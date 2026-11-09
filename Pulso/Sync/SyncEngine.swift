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
    static let queryLimit = 100

    private let healthStore: HKHealthStore
    private let anchors: AnchorStore
    private let outbox: Outbox
    private let log: LogStore
    private let status: AppStatus
    private var anchorCache: [String: HKQueryAnchor] = [:]
    private var chain: Task<Void, Never>?
    private var anotherPass = false

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

    /// Every trigger funnels here. Passes are serialized; each caller returns
    /// after its own pass (and the outbox drain it triggers) completes.
    func requestSync(_ reason: SyncReason) async {
        if let chain {
            anotherPass = true
            await chain.value
            return
        }
        let task = Task {
            repeat {
                self.anotherPass = false
                await self.performSync(reason)
            } while self.anotherPass && !Task.isCancelled
        }
        chain = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        chain = nil
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

        // Resume from queued checkpoints before acknowledged disk anchors.
        var resolvedAnchors: [String: HKQueryAnchor] = [:]
        for type in enabled {
            let queuedData: Data?
            do { queuedData = try await outbox.queuedAnchor(for: type.key) }
            catch {
                await status.setError("Unreadable pending batch. Sync stopped to preserve data.")
                await status.setSyncing(false)
                return
            }
            let queuedAnchor = queuedData.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
            if let anchor = anchorCache[type.key] ?? queuedAnchor ?? anchors.load(type.key) {
                resolvedAnchors[type.key] = anchor
            }
        }
        let reimporting = UserDefaults.standard.bool(forKey: SettingsKeys.reimportPending)

        var queued = 0
        var anyFailed = false
        for type in enabled {
            do {
                queued += try await sync(type, anchor: resolvedAnchors[type.key])
            } catch {
                anyFailed = true
                await status.setError("\(type.displayName): \(error.localizedDescription)")
                await log.error("\(type.key): \(error.localizedDescription)")
            }
        }
        if reimporting && !anyFailed {
            UserDefaults.standard.set(false, forKey: SettingsKeys.reimportPending)
            await log.info("full re-import pass completed for all enabled types")
        }
        let force: Bool
        switch reason {
        case .manual, .foreground, .settingsChanged, .reimport: force = true
        case .observer, .backgroundRefresh: force = false
        }
        await outbox.drain(force: force)
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

    func resetAllAnchors() {
        anchorCache = [:]
    }
}
