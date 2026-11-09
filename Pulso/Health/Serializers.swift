import Foundation
import HealthKit

struct SerializerContext: Sendable {
    /// Read at serialize time so long-running backfills track timezone changes.
    let defaultTimeZone: @Sendable () -> TimeZone
    let formatter: TimestampFormatter

    static let live = SerializerContext(defaultTimeZone: { .current }, formatter: TimestampFormatter())
}

enum Serializers {
    /// Fields shared by every sample type. Timestamps keep the sample's own
    /// timezone when it recorded one (HKMetadataKeyTimeZone); otherwise the
    /// device timezone is used and `metadata.timeZone` stays absent so
    /// consumers can tell a recorded timezone from an assumed one.
    static func base(_ sample: HKSample, type: String, context: SerializerContext) -> SampleDTO {
        let recordedZone = (sample.metadata?[HKMetadataKeyTimeZone] as? String).flatMap {
            TimeZone(identifier: $0) ?? TimeZone(abbreviation: $0)
        }
        let zone = recordedZone ?? context.defaultTimeZone()
        return SampleDTO(
            uuid: sample.uuid.uuidString,
            type: type,
            start: context.formatter.string(sample.startDate, in: zone),
            end: context.formatter.string(sample.endDate, in: zone),
            source: sample.sourceRevision.source.name,
            sourceBundleId: sample.sourceRevision.source.bundleIdentifier,
            metadata: recordedZone.map { ["timeZone": .string($0.identifier)] }
        )
    }

    /// `scale` multiplies the converted value before it goes on the wire.
    /// Used for HealthKit's percent types, which read as fractions (0–1)
    /// via HKUnit.percent(): scale 100 delivers human-scale 0–100 under a
    /// "%" unit label.
    static func quantity(
        type: String, unit: HKUnit, unitLabel: String, scale: Double = 1
    ) -> @Sendable (HKSample, SerializerContext) -> SampleDTO? {
        { sample, context in
            guard let quantitySample = sample as? HKQuantitySample else { return nil }
            var dto = base(quantitySample, type: type, context: context)
            dto.value = .number(quantitySample.quantity.doubleValue(for: unit) * scale)
            dto.unit = unitLabel
            return dto
        }
    }

    /// Generic category-sample serializer. `valueName` maps the raw category
    /// value to its wire name; returning nil omits `value` entirely (for
    /// types like mindfulSession whose value is notApplicable — the interval
    /// itself is the data).
    static func category(
        type: String, valueName: @escaping @Sendable (Int) -> String?
    ) -> @Sendable (HKSample, SerializerContext) -> SampleDTO? {
        { sample, context in
            guard let categorySample = sample as? HKCategorySample else { return nil }
            var dto = base(categorySample, type: type, context: context)
            dto.value = valueName(categorySample.value).map(SampleValue.string)
            return dto
        }
    }

    /// Value is notApplicable (the event itself is the data); the one
    /// meaningful HealthKit metadata field becomes metadata.protectionUsed.
    @Sendable
    static func sexualActivity(_ sample: HKSample, context: SerializerContext) -> SampleDTO? {
        guard let categorySample = sample as? HKCategorySample else { return nil }
        var dto = base(categorySample, type: "sexualActivity", context: context)
        if let protectionUsed = categorySample.metadata?[HKMetadataKeySexualActivityProtectionUsed] as? Bool {
            var metadata = dto.metadata ?? [:]
            metadata["protectionUsed"] = .bool(protectionUsed)
            dto.metadata = metadata
        }
        return dto
    }

    static func standHourName(_ rawValue: Int) -> String {
        switch HKCategoryValueAppleStandHour(rawValue: rawValue) {
        case .stood: "stood"
        case .idle: "idle"
        default: "value_\(rawValue)"
        }
    }

    @Sendable
    static func sleep(_ sample: HKSample, context: SerializerContext) -> SampleDTO? {
        guard let categorySample = sample as? HKCategorySample else { return nil }
        var dto = base(categorySample, type: "sleepAnalysis", context: context)
        dto.value = .string(sleepStageName(categorySample.value))
        return dto
    }

