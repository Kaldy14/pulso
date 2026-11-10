import Foundation

/// Wire-format constants and encoders. The upload body is a bare JSON array
/// of batch elements; outbox files add a small envelope around the same
/// elements (see Batch).
enum Wire {
    /// Uncompressed batch ceiling. JSON this size gzips to roughly 2 MB,
    /// the batch budget from the design doc.
    static let maxBatchBytes = 8 * 1024 * 1024

    static func encodeElements(_ elements: [BatchElement]) throws -> Data {
        try bodyEncoder().encode(elements)
    }

    static func bodyEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func fileEncoder() -> JSONEncoder {
        let encoder = bodyEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func fileDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum BatchSlicer {
    /// Splits elements in half recursively until every slice encodes under
    /// maxBytes. A single element is never split, whatever its size.
    static func slice(_ elements: [BatchElement], maxBytes: Int) throws -> [[BatchElement]] {
        guard elements.count > 1 else { return [elements] }
        let encoded = try Wire.encodeElements(elements)
        guard encoded.count > maxBytes else { return [elements] }
        let mid = elements.count / 2
        return try slice(Array(elements[..<mid]), maxBytes: maxBytes)
            + slice(Array(elements[mid...]), maxBytes: maxBytes)
    }
}

/// Health Auto Export envelope. `id`, `deleted`, `routes` and raw category values
/// extend the format to preserve sample identity, late routes and deletions.
enum HealthAutoExport {
    static let symptomKinds: [String: String] = ["abdominalCramps": "Severity", "acne": "Severity", "appetiteChanges": "AppetiteChanges", "bladderIncontinence": "Severity", "bloating": "Severity", "breastPain": "Severity", "chestTightnessOrPain": "Severity", "chills": "Severity", "constipation": "Severity", "coughing": "Severity", "diarrhea": "Severity", "dizziness": "Severity", "drySkin": "Severity", "fainting": "Severity", "fatigue": "Severity", "fever": "Severity", "generalizedBodyAche": "Severity", "hairLoss": "Severity", "headache": "Severity", "heartburn": "Severity", "hotFlashes": "Severity", "lossOfSmell": "Severity", "lossOfTaste": "Severity", "lowerBackPain": "Severity", "memoryLapse": "Severity", "moodChanges": "Presence", "nausea": "Severity", "nightSweats": "Severity", "pelvicPain": "Severity", "rapidPoundingOrFlutteringHeartbeat": "Severity", "runnyNose": "Severity", "shortnessOfBreath": "Severity", "sinusCongestion": "Severity", "skippedHeartbeat": "Severity", "sleepChanges": "Presence", "soreThroat": "Severity", "vaginalDryness": "Severity", "vomiting": "Severity", "wheezing": "Severity"]

    static func encode(_ elements: [BatchElement]) throws -> Data {
        // Formatters belong to this encoding call: reused without shared mutable state.
        let dates = ExportDates()
        var metrics: [String: [String: JSONValue]] = [:]
        var collections: [String: [JSONValue]] = [:]
        for element in elements {
            switch element {
            case .tombstone(let ids):
                collections["deleted", default: []] += ids.map(JSONValue.string)
            case .sample(let sample):
                var point = sample.details ?? [:]
                point["id"] = .string(sample.uuid)
                point["start"] = .string(dates.timestamp(sample.start))
                point["end"] = .string(dates.timestamp(sample.end))
                point["source"] = .string(sample.source)
                point["date"] = point["start"]
                if let metadata = sample.metadata { point["metadata"] = .object(metadata) }
                switch sample.type {
                case "workout":
                    point["name"] = .string(title(sample.workoutActivityType ?? "workout"))
                    point["duration"] = sample.duration.map(JSONValue.number)
                    point["source"] = .object(["name": .string(sample.source), "identifier": .string(sample.sourceBundleId ?? "")])
                    point["distance"] = sample.totalDistance.map { measurement($0, "m") }
                    point["heartRate"] = sample.averageHeartRate.map { measurement($0, "count/min") }
                    point["heartRateMin"] = sample.minimumHeartRate.map { measurement($0, "count/min") }
                    point["heartRateMax"] = sample.maximumHeartRate.map { measurement($0, "count/min") }
                    point["activeEnergyBurned"] = sample.totalEnergyBurned.map { measurement($0, "kcal") }
                    collections["workouts", default: []].append(.object(point))
                case "Electrocardiogram", "electrocardiogramType", "electrocardiogram":
                    collections["ecg", default: []].append(.object(point))
                case "stateOfMindType", "stateOfMind":
                    point["start"] = .string(sample.start)
                    point["end"] = .string(sample.end)
                    collections["stateOfMind", default: []].append(.object(point))
                case "medicationDoseEventType", "medicationDoseEvent":
                    collections["medications", default: []].append(.object(point))
                case "workoutRoute", "workoutRouteType", "seriesTypeWorkoutRoute":
                    collections["routes", default: []].append(.object(point))
                default:
                    if let kind = symptomKinds[sample.type], case .number(let raw) = sample.value {
                        let severity = kind == "Presence" ? [0: "Present", 1: "Not Present"] : [0: "Unspecified", 1: "Not Present", 2: "Mild", 3: "Moderate", 4: "Severe"]
                        point["name"] = .string(title(sample.type))
                        point["severity"] = .string(severity[Int(raw)] ?? "Unspecified")
                        point["rawValue"] = .number(raw)
                        collections["symptoms", default: []].append(.object(point))
                        continue
                    }
                    if sample.type == "sleepAnalysis", case .string(let stage) = sample.value {
                        if let start = dates.parser.date(from: sample.start), let end = dates.parser.date(from: sample.end) {
                            point["qty"] = .number(end.timeIntervalSince(start) / 3600)
                        }
                        let names = ["asleepREM": "REM", "asleepCore": "Core", "asleepDeep": "Deep", "awake": "Awake", "inBed": "InBed", "asleepUnspecified": "Asleep"]
                        point["value"] = .string(names[stage] ?? stage)
                    }
                    if case .number(let value) = sample.value { point["qty"] = .number(value) }
                    if case .string(let value) = sample.value, sample.type != "sleepAnalysis" { point["value"] = .string(value) }
                    // A raw heart-rate sample has identical min/average/max.
                    if sample.type == "heartRate", let value = point.removeValue(forKey: "qty") {
                        point["Min"] = value; point["Avg"] = value; point["Max"] = value
                    }
                    let name = metricName(sample.type)
                    var metric = metrics[name] ?? ["name": .string(name), "units": .string(sample.type == "sleepAnalysis" ? "hr" : (sample.unit ?? "count")), "data": .array([])]
                    if case .array(var points) = metric["data"] { points.append(.object(point)); metric["data"] = .array(points) }
                    metrics[name] = metric
                }
            }
        }
        var data = collections.mapValues(JSONValue.array)
        data["metrics"] = .array(metrics.keys.sorted().compactMap { metrics[$0].map(JSONValue.object) })
        return try Wire.bodyEncoder().encode(["data": JSONValue.object(data)])
    }

    static func metricName(_ key: String) -> String {
        let aliases = ["activeEnergyBurned": "active_energy", "basalEnergyBurned": "basal_energy_burned",
                       "distanceWalkingRunning": "walking_running_distance", "correlationTypeIdentifierBloodPressure": "blood_pressure"]
        return aliases[key] ?? key.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1_$2", options: .regularExpression).lowercased()
    }

    static func title(_ key: String) -> String {
        metricName(key).replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func measurement(_ value: Double, _ units: String) -> JSONValue {
        .object(["qty": .number(value), "units": .string(units)])
    }

}

private final class ExportDates {
    let parser = ISO8601DateFormatter()
    private var formatters: [String: DateFormatter] = [:]

    func timestamp(_ raw: String) -> String {
        guard let date = parser.date(from: raw) else { return raw }
        let suffix = String(raw.suffix(6)).replacingOccurrences(of: ":", with: "")
        let formatter: DateFormatter
        if let cached = formatters[suffix] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(abbreviation: "GMT" + suffix) ?? TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            formatters[suffix] = formatter
        }
        return formatter.string(from: date)
    }
}
