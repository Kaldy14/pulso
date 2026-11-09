import Foundation
import Observation

enum SettingsKeys {
    static let endpoint = "server.endpoint"
    static let enabledTypes = "types.enabled"
    static let tokenAccount = "server-token"
    static let outboxSequence = "outbox.seq"
    /// Durable indication that a requested full history import is unfinished.
    static let reimportPending = "sync.reimportPending"
}

/// User configuration. The @Observable instance drives the UI; the static
/// accessors read the same storage (UserDefaults / Keychain, both
/// thread-safe) so background actors never touch the UI object.
@Observable
@MainActor
final class AppSettings {
    var endpoint: String {
        didSet { UserDefaults.standard.set(endpoint, forKey: SettingsKeys.endpoint) }
    }

    var token: String {
        didSet { Keychain.set(token.isEmpty ? nil : token, for: SettingsKeys.tokenAccount) }
    }

    private var enabled: [String: Bool] {
        didSet { UserDefaults.standard.set(enabled, forKey: SettingsKeys.enabledTypes) }
    }

    init() {
        endpoint = UserDefaults.standard.string(forKey: SettingsKeys.endpoint) ?? ""
        token = Keychain.string(for: SettingsKeys.tokenAccount) ?? ""
        enabled = Self.storedEnabled()
    }

    func isEnabled(_ key: String) -> Bool { enabled[key] ?? true }
    func setEnabled(_ key: String, _ value: Bool) { enabled[key] = value }

    var baseURL: URL? { Self.baseURL(from: endpoint) }
    var healthURL: URL? { baseURL }

    // MARK: - Shared parsing / thread-safe accessors

    nonisolated static func baseURL(from raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let host = url.host()?.lowercased(),
              ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil,
              url.fragment == nil, url.query == nil else { return nil }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        let ipv4 = octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1]) && octets.allSatisfy { (0...255).contains($0) }
        let ipv6 = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).hasPrefix("fd7a:115c:a1e0:")
        guard ipv4 || ipv6 || host.hasSuffix(".ts.net") else { return nil }
        return url
    }

    /// Where to POST, resolved at send time. nil = not configured yet.
    nonisolated static func currentTarget() -> (url: URL, token: String?)? {
        guard let base = currentBase(), let token = base.token, !token.isEmpty else { return nil }
        return (base.url, token)
    }

    nonisolated static func currentBase() -> (url: URL, token: String?)? {
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.endpoint) ?? ""
        guard let base = baseURL(from: raw) else { return nil }
        return (base, Keychain.string(for: SettingsKeys.tokenAccount))
    }

    nonisolated static func currentEnabled(_ key: String) -> Bool {
        storedEnabled()[key] ?? true
    }

    nonisolated static func currentEnabledTypes() -> [SyncedType] {
        TypeRegistry.all.filter { currentEnabled($0.key) }
    }

    nonisolated private static func storedEnabled() -> [String: Bool] {
        (UserDefaults.standard.dictionary(forKey: SettingsKeys.enabledTypes) ?? [:])
            .compactMapValues { $0 as? Bool }
    }
}