    static func sleepStageName(_ rawValue: Int) -> String {
        switch HKCategoryValueSleepAnalysis(rawValue: rawValue) {
        case .inBed: "inBed"
        case .asleepUnspecified: "asleepUnspecified"
        case .awake: "awake"
        case .asleepCore: "asleepCore"
        case .asleepDeep: "asleepDeep"
        case .asleepREM: "asleepREM"
        default: "value_\(rawValue)"
        }
    }

    @Sendable
    static func workout(_ sample: HKSample, context: SerializerContext) -> SampleDTO? {
        guard let workout = sample as? HKWorkout else { return nil }
        var dto = base(workout, type: "workout", context: context)
        dto.workoutActivityType = WorkoutActivityName.name(for: workout.workoutActivityType)
        dto.duration = workout.duration
        // Statistics first; legacy totals (pre-iOS-16 recordings) as fallback.
        // HealthKit synthesizes zero-valued statistics for legacy-total
        // workouts, so zero sums count as absent — otherwise they shadow the
        // real legacy value.
        dto.totalEnergyBurned = positiveSum(workout, .activeEnergyBurned, unit: .kilocalorie())
            ?? workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
        dto.totalBasalEnergyBurned = positiveSum(workout, .basalEnergyBurned, unit: .kilocalorie())
        dto.totalDistance = distanceMeters(of: workout)

        let bpm = HKUnit.count().unitDivided(by: .minute())
        if let heartRate = workout.statistics(for: HKQuantityType(.heartRate)) {
            dto.averageHeartRate = heartRate.averageQuantity()?.doubleValue(for: bpm)
            dto.minimumHeartRate = heartRate.minimumQuantity()?.doubleValue(for: bpm)
            dto.maximumHeartRate = heartRate.maximumQuantity()?.doubleValue(for: bpm)
        }

        // Workouts carry their full metadata (routine names from third-party
        // apps, indoor flag, weather, …). HKTimeZone is folded into the
        // protocol's "timeZone" key by base() rather than passed through raw.
        var metadata = dto.metadata ?? [:]
        for (key, value) in workout.metadata ?? [:] where key != HKMetadataKeyTimeZone {
            metadata[key] = jsonValue(value, context: context)
        }
        dto.metadata = metadata.isEmpty ? nil : metadata
        return dto
    }

    /// Strings, numbers, and booleans pass through natively; HKQuantity,
    /// dates, and anything else are stringified.
    static func jsonValue(_ value: Any, context: SerializerContext) -> JSONValue {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let date as Date:
            return .string(context.formatter.string(date, in: context.defaultTimeZone()))
        default:
            return .string(String(describing: value))
        }
    }

    private static let distanceTypes: [HKQuantityTypeIdentifier] = [
        .distanceWalkingRunning, .distanceCycling, .distanceSwimming,
        .distanceWheelchair, .distanceDownhillSnowSports,
    ]

    private static func distanceMeters(of workout: HKWorkout) -> Double? {
        for identifier in distanceTypes {
            if let meters = positiveSum(workout, identifier, unit: .meter()) {
                return meters
            }
        }
        return workout.totalDistance?.doubleValue(for: .meter())
    }

    private static func positiveSum(
        _ workout: HKWorkout, _ identifier: HKQuantityTypeIdentifier, unit: HKUnit
    ) -> Double? {
        guard let sum = workout.statistics(for: HKQuantityType(identifier))?.sumQuantity() else { return nil }
        let value = sum.doubleValue(for: unit)
        return value > 0 ? value : nil
    }
}

/// Series reads must finish successfully before the enclosing page enters the outbox.
/// An error keeps its anchor unchanged, so incomplete routes/ECGs are retried.
struct DetailedSerializer {
    let store: HKHealthStore

