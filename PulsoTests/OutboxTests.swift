import XCTest
@testable import Pulso

/// Scriptable uploader. Unscripted calls succeed with HTTP 200.
final class MockUploader: Uploading, @unchecked Sendable {
    struct Call {
        let body: Data
        let url: URL
        let token: String?
    }

    static let ok = UploadResult(status: 200, bodySnippet: #"{"received":1}"#, duration: 0.01)

    private let lock = NSLock()
    private var script: [Result<UploadResult, Error>] = []
    private var calls: [Call] = []

    func enqueueResult(_ result: Result<UploadResult, Error>) {
        lock.lock()
        script.append(result)
        lock.unlock()
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls.count
    }

    func call(_ index: Int) -> Call {
        lock.lock()
        defer { lock.unlock() }
        return calls[index]
    }

    func send(_ body: Data, gzipped: Bool, to url: URL, token: String?) async throws -> UploadResult {
        switch record(Call(body: body, url: url, token: token)) {
        case .none:
            return Self.ok
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }

    private func record(_ call: Call) -> Result<UploadResult, Error>? {
        lock.lock()
        defer { lock.unlock() }
        calls.append(call)
        return script.isEmpty ? nil : script.removeFirst()
    }
}

@MainActor
final class OutboxTests: XCTestCase {
    private var base: URL!
    private var outboxDir: URL!
    private var anchors: AnchorStore!
    private var uploader: MockUploader!
    private var status: AppStatus!
    private var log: LogStore!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        outboxDir = base.appendingPathComponent("Outbox")
        anchors = AnchorStore(directory: base.appendingPathComponent("Anchors"))
        uploader = MockUploader()
        status = AppStatus()
        log = LogStore(directory: base)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makeOutbox(maxBatchBytes: Int = Wire.maxBatchBytes, hasTarget: Bool = true) -> Outbox {
        let target: @Sendable () -> (url: URL, token: String?)?
        if hasTarget {
            let url = URL(string: "http://127.0.0.1:1/ingest")!
            target = { (url: url, token: "tok") }
        } else {
            target = { nil }
        }
        return Outbox(
            directory: outboxDir,
            anchors: anchors,
            uploader: uploader,
            target: target,
            log: log,
            status: status,
            maxBatchBytes: maxBatchBytes
        )
    }

    private func element(_ id: String, pad: Int = 0) -> BatchElement {
        .sample(SampleDTO(
            uuid: id + String(repeating: "x", count: pad),
            type: "sleepAnalysis",
            start: "2026-07-06T01:12:00+01:00",
            end: "2026-07-06T02:40:00+01:00",
            value: .string("inBed"),
            source: "test"
        ))
    }

    private func anchorData(_ key: String) -> Data? {
        try? Data(contentsOf: base.appendingPathComponent("Anchors/\(key).anchor"))
    }

    // MARK: - Tests

    func testDrainDeliversFIFOPersistsAnchorsAndClearsFiles() async throws {
        let outbox = makeOutbox()
        let anchorA1 = Data("anchor-a1".utf8)
        let anchorA2 = Data("anchor-a2".utf8)
        let anchorB1 = Data("anchor-b1".utf8)

        try await outbox.enqueue(typeKey: "a", elements: [element("first")], anchor: anchorA1)
        try await outbox.enqueue(typeKey: "a", elements: [element("second")], anchor: anchorA2)
        try await outbox.enqueue(typeKey: "b", elements: [element("third")], anchor: anchorB1)
        await outbox.drain(force: true)

        XCTAssertEqual(uploader.callCount, 3)
        let pending = await outbox.pendingCount()
        XCTAssertEqual(pending, 0)

        // The anchor moves only when the server says yes — and in order.
        XCTAssertEqual(anchorData("a"), anchorA2)
        XCTAssertEqual(anchorData("b"), anchorB1)

        // FIFO: bodies arrive in enqueue order.
        let firstBody = String(decoding: uploader.call(0).body, as: UTF8.self)
        XCTAssertTrue(firstBody.contains("first"))
        XCTAssertEqual(uploader.call(0).token, "tok")
        XCTAssertEqual(uploader.call(0).url.path, "/ingest")
    }

    func testFailureStopsDrainKeepsFilesAndBacksOff() async throws {
        uploader.enqueueResult(.failure(URLError(.cannotConnectToHost)))
        let outbox = makeOutbox()

        try await outbox.enqueue(typeKey: "a", elements: [element("one")], anchor: Data("a1".utf8))
        try await outbox.enqueue(typeKey: "a", elements: [element("two")], anchor: Data("a2".utf8))
        await outbox.drain(force: false) // barrier for the enqueue-spawned drains

        // First attempt failed; backoff must swallow non-forced retries.
        XCTAssertEqual(uploader.callCount, 1)
        var pending = await outbox.pendingCount()
        XCTAssertEqual(pending, 2)
        XCTAssertNil(anchorData("a"), "no ACK, no anchor")

        await outbox.drain(force: false)
        XCTAssertEqual(uploader.callCount, 1, "backoff window must suppress retries")

        // Manual sync bypasses the backoff.
        await outbox.drain(force: true)
        XCTAssertEqual(uploader.callCount, 3)
        pending = await outbox.pendingCount()
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(anchorData("a"), Data("a2".utf8))
    }

    func testNon2xxResponseIsAFailure() async throws {
        uploader.enqueueResult(.success(UploadResult(status: 500, bodySnippet: "boom", duration: 0.01)))
        let outbox = makeOutbox()

        try await outbox.enqueue(typeKey: "a", elements: [element("one")], anchor: Data("a1".utf8))
        await outbox.drain(force: false)

        let pending = await outbox.pendingCount()
        XCTAssertEqual(pending, 1)
        XCTAssertNil(anchorData("a"))
    }

    func testCorruptBatchStopsDeliveryWithoutDroppingData() async throws {
        let outbox = makeOutbox()
        try FileManager.default.createDirectory(at: outboxDir, withIntermediateDirectories: true)
        try Data("this is not json".utf8)
            .write(to: outboxDir.appendingPathComponent("batch-000000000001-dead.json"))

        await outbox.drain(force: true)

        XCTAssertEqual(uploader.callCount, 0)
        let pending = await outbox.pendingCount()
        XCTAssertEqual(pending, 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: outboxDir.path)
        XCTAssertEqual(names, ["batch-000000000001-dead.json"])
    }

    func testOversizedEnqueueSplitsAndOnlyLastSliceCarriesAnchor() async throws {
        // No server configured: files stay on disk for inspection.
        let outbox = makeOutbox(maxBatchBytes: 700, hasTarget: false)
        let anchor = Data("final-anchor".utf8)

        try await outbox.enqueue(
            typeKey: "a",
            elements: (0 ..< 8).map { element("id-\($0)", pad: 150) },
            anchor: anchor
        )
        await outbox.drain(force: true) // no-op without a target; barrier only

        let files = try FileManager.default.contentsOfDirectory(at: outboxDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThan(files.count, 1, "batch should have been split")

        var totalSamples = 0
        for (index, file) in files.enumerated() {
            let batch = try Wire.fileDecoder().decode(Batch.self, from: Data(contentsOf: file))
            totalSamples += batch.sampleCount
            if index == files.count - 1 {
                XCTAssertEqual(batch.anchor, anchor, "only the last slice may advance the anchor")
            } else {
                XCTAssertNil(batch.anchor)
            }
        }
        XCTAssertEqual(totalSamples, 8)
        XCTAssertEqual(uploader.callCount, 0)
    }

    func testRemoveAllClearsQueue() async throws {
        let outbox = makeOutbox(hasTarget: false)
        try await outbox.enqueue(typeKey: "a", elements: [element("one")], anchor: nil)
        var pending = await outbox.pendingCount()
        XCTAssertEqual(pending, 1)

        await outbox.removeAll()
        pending = await outbox.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    func testUploadBodyHasHealthAutoExportEnvelopeAndDeletions() async throws {
        let outbox = makeOutbox()
        try await outbox.enqueue(typeKey: "a", elements: [element("one"), .tombstone(["gone-1"])], anchor: nil)
        await outbox.drain(force: true)
        let root = try JSONDecoder().decode([String: JSONValue].self, from: uploader.call(0).body)
        guard case .object(let data) = root["data"] else { return XCTFail("missing data envelope") }
        XCTAssertEqual(data["deleted"], .array([.string("gone-1")]))
        guard case .array(let metrics) = data["metrics"] else { return XCTFail("missing metrics") }
        XCTAssertEqual(metrics.count, 1)
    }

    func testFailedDeliveryKeepsQueuedAnchorForRestart() async throws {
        uploader.enqueueResult(.failure(URLError(.notConnectedToInternet)))
        let outbox = makeOutbox()
        let anchor = Data("resume-anchor".utf8)
        try await outbox.enqueue(typeKey: "a", elements: [element("one")], anchor: anchor)
        await outbox.drain(force: false)
        let restored = makeOutbox()
        let queued = try await restored.queuedAnchors()["a"]
        XCTAssertEqual(queued, anchor)
        XCTAssertNil(anchorData("a"))
    }
    func testRestartRestoresLatestCheckpointForEveryTypeInOneSnapshot() async throws {
        let outbox = makeOutbox(hasTarget: false)
        try await outbox.enqueue(typeKey: "a", elements: [element("one")], anchor: Data("a1".utf8))
        try await outbox.enqueue(typeKey: "b", elements: [element("two")], anchor: Data("b1".utf8))
        try await outbox.enqueue(typeKey: "a", elements: [element("three")], anchor: Data("a2".utf8))
        // A partial split page has no checkpoint yet and must not erase a2.
        try await outbox.enqueue(typeKey: "a", elements: [element("four")], anchor: nil)
        await outbox.drain(force: false)
        let restored = makeOutbox(hasTarget: false)
        let checkpoints = try await restored.queuedAnchors()
        XCTAssertEqual(checkpoints, ["a": Data("a2".utf8), "b": Data("b1".utf8)])
        XCTAssertNil(anchorData("a"), "reading a checkpoint must not acknowledge delivery")
    }

    func testCorruptQueueCannotBeUsedToAdvanceAnyType() async throws {
        let outbox = makeOutbox(hasTarget: false)
        try await outbox.enqueue(typeKey: "a", elements: [element("one")], anchor: Data("a1".utf8))
        try Data("broken".utf8).write(to: outboxDir.appendingPathComponent("batch-999999999999-bad.json"))
        do {
            _ = try await outbox.queuedAnchors()
            XCTFail("Corrupt queue must stop checkpoint restoration")
        } catch { }
        XCTAssertNil(anchorData("a"))
    }

    func testNetworkFailureRetriesWithoutAnotherHealthKitOrManualTrigger() async throws {
        uploader.enqueueResult(.failure(URLError(.timedOut)))
        let outbox = Outbox(
            directory: outboxDir, anchors: anchors, uploader: uploader,
            target: { (URL(string: "http://100.64.0.1/apple-health")!, "test") },
            log: log, status: status, retryInterval: 0.05
        )
        try await outbox.enqueue(typeKey: "a", elements: [element("one")], anchor: Data("a1".utf8))
        await outbox.drain(force: false)
        for _ in 0..<200 {
            if await outbox.pendingCount() == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pending = await outbox.pendingCount()
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(uploader.callCount, 2)
        XCTAssertNil(status.lastError, "a recovered delivery error must disappear")
        XCTAssertEqual(uploader.call(0).body, uploader.call(1).body, "retry identity must remain stable")
        XCTAssertEqual(anchorData("a"), Data("a1".utf8))
    }

    func testDeliveryRecoveryDoesNotHideUnrelatedHealthKitError() {
        status.setError("HealthKit is locked")
        status.clearError(ifMatching: "The request timed out.")
        XCTAssertEqual(status.lastError, "HealthKit is locked")
    }

    func testReimportWaitsForInflightUploadBeforeResettingQueue() async throws {
        let blocked = BlockingUploader()
        let outbox = Outbox(directory: outboxDir, anchors: anchors, uploader: blocked,
            target: { (URL(string: "http://100.64.0.1/apple-health")!, "test") }, log: log, status: status)
        try await outbox.enqueue(typeKey: "a", elements: [element("old")], anchor: Data("old-anchor".utf8))
        await blocked.waitUntilStarted()
        let stopping = Task { await outbox.pause() }
        // Give pause time to cancel the worker while the transport is blocked.
        try await Task.sleep(for: .milliseconds(30))
        await blocked.release()
        await stopping.value
        XCTAssertNil(anchorData("a"), "late response must not persist an old checkpoint after cancellation")
        try await outbox.clearForReimport()
        let pending = await outbox.pendingCount()
        XCTAssertEqual(pending, 0)
        await outbox.resume()
        try await outbox.enqueue(typeKey: "a", elements: [element("new")], anchor: Data("new-anchor".utf8))
        await outbox.drain(force: true)
        XCTAssertEqual(anchorData("a"), Data("new-anchor".utf8))
    }

    func testProgressDoesNotClaimCompletionDuringReadingOrFailure() {
        status.beginReading(total: 3)
        status.readingType("Steps")
        status.loaded(100)
        status.finishedType()
        status.finishedType(failed: true)
        status.endReading(completed: false)
        XCTAssertEqual(status.loadedSamples, 100)
        XCTAssertEqual(status.completedTypes, 1)
        XCTAssertEqual(status.failedTypes, 1)
        XCTAssertFalse(status.passFinished)
        status.beginReading(total: 3)
        XCTAssertEqual(status.loadedSamples, 0)
        XCTAssertEqual(status.failedTypes, 0)
    }

    func testConcurrentProducersUseOneUploaderAndDeliverNewPages() async throws {
        let blocked = BlockingUploader()
        let outbox = Outbox(
            directory: outboxDir, anchors: anchors, uploader: blocked,
            target: { (URL(string: "http://100.64.0.1/apple-health")!, "test") },
            log: log, status: status
        )
        try await outbox.enqueue(typeKey: "a", elements: [element("first")], anchor: Data("a1".utf8))
        await blocked.waitUntilStarted()
        for i in 0..<100 {
            try await outbox.enqueue(typeKey: "a", elements: [element("next-\(i)")], anchor: Data("a-\(i)".utf8))
        }
        await blocked.release()
        await outbox.drain(force: false)
        let counts = await blocked.counts()
        let pending = await outbox.pendingCount()
        XCTAssertEqual(counts.calls, 101)
        XCTAssertEqual(counts.maximumInFlight, 1)
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(anchorData("a"), Data("a-99".utf8))
    }

}


private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor BlockingUploader: Uploading {
    private let started = AsyncGate()
    private let gate = AsyncGate()
    private var callCount = 0
    private var inFlight = 0
    private var maximumInFlight = 0

    func send(_ body: Data, gzipped: Bool, to url: URL, token: String?) async throws -> UploadResult {
        callCount += 1
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        await started.open()
        await gate.wait()
        inFlight -= 1
        return MockUploader.ok
    }

    func waitUntilStarted() async { await started.wait() }
    func release() async { await gate.open() }
    func counts() -> (calls: Int, maximumInFlight: Int) { (callCount, maximumInFlight) }
}

private actor SyncProbe {
    let started = AsyncGate()
    let gate = AsyncGate()
    private(set) var cancellations: [Bool] = []
    private(set) var reasons: [String] = []

    func perform(_ reason: SyncReason) async {
        reasons.append(reason.description)
        await started.open()
        await gate.wait()
        cancellations.append(Task.isCancelled)
    }
}

@MainActor
final class SyncCoordinatorTests: XCTestCase {
    private func waitForCallers(_ count: Int, in coordinator: SyncCoordinator) async throws {
        for _ in 0..<200 {
            if await coordinator.waitingCount == count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Callers did not register")
    }

    func testExpiringObserverDoesNotCancelManualSync() async throws {
        let coordinator = SyncCoordinator()
        let probe = SyncProbe()
        let observerReturned = expectation(description: "observer deadline returns promptly")
        let observer = Task {
            await coordinator.run(.observer("steps")) { await probe.perform($0) }
            observerReturned.fulfill()
        }
        await probe.started.wait()
        let foreground = Task {
            await coordinator.run(.manual) { await probe.perform($0) }
        }
        try await waitForCallers(2, in: coordinator)
        observer.cancel()
        await fulfillment(of: [observerReturned], timeout: 1)
        await probe.gate.open()
        await foreground.value
        let cancellations = await probe.cancellations
        let reasons = await probe.reasons
        XCTAssertEqual(cancellations, [false, false])
        XCTAssertEqual(reasons, ["new steps data", "manual"])
    }

    func testForegroundRestartsAfterCancelledBackgroundRun() async throws {
        let coordinator = SyncCoordinator()
        let probe = SyncProbe()
        let observerReturned = expectation(description: "cancelled waiter releases before work completes")
        let observer = Task {
            await coordinator.run(.observer("steps")) { await probe.perform($0) }
            observerReturned.fulfill()
        }
        await probe.started.wait()
        observer.cancel()
        await fulfillment(of: [observerReturned], timeout: 1)
        let foreground = Task {
            await coordinator.run(.foreground) { await probe.perform($0) }
        }
        try await waitForCallers(1, in: coordinator)
        await probe.gate.open()
        await foreground.value
        let cancellations = await probe.cancellations
        XCTAssertEqual(cancellations, [true, false], "new caller must get an uncancelled run")
    }

    func testObserverBurstCoalescesAndKeepsManualRetryPriority() async throws {
        let coordinator = SyncCoordinator()
        let probe = SyncProbe()
        let first = Task { await coordinator.run(.observer("first")) { await probe.perform($0) } }
        await probe.started.wait()
        let manual = Task { await coordinator.run(.manual) { await probe.perform($0) } }
        try await waitForCallers(2, in: coordinator)
        let observers = (0..<30).map { i in
            Task { await coordinator.run(.observer("type-\(i)")) { await probe.perform($0) } }
        }
        try await waitForCallers(32, in: coordinator)
        await probe.gate.open()
        await first.value
        await manual.value
        for observer in observers { await observer.value }
        let reasons = await probe.reasons
        XCTAssertEqual(reasons, ["new first data", "manual"])
    }
}
