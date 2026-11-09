import Foundation

/// Durable delivery queue. Every batch is written to disk *before* the first
/// upload attempt and deleted only on a server 2xx — at which point the
/// batch's anchor (if any) is persisted. Files drain strictly in enqueue
/// order and draining stops at the first failure, so anchors can never
/// advance past an undelivered batch. At-least-once delivery; the server
/// dedupes by sample uuid.
actor Outbox {
    static let baseRetryInterval: TimeInterval = 60
    static let maxRetryInterval: TimeInterval = 3600

    private let directory: URL
    private let anchors: AnchorStore
    private let uploader: Uploading
    private let target: @Sendable () -> (url: URL, token: String?)?
    private let log: LogStore
    private let status: AppStatus
    private let maxBatchBytes: Int
    private var sequence: Int
    private var failureCount = 0
    private var nextAttempt = Date.distantPast
    private var chain: Task<Void, Never>?
    private var drainRequested = false
    private var forceRequested = false
    private var retryTask: Task<Void, Never>?
    private let retryInterval: TimeInterval
    private var deliveryError: String?
    private var paused = false
    private var queueSizes: [URL: Int64]?

    init(
        directory: URL,
        anchors: AnchorStore,
        uploader: Uploading,
        target: @escaping @Sendable () -> (url: URL, token: String?)?,
        log: LogStore,
        status: AppStatus,
        maxBatchBytes: Int = Wire.maxBatchBytes,
        retryInterval: TimeInterval = Outbox.baseRetryInterval
    ) {
        self.directory = directory
        self.anchors = anchors
        self.uploader = uploader
        self.target = target
        self.log = log
        self.status = status
        self.maxBatchBytes = maxBatchBytes
        self.retryInterval = retryInterval
        sequence = UserDefaults.standard.integer(forKey: SettingsKeys.outboxSequence)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Enqueue

    func enqueue(typeKey: String, elements: [BatchElement], anchor: Data?) throws {
        guard !elements.isEmpty else { return }
        let slices = try BatchSlicer.slice(elements, maxBytes: maxBatchBytes)
        for (index, slice) in slices.enumerated() {
            let batch = Batch(
                id: UUID(),
                typeKey: typeKey,
                createdAt: Date(),
                anchor: index == slices.count - 1 ? anchor : nil,
                elements: slice
            )
            let data = try Wire.fileEncoder().encode(batch)
            sequence += 1
            UserDefaults.standard.set(sequence, forKey: SettingsKeys.outboxSequence)
            let name = String(format: "batch-%012d-%@.json", sequence, String(batch.id.uuidString.prefix(8)))
            let file = directory.appendingPathComponent(name)
            try data.write(to: file, options: .atomic)
            queueSizes?[file] = Int64(data.count)
        }
        // Pipeline uploads with whatever the caller does next.
        startDrain(force: false)
    }

    // MARK: - Drain

    /// One worker services all producers. A large import used to create a
    /// retained chain of thousands of tasks, each rescanning the same files.
    func drain(force: Bool) async {
        await startDrain(force: force).value
    }

    @discardableResult
    func startDrain(force: Bool) -> Task<Void, Never> {
        guard !paused else { return Task {} }
        drainRequested = true
        forceRequested = forceRequested || force
        if let chain { return chain }
        let task = Task {
            repeat {
                let force = forceRequested
                drainRequested = false
                forceRequested = false
                await performDrain(force: force)
                await refreshPendingStatus()
            } while drainRequested && !Task.isCancelled && !paused
            chain = nil
        }
        chain = task
        return task
    }

    private func performDrain(force: Bool) async {
        var files = pendingFiles()
        guard !files.isEmpty else { return }
        guard let target = target() else {
            await log.info("outbox: \(files.count) batch(es) waiting — no server configured")
            return
        }
        if !force && Date() < nextAttempt { return }

        while let file = files.first, !Task.isCancelled {
            files.removeFirst()
            let batch: Batch
            do {
                batch = try Wire.fileDecoder().decode(Batch.self, from: Data(contentsOf: file))
            } catch {
                // Skipping this page could acknowledge a later anchor and lose data.
                await recordFailure("Unreadable pending batch; delivery stopped: \(file.lastPathComponent)", status: nil)
                return
            }
            do {
                let body = try HealthAutoExport.encode(batch.elements)
                await status.setUploading(true)
                let result = try await uploader.send(body, gzipped: false, to: target.url, token: target.token)
                await status.setUploading(false)
                try Task.checkCancellation()
                guard result.isSuccess else {
                    await recordFailure("HTTP \(result.status) \(result.bodySnippet.prefix(120))", status: result.status)
                    return
                }
                if let anchorData = batch.anchor {
                    anchors.saveRaw(anchorData, for: batch.typeKey)
                }
                try FileManager.default.removeItem(at: file)
                queueSizes?.removeValue(forKey: file)
                failureCount = 0
                nextAttempt = .distantPast
                retryTask?.cancel()
                retryTask = nil
                let response = "HTTP \(result.status) · \(result.bodySnippet.prefix(80))"
                await status.recordDelivery(typeKey: batch.typeKey, count: batch.sampleCount, response: response)
                await status.clearError(ifMatching: deliveryError)
                deliveryError = nil
                await refreshPendingStatus()
                await log.info(
                    "delivered \(batch.sampleCount) \(batch.typeKey) sample(s) — HTTP \(result.status) in \(Int(result.duration * 1000))ms"
                )
            } catch {
                await status.setUploading(false)
                if Task.isCancelled { return }
                await recordFailure(error.localizedDescription, status: nil)
                return
            }
        }
    }

    private func recordFailure(_ reason: String, status statusCode: Int?) async {
        deliveryError = reason
        await status.setError(reason)
        failureCount += 1
        let delay = min(
            Self.maxRetryInterval,
            retryInterval * pow(2, Double(failureCount - 1))
        )
        nextAttempt = Date(timeIntervalSinceNow: delay)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            await self?.drain(force: false)
        }
        var hint = ""
        if statusCode == 401 { hint = " — check the X-Health-Key in Settings" }
        await status.setLastResponse(String(reason.prefix(160)))
        await log.warn("delivery failed: \(reason)\(hint) — retrying in \(Int(delay))s")
    }

    // MARK: - State

    private func pendingFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Restore the newest checkpoint for every type in one FIFO scan. This
    /// keeps split pages safe: only their final file contains an anchor.
    func queuedAnchors() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for file in pendingFiles() {
            try Task.checkCancellation()
            try autoreleasepool {
                let batch = try Wire.fileDecoder().decode(Batch.self, from: Data(contentsOf: file))
                if let anchor = batch.anchor { result[batch.typeKey] = anchor }
            }
        }
        return result
    }

    func pendingCount() -> Int {
        pendingFiles().count
    }

    func refreshPendingStatus() async {
        if queueSizes == nil {
            queueSizes = Dictionary(uniqueKeysWithValues: pendingFiles().map { file in
                (file, Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
            })
        }
        let count = queueSizes?.count ?? 0
        let bytes = queueSizes?.values.reduce(0, +) ?? 0
        await status.setOutbox(pending: count, nextRetry: failureCount > 0 && count > 0 ? nextAttempt : nil, bytes: bytes)
    }

    func pause() async {
        paused = true
        retryTask?.cancel()
        retryTask = nil
        drainRequested = false
        chain?.cancel()
        await chain?.value
    }

    func resume() { paused = false }

    func clearForReimport() async throws {
        for file in pendingFiles() { try FileManager.default.removeItem(at: file) }
        queueSizes = nil
        failureCount = 0
        nextAttempt = .distantPast
        await refreshPendingStatus()
    }

    func removeAll() async {
        retryTask?.cancel()
        retryTask = nil
        for file in pendingFiles() {
            try? FileManager.default.removeItem(at: file)
        }
        queueSizes = nil
        failureCount = 0
        nextAttempt = .distantPast
        await refreshPendingStatus()
    }
}
