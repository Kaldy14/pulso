import Foundation
import CryptoKit

struct UploadResult: Sendable {
    let status: Int
    let bodySnippet: String
    let duration: TimeInterval

    var isSuccess: Bool { (200 ..< 300).contains(status) }
}

protocol Uploading: Sendable {
    func send(_ body: Data, gzipped: Bool, to url: URL, token: String?) async throws -> UploadResult
}

struct HTTPUploader: Uploading {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false // fail fast; the outbox owns retries
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    static func request(body: Data, gzipped: Bool, url: URL, token: String?) throws -> URLRequest {
        guard AppSettings.baseURL(from: url.absoluteString) != nil, let token, !token.isEmpty else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if gzipped {
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        }
        request.setValue(token, forHTTPHeaderField: "X-Health-Key")
        request.setValue(SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(), forHTTPHeaderField: "Idempotency-Key")
        return request
    }

    func send(_ body: Data, gzipped: Bool, to url: URL, token: String?) async throws -> UploadResult {
        let request = try Self.request(body: body, gzipped: gzipped, url: url, token: token)
        let started = Date()
        let (_, response) = try await session.upload(for: request, from: body)
        return UploadResult(
            status: (response as? HTTPURLResponse)?.statusCode ?? 0,
            bodySnippet: "",
            duration: Date().timeIntervalSince(started)
        )
    }

    /// GET <base>/health — the Settings "Test Connection" button.
    func checkHealth(_ url: URL) async -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.httpMethod = "HEAD"
        request.setValue(Keychain.string(for: SettingsKeys.tokenAccount), forHTTPHeaderField: "X-Health-Key")
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200 ..< 300).contains(status) {
                return "OK — HTTP \(status)"
            }
            return "HTTP \(status)"
        } catch {
            return "Unreachable: \(error.localizedDescription)"
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward health data or credentials to another destination, even on 307/308.
        completionHandler(nil)
    }
}