    func serialize(_ sample: HKSample, as type: SyncedType) async throws -> SampleDTO {
        guard var dto = type.serialize(sample, .live) else { throw CocoaError(.coderInvalidValue) }
        var metadata = dto.metadata ?? [:]
        for (key, value) in sample.metadata ?? [:] where key != HKMetadataKeyTimeZone {
            metadata[key] = Serializers.jsonValue(value, context: .live)
        }
        dto.metadata = metadata.isEmpty ? nil : metadata
        if let quantity = sample as? HKQuantitySample, dto.value == nil {
            let units = try await store.preferredUnits(for: [quantity.quantityType])
            guard let unit = units[quantity.quantityType] else { throw CocoaError(.coderInvalidValue) }
            dto.value = .number(quantity.quantity.doubleValue(for: unit))
            dto.unit = unit.unitString
        }
        if let category = sample as? HKCategorySample, HealthAutoExport.symptomKinds[type.key] != nil {
            dto.details = ["cycleStart": .bool(category.metadata?[HKMetadataKeyMenstrualCycleStart] as? Bool ?? false),
                           "userEntered": .bool(category.metadata?[HKMetadataKeyWasUserEntered] as? Bool ?? false)]
        }
        if let pressure = sample as? HKCorrelation {
            var fields: [String: JSONValue] = [:]
            for member in pressure.objects {
                guard let q = member as? HKQuantitySample else { continue }
                let key = q.quantityType.identifier == HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue ? "systolic" : "diastolic"
                fields[key] = .number(q.quantity.doubleValue(for: .millimeterOfMercury()))
            }
            dto.details = fields
            dto.unit = "mmHg"
        }
        if #available(iOS 18.0, *), let mood = sample as? HKStateOfMind {
            dto.details = ["kind": .string(mood.kind == .dailyMood ? "daily_mood" : "momentary_emotion"), "valence": .number(mood.valence),
                           "labels": .array(mood.labels.map { .string(Self.moodLabel[$0.rawValue] ?? "unknown_\($0.rawValue)") }),
                           "associations": .array(mood.associations.map { .string(Self.moodAssociation[$0.rawValue] ?? "unknown_\($0.rawValue)") }),
                           "valenceClassification": .string(Self.moodValenceClassification[mood.valenceClassification.rawValue] ?? "unknown")]
        }
        if #available(iOS 26.0, *), let dose = sample as? HKMedicationDoseEvent {
            var details: [String: JSONValue] = ["status": .string(String(describing: dose.logStatus)),
                "medicationConceptIdentifier": .string(String(describing: dose.medicationConceptIdentifier)),
                "units": .string(dose.unit.unitString)]
            details["dosage"] = dose.doseQuantity.map(JSONValue.number)
            details["scheduledDosage"] = dose.scheduledDoseQuantity.map(JSONValue.number)
            details["scheduledDate"] = dose.scheduledDate.map { .string(Self.date($0)) }
            let medications: [HKUserAnnotatedMedication] = try await withCheckedThrowingContinuation { continuation in
                var values: [HKUserAnnotatedMedication] = []
                store.execute(HKUserAnnotatedMedicationQuery(predicate: nil, limit: HKObjectQueryNoLimit) { _, medication, done, error in
                    if let error { continuation.resume(throwing: error); return }
                    if let medication { values.append(medication) }
                    if done { continuation.resume(returning: values) }
                })
            }
            if let medication = medications.first(where: { $0.medication.identifier == dose.medicationConceptIdentifier }) {
                details["displayText"] = .string(medication.medication.displayText)
                details["nickname"] = medication.nickname.map(JSONValue.string)
                details["isArchived"] = .bool(medication.isArchived)
                details["codings"] = .array(medication.medication.relatedCodings.map {
                    .object(["code": .string($0.code), "system": .string($0.system), "version": .string($0.version ?? "")])
                })
            }
            let statuses = [1: "Not Interacted", 2: "Notification Not Sent", 3: "Snoozed", 4: "Taken", 5: "Skipped", 6: "Not Logged"]
            details["status"] = .string(statuses[dose.logStatus.rawValue] ?? "Unspecified")
            dto.details = details
        }
        if let route = sample as? HKWorkoutRoute {
            dto.details = ["route": .array(try await routePoints(route))]
            // A route can arrive after its workout. Export independently too, linked
            // by the workout UUID, so an already-acknowledged workout loses no GPS data.
            let candidates = try await samples(HKObjectType.workoutType(), predicate: HKQuery.predicateForSamples(withStart: route.startDate, end: route.endDate))
            var workouts: [HKSample] = []
            for case let workout as HKWorkout in candidates {
                let associated = try await samples(HKSeriesType.workoutRoute(), predicate: HKQuery.predicateForObjects(from: workout))
                if associated.contains(where: { $0.uuid == route.uuid }) { workouts.append(workout) }
            }
            dto.details?["workoutIds"] = .array(workouts.map { .string($0.uuid.uuidString) })
        }
        if let ecg = sample as? HKElectrocardiogram {
            let voltages: [JSONValue] = try await withCheckedThrowingContinuation { continuation in
                var values: [JSONValue] = []
                store.execute(HKElectrocardiogramQuery(ecg) { _, result in
                    switch result {
                    case .measurement(let measurement):
                        if let voltage = measurement.quantity(for: .appleWatchSimilarToLeadI) {
                            values.append(.object(["date": .number(ecg.startDate.timeIntervalSince1970 + measurement.timeSinceSampleStart),
                                "voltage": .number(voltage.doubleValue(for: .voltUnit(with: .micro))), "units": .string("mcV")]))
                        }
                    case .done: continuation.resume(returning: values)
                    case .error(let error): continuation.resume(throwing: error)
                    @unknown default: continuation.resume(throwing: CocoaError(.coderInvalidValue))
                    }
                })
            }
            dto.details = ["classification": .string(Self.ecgClassification(ecg.classification)),
                "numberOfVoltageMeasurements": .number(Double(ecg.numberOfVoltageMeasurements)),
                "voltageMeasurements": .array(voltages)]
            dto.details?["samplingFrequency"] = ecg.samplingFrequency.map { .number($0.doubleValue(for: .hertz())) }
            dto.details?["averageHeartRate"] = ecg.averageHeartRate.map { .number($0.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))) }
        }
        if let workout = sample as? HKWorkout {
            var fields: [String: JSONValue] = [:]
            let predicate = HKQuery.predicateForObjects(from: workout)
            let routes = try await samples(HKSeriesType.workoutRoute(), predicate: predicate)
            var points: [JSONValue] = []
            for case let route as HKWorkoutRoute in routes { points += try await routePoints(route) }
            fields["route"] = .array(points)
            for (identifier, key) in [(HKQuantityTypeIdentifier.heartRate, "heartRateData"), (.heartRateRecoveryOneMinute, "heartRateRecovery")] {
                let interval = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: [.strictStartDate, .strictEndDate])
                let quantities = try await samples(HKQuantityType(identifier), predicate: identifier == .heartRate ? interval : predicate)
                fields[key] = .array(quantities.compactMap { sample in
                    guard let q = sample as? HKQuantitySample else { return nil }
                    return .object(["id": .string(q.uuid.uuidString), "date": .string(Self.date(q.startDate)),
                        "qty": .number(q.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))),
                        "units": .string("count/min"), "source": .string(q.sourceRevision.source.name)])
                })
            }
            fields["splits"] = .array((workout.workoutEvents ?? []).filter { $0.type == .lap || $0.type == .segment }.map {
                .object(["start": .string(Self.date($0.dateInterval.start)), "end": .string(Self.date($0.dateInterval.end)),
                         "duration": .number($0.dateInterval.duration), "type": .number(Double($0.type.rawValue)),
                         "metadata": .object(($0.metadata ?? [:]).mapValues { Serializers.jsonValue($0, context: .live) })])
            })
            for (metadataKey, key) in [(HKMetadataKeyElevationAscended, "elevationUp"), (HKMetadataKeyElevationDescended, "elevationDown")] {
                if let elevation = workout.metadata?[metadataKey] as? HKQuantity {
                    fields[key] = .object(["qty": .number(elevation.doubleValue(for: .meter())), "units": .string("m")])
                }
            }
            let statisticTypes = Set(workout.allStatistics.keys)
            let units = try await store.preferredUnits(for: statisticTypes)
            fields["statistics"] = .array(workout.allStatistics.keys.sorted { $0.identifier < $1.identifier }.compactMap { type in
                guard let statistics = workout.allStatistics[type], let unit = units[type] else { return nil }
                var result: [String: JSONValue] = ["identifier": .string(type.identifier), "units": .string(unit.unitString)]
                result["sum"] = statistics.sumQuantity().map { .number($0.doubleValue(for: unit)) }
                result["average"] = statistics.averageQuantity().map { .number($0.doubleValue(for: unit)) }
                result["minimum"] = statistics.minimumQuantity().map { .number($0.doubleValue(for: unit)) }
                result["maximum"] = statistics.maximumQuantity().map { .number($0.doubleValue(for: unit)) }
                return .object(result)
            })
            let recoveryInterval = HKQuery.predicateForSamples(withStart: workout.endDate, end: workout.endDate.addingTimeInterval(180), options: [.strictStartDate, .strictEndDate])
            let recovery = try await samples(HKQuantityType(.heartRate), predicate: recoveryInterval)
            fields["heartRateAfterWorkout"] = .array(recovery.compactMap { sample in
                guard let q = sample as? HKQuantitySample else { return nil }
                return .object(["id": .string(q.uuid.uuidString), "date": .string(Self.date(q.startDate)),
                    "qty": .number(q.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))),
                    "units": .string("count/min"), "source": .string(q.sourceRevision.source.name)])
            })
            dto.details = fields
        }
        return dto
    }

    private func samples(_ type: HKSampleType, predicate: NSPredicate) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            store.execute(HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            })
        }
    }

    private func routePoints(_ route: HKWorkoutRoute) async throws -> [JSONValue] {
        try await withCheckedThrowingContinuation { continuation in
            var points: [JSONValue] = []
            store.execute(HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error { continuation.resume(throwing: error); return }
                points += (locations ?? []).map { location in
                    .object(["latitude": .number(location.coordinate.latitude), "longitude": .number(location.coordinate.longitude),
                             "altitude": .number(location.altitude), "timestamp": .string(Self.date(location.timestamp)),
                             "speed": .number(location.speed), "course": .number(location.course),
                             "horizontalAccuracy": .number(location.horizontalAccuracy), "verticalAccuracy": .number(location.verticalAccuracy)])
                }
                if done { continuation.resume(returning: points) }
            })
        }
    }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.string(from: date)
    }
}

