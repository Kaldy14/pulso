import Foundation
import HealthKit
import UIKit

enum SyncReason: CustomStringConvertible, Sendable {
    case manual
    case foreground
    case observer(String)
    case backgroundRefresh
    case settingsChanged
    case reimport

    var forcesUpload: Bool {
        switch self {
        case .manual, .foreground, .settingsChanged, .reimport: true
        case .observer, .backgroundRefresh: false
        }
    }

    var description: String {
        switch self {
        case .manual: "manual"
        case .foreground: "app opened"
        case .observer(let key): "new \(key) data"
        case .backgroundRefresh: "background refresh"
        case .settingsChanged: "settings changed"
        case .reimport: "full re-import"
        }
    }
}

/// Per enabled type: run an anchored query from the last anchor, hand the
/// results to the outbox, and let the outbox persist the new anchor once the
/// server ACKs. An in-memory anchor cache leads the persisted one so
/// overlapping triggers don't re-read samples that are already queued; after
/// a crash the newest queued checkpoint wins over the acknowledged anchor.
/// The receiver still deduplicates UUIDs if enqueue or HTTP acknowledgment was interrupted.
actor SyncEngine {
    // Larger metric pages reduce requests; routes, ECG and workouts stay one per page.
    static let queryLimit = 1000

    private let healthStore: HKHealthStore
    private let anchors: AnchorStore
    private let outbox: Outbox
    private let log: LogStore
    private let status: AppStatus
    private var anchorCache: [String: HKQueryAnchor] = [:]
    private let coordinator = SyncCoordinator()
    private var paused = false

    init(
        healthStore: HKHealthStore, anchors: AnchorStore, outbox: Outbox,
        log: LogStore, status: AppStatus
    ) {
        self.healthStore = healthStore
        self.anchors = anchors
        self.outbox = outbox
        self.log = log
        self.status = status
    }

    /// Callers share a run, but cancelling one observer must not cancel a
    /// foreground caller that is still waiting for its import.
    func requestSync(_ reason: SyncReason) async {
        guard !paused, !UserDefaults.standard.bool(forKey: "sync.reimportPreparing") else { return }
        await coordinator.run(reason) { reason in
            await self.performSync(reason)
        }
    }

    private func performSync(_ reason: SyncReason) async {
        guard !Task.isCancelled, await MainActor.run(body: { UIApplication.shared.isProtectedDataAvailable }) else { return }
        guard AppSettings.currentTarget() != nil else {
            await log.info("sync skipped (\(reason)): no server configured")
            return
        }
        await status.setSyncing(true)
        await status.setError(nil)
        let enabled = AppSettings.currentEnabledTypes()
        await status.beginReading(total: enabled.count)

        await log.info("sync started (\(reason))")

        // Restore all types in ONE scan. A per-type scan decoded the entire
        // history ~200 times, blocking both HealthKit queries and uploads.
        let queuedAnchors: [String: Data]
        do {
            queuedAnchors = try await outbox.queuedAnchors()
        } catch {
            if !(error is CancellationError) {
                await status.setError("Unreadable pending batch. Sync stopped to preserve data.")
            }
            await status.endReading(completed: false)
            await status.setSyncing(false)
            return
        }
        // Existing durable pages can upload while new HealthKit pages are read.
        let delivery = await outbox.startDrain(force: reason.forcesUpload)
        var resolvedAnchors: [String: HKQueryAnchor] = [:]
        for type in enabled {
            let queuedAnchor = queuedAnchors[type.key].flatMap {
                try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
            }
            if let anchor = anchorCache[type.key] ?? queuedAnchor ?? anchors.load(type.key) {
                resolvedAnchors[type.key] = anchor
            }
        }
        let reimporting = UserDefaults.standard.bool(forKey: SettingsKeys.reimportPending)

        var queued = 0
        var anyFailed = false
        for type in enabled {
            do {
                try Task.checkCancellation()
                await status.readingType(type.displayName)
                queued += try await sync(type, anchor: resolvedAnchors[type.key])
                await status.finishedType()
            } catch is CancellationError {
                anyFailed = true
                await log.info("sync paused; queued data will resume on the next run")
                break
            } catch {
                anyFailed = true
                await status.finishedType(failed: true)
                await status.setError("\(type.displayName): \(error.localizedDescription)")
                await log.error("\(type.key): \(error.localizedDescription)")
            }
        }
        if reimporting && !anyFailed {
            UserDefaults.standard.set(false, forKey: SettingsKeys.reimportPending)
            await log.info("full re-import pass completed for all enabled types")
        }
        await status.endReading(completed: !anyFailed && !Task.isCancelled)
        await delivery.value
        // The first drain may have finished while queries were still running.
        // Do not force another retry here after an HTTP failure in this pass.
        if !Task.isCancelled { await outbox.drain(force: false) }
        await status.setSyncing(false)
        if queued > 0 {
            await log.info("sync (\(reason)): queued \(queued) sample(s)")
        }
    }

    private func sync(_ type: SyncedType, anchor resolvedAnchor: HKQueryAnchor?) async throws -> Int {
        var anchor = resolvedAnchor
        var queued = 0
        let pageLimit = ["workout", "workoutRoute", "electrocardiogram"].contains(type.key) ? 1 : Self.queryLimit
        while true {
            try Task.checkCancellation()
            let descriptor = HKAnchoredObjectQueryDescriptor(
                predicates: [.sample(type: type.sampleType, predicate: nil)],
                anchor: anchor,
                limit: pageLimit
            )
            let result = try await descriptor.result(for: healthStore)
            let added = result.addedSamples
            let deleted = result.deletedObjects.map { $0.uuid.uuidString }
            let newAnchor = normalize(result.newAnchor)

            if added.isEmpty && deleted.isEmpty {
                // Nothing new — the anchor covers no undelivered samples, so
                // persisting it immediately is safe.
                if let newAnchor {
                    anchorCache[type.key] = newAnchor
                    // Only persist an empty result if no earlier page remains unacknowledged.
                    if await outbox.pendingCount() == 0 { anchors.save(newAnchor, for: type.key) }
                }
                await status.recordChecked(type.key)
                return queued
            }

            var dtos: [SampleDTO] = []
            let serializer = DetailedSerializer(store: healthStore)
            for sample in added {
                try Task.checkCancellation()
                dtos.append(try await serializer.serialize(sample, as: type))
            }
            var elements = dtos.map(BatchElement.sample)
            if !deleted.isEmpty {
                elements.append(.tombstone(deleted))
            }
            let anchorData = newAnchor.flatMap { anchors.archive($0) }
            try await outbox.enqueue(typeKey: type.key, elements: elements, anchor: anchorData)
            if let newAnchor {
                anchorCache[type.key] = newAnchor
                anchor = newAnchor
            }
            queued += dtos.count
            await status.loaded(dtos.count)
            await status.recordChecked(type.key)
            if !deleted.isEmpty {
                await log.info("\(type.key): queued \(dtos.count) sample(s) + \(deleted.count) deletion(s)")
            } else {
                await log.info("\(type.key): queued \(dtos.count) sample(s)")
            }
            if added.count < pageLimit && deleted.count < pageLimit {
                return queued
            }
        }
    }

    /// The SDK has flip-flopped on the optionality of `newAnchor`; funneling
    /// it through an optional parameter compiles either way.
    private func normalize(_ anchor: HKQueryAnchor?) -> HKQueryAnchor? {
        anchor
    }

    func prepareReimport() async throws {
        paused = true
        let worker = await coordinator.suspend()
        await outbox.pause()
        await worker?.value
        // Nothing can write old anchors or enqueue pages beyond this barrier.
        try await outbox.clearForReimport()
        anchors.clearAll()
        anchorCache = [:]
    }

    func resumeAfterReimport() async {
        await coordinator.resume()
        await outbox.resume()
        paused = false
    }
}