extension DetailedSerializer {
    static let moodLabel: [Int: String] = [1: "amazed", 2: "amused", 3: "angry", 4: "anxious", 5: "ashamed", 6: "brave", 7: "calm", 8: "content", 9: "disappointed", 10: "discouraged", 11: "disgusted", 12: "embarrassed", 13: "excited", 14: "frustrated", 15: "grateful", 16: "guilty", 17: "happy", 18: "hopeless", 19: "irritated", 20: "jealous", 21: "joyful", 22: "lonely", 23: "passionate", 24: "peaceful", 25: "proud", 26: "relieved", 27: "sad", 28: "scared", 29: "stressed", 30: "surprised", 31: "worried", 32: "annoyed", 33: "confident", 34: "drained", 35: "hopeful", 36: "indifferent", 37: "overwhelmed", 38: "satisfied"]
    static let moodAssociation: [Int: String] = [1: "community", 2: "current_events", 3: "dating", 4: "education", 5: "family", 6: "fitness", 7: "friends", 8: "health", 9: "hobbies", 10: "identity", 11: "money", 12: "partner", 13: "self_care", 14: "spirituality", 15: "tasks", 16: "travel", 17: "work", 18: "weather"]
    static let moodValenceClassification: [Int: String] = [1: "very_unpleasant", 2: "unpleasant", 3: "slightly_unpleasant", 4: "neutral", 5: "slightly_pleasant", 6: "pleasant", 7: "very_pleasant"]
}

extension DetailedSerializer {
    static func ecgClassification(_ value: HKElectrocardiogram.Classification) -> String {
        switch value {
        case .notSet: "Not Set"
        case .sinusRhythm: "Sinus Rhythm"
        case .atrialFibrillation: "Atrial Fibrillation"
        case .inconclusiveLowHeartRate: "Inconclusive Low Heart Rate"
        case .inconclusiveHighHeartRate: "Inconclusive High Heart Rate"
        case .inconclusivePoorReading: "Inconclusive Poor Recording"
        case .inconclusiveOther: "Inconclusive"
        case .unrecognized: "Unrecognized"
        @unknown default: "Unrecognized"
        }
    }
}