/// Coalesces triggers and gives each caller a cancellable wait. In particular,
/// the observer's 25-second deadline releases that observer promptly, without
/// cancelling work needed by an open app. A new caller restarts a cancelled run.
actor SyncCoordinator {
    private var worker: Task<Void, Never>?
    private var suspended = false
    private var pendingReason: SyncReason?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    var waitingCount: Int { waiters.count }

    func run(_ reason: SyncReason, operation: @escaping @Sendable (SyncReason) async -> Void) async {
        guard !suspended else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                waiters[id] = continuation
                // Keep a manual retry's priority when observer events arrive.
                if pendingReason?.forcesUpload != true { pendingReason = reason }
                if worker == nil { start(operation) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func suspend() -> Task<Void, Never>? {
        suspended = true
        pendingReason = nil
        worker?.cancel()
        return worker
    }

    func resume() { suspended = false }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
        if waiters.isEmpty {
            pendingReason = nil
            worker?.cancel()
        }
    }

    private func start(_ operation: @escaping @Sendable (SyncReason) async -> Void) {
        worker = Task {
            while !Task.isCancelled, let reason = pendingReason {
                pendingReason = nil
                await operation(reason)
            }
            worker = nil
            if pendingReason != nil, !waiters.isEmpty {
                // A foreground request arrived after the old run was cancelled.
                // It needs a fresh task, not the old task's cancellation flag.
                start(operation)
            } else {
                let completed = waiters
                waiters.removeAll()
                for waiter in completed.values { waiter.resume() }
            }
        }
    }
}
