import Foundation
import HealthKit

/// One syncable HealthKit type: its wire key, how eagerly HealthKit may wake
/// us for it, and how its samples serialize. Adding a type is a table row.
struct SyncedType: Identifiable {
    let key: String // wire "type" value and persistence key
    let displayName: String
    let group: String // UI section
    let sampleType: HKSampleType
    let frequency: HKUpdateFrequency
    let serialize: @Sendable (HKSample, SerializerContext) -> SampleDTO?

    var id: String { key }
}

enum TypeRegistry {
    enum Group {
        static let sleep = "Sleep & Circadian"
        static let workouts = "Workouts"
        static let energy = "Energy & Activity"
        static let cardio = "Cardio & Recovery"
        static let body = "Body"
        static let gait = "Running & Gait"
        static let audio = "Audio Exposure"
        static let nutrition = "Nutrition"
        static let lifestyle = "Lifestyle"
    }

    private static let bpm = HKUnit.count().unitDivided(by: .minute())
    private static let mps = HKUnit.meter().unitDivided(by: .second())

    /// Shorthand: one registry row per quantity type. Everything defaults to
    /// .hourly — HealthKit's cap for most quantity types anyway.
    private static func quantity(
        _ identifier: HKQuantityTypeIdentifier, key: String, name: String, group: String,
        unit: HKUnit, label: String, scale: Double = 1
    ) -> SyncedType {
        SyncedType(
            key: key, displayName: name, group: group,
            sampleType: HKQuantityType(identifier), frequency: .hourly,
            serialize: Serializers.quantity(type: key, unit: unit, unitLabel: label, scale: scale)
        )
    }

    // MARK: - Groups
    // Sleep and workouts are what this app exists for — they get .immediate
    // background delivery. Everything else is capped at .hourly by HealthKit.

    private static let sleepAndCircadian: [SyncedType] = {
        var types: [SyncedType] = [
            SyncedType(
                key: "sleepAnalysis", displayName: "Sleep", group: Group.sleep,
                sampleType: HKCategoryType(.sleepAnalysis),
                frequency: .immediate, serialize: Serializers.sleep
            ),
            quantity(.timeInDaylight, key: "timeInDaylight", name: "Time in Daylight",
                     group: Group.sleep, unit: .minute(), label: "min"),
            quantity(.appleSleepingWristTemperature, key: "appleSleepingWristTemperature",
                     name: "Sleeping Wrist Temperature", group: Group.sleep,
                     unit: .degreeCelsius(), label: "°C"),
        ]
        if #available(iOS 18.0, *) {
            types.append(quantity(.appleSleepingBreathingDisturbances, key: "appleSleepingBreathingDisturbances",
                                  name: "Breathing Disturbances", group: Group.sleep,
                                  unit: .count(), label: "count"))
        }
        types += [
            SyncedType(
                key: "appleStandHour", displayName: "Stand Hours", group: Group.sleep,
                sampleType: HKCategoryType(.appleStandHour),
                frequency: .hourly,
                serialize: Serializers.category(type: "appleStandHour", valueName: Serializers.standHourName)
            ),
            SyncedType(
                key: "mindfulSession", displayName: "Mindful Sessions", group: Group.sleep,
                sampleType: HKCategoryType(.mindfulSession),
                frequency: .hourly,
                // Value is notApplicable; the interval itself is the session.
                serialize: Serializers.category(type: "mindfulSession", valueName: { _ in nil })
            ),
        ]
        return types
    }()

    private static let workouts: [SyncedType] = [
        SyncedType(
            key: "workout", displayName: "Workouts", group: Group.workouts,
            sampleType: HKObjectType.workoutType(),
            frequency: .immediate, serialize: Serializers.workout
        ),
    ]

    private static let energyAndActivity: [SyncedType] = [
        quantity(.stepCount, key: "stepCount", name: "Steps",
                 group: Group.energy, unit: .count(), label: "count"),
        quantity(.activeEnergyBurned, key: "activeEnergyBurned", name: "Active Energy",
                 group: Group.energy, unit: .kilocalorie(), label: "kcal"),
        quantity(.basalEnergyBurned, key: "basalEnergyBurned", name: "Basal Energy",
                 group: Group.energy, unit: .kilocalorie(), label: "kcal"),
        quantity(.physicalEffort, key: "physicalEffort", name: "Physical Effort",
                 group: Group.energy,
                 unit: .kilocalorie().unitDivided(by: .hour().unitMultiplied(by: .gramUnit(with: .kilo))),
                 label: "kcal/hr·kg"),
        quantity(.appleExerciseTime, key: "appleExerciseTime", name: "Exercise Time",
                 group: Group.energy, unit: .minute(), label: "min"),
        quantity(.appleStandTime, key: "appleStandTime", name: "Stand Time",
                 group: Group.energy, unit: .minute(), label: "min"),
        quantity(.flightsClimbed, key: "flightsClimbed", name: "Flights Climbed",
                 group: Group.energy, unit: .count(), label: "count"),
        quantity(.distanceWalkingRunning, key: "distanceWalkingRunning", name: "Walking + Running Distance",
                 group: Group.energy, unit: .meter(), label: "m"),
        quantity(.distanceCycling, key: "distanceCycling", name: "Cycling Distance",
                 group: Group.energy, unit: .meter(), label: "m"),
        quantity(.distanceSwimming, key: "distanceSwimming", name: "Swimming Distance",
                 group: Group.energy, unit: .meter(), label: "m"),
        quantity(.swimmingStrokeCount, key: "swimmingStrokeCount", name: "Swimming Strokes",
                 group: Group.energy, unit: .count(), label: "count"),
    ]

    private static let cardioAndRecovery: [SyncedType] = [
        quantity(.heartRate, key: "heartRate", name: "Heart Rate",
                 group: Group.cardio, unit: bpm, label: "count/min"),
        quantity(.restingHeartRate, key: "restingHeartRate", name: "Resting Heart Rate",
                 group: Group.cardio, unit: bpm, label: "count/min"),
        quantity(.heartRateVariabilitySDNN, key: "heartRateVariabilitySDNN", name: "HRV (SDNN)",
                 group: Group.cardio, unit: .secondUnit(with: .milli), label: "ms"),
        quantity(.vo2Max, key: "vo2Max", name: "VO₂ Max",
                 group: Group.cardio,
                 unit: .literUnit(with: .milli)
                     .unitDivided(by: .gramUnit(with: .kilo).unitMultiplied(by: .minute())),
                 label: "mL/(kg·min)"),
        quantity(.heartRateRecoveryOneMinute, key: "heartRateRecoveryOneMinute", name: "Heart Rate Recovery",
                 group: Group.cardio, unit: bpm, label: "count/min"),
        quantity(.walkingHeartRateAverage, key: "walkingHeartRateAverage", name: "Walking Heart Rate Avg",
                 group: Group.cardio, unit: bpm, label: "count/min"),
        quantity(.oxygenSaturation, key: "oxygenSaturation", name: "Blood Oxygen",
                 group: Group.cardio, unit: .percent(), label: "%", scale: 100),
        quantity(.respiratoryRate, key: "respiratoryRate", name: "Respiratory Rate",
                 group: Group.cardio, unit: bpm, label: "count/min"),
    ]

    private static let body: [SyncedType] = [
        quantity(.bodyMass, key: "bodyMass", name: "Body Mass",
                 group: Group.body, unit: .gramUnit(with: .kilo), label: "kg"),
        quantity(.bodyFatPercentage, key: "bodyFatPercentage", name: "Body Fat",
                 group: Group.body, unit: .percent(), label: "%", scale: 100),
        quantity(.leanBodyMass, key: "leanBodyMass", name: "Lean Body Mass",
                 group: Group.body, unit: .gramUnit(with: .kilo), label: "kg"),
        quantity(.bodyMassIndex, key: "bodyMassIndex", name: "Body Mass Index",
                 group: Group.body, unit: .count(), label: "count"),
        quantity(.waistCircumference, key: "waistCircumference", name: "Waist Circumference",
                 group: Group.body, unit: .meterUnit(with: .centi), label: "cm"),
        quantity(.height, key: "height", name: "Height",
                 group: Group.body, unit: .meterUnit(with: .centi), label: "cm"),
    ]

    private static let runningAndGait: [SyncedType] = [
        quantity(.runningPower, key: "runningPower", name: "Running Power",
                 group: Group.gait, unit: .watt(), label: "W"),
        quantity(.runningSpeed, key: "runningSpeed", name: "Running Speed",
                 group: Group.gait, unit: mps, label: "m/s"),
        quantity(.runningStrideLength, key: "runningStrideLength", name: "Running Stride Length",
                 group: Group.gait, unit: .meter(), label: "m"),
        quantity(.runningVerticalOscillation, key: "runningVerticalOscillation", name: "Vertical Oscillation",
                 group: Group.gait, unit: .meterUnit(with: .centi), label: "cm"),
        quantity(.runningGroundContactTime, key: "runningGroundContactTime", name: "Ground Contact Time",
                 group: Group.gait, unit: .secondUnit(with: .milli), label: "ms"),
        quantity(.walkingSpeed, key: "walkingSpeed", name: "Walking Speed",
                 group: Group.gait, unit: mps, label: "m/s"),
        quantity(.walkingStepLength, key: "walkingStepLength", name: "Walking Step Length",
                 group: Group.gait, unit: .meterUnit(with: .centi), label: "cm"),
        quantity(.walkingAsymmetryPercentage, key: "walkingAsymmetryPercentage", name: "Walking Asymmetry",
                 group: Group.gait, unit: .percent(), label: "%", scale: 100),
        quantity(.walkingDoubleSupportPercentage, key: "walkingDoubleSupportPercentage", name: "Double Support",
                 group: Group.gait, unit: .percent(), label: "%", scale: 100),
        quantity(.appleWalkingSteadiness, key: "appleWalkingSteadiness", name: "Walking Steadiness",
                 group: Group.gait, unit: .percent(), label: "%", scale: 100),
        quantity(.sixMinuteWalkTestDistance, key: "sixMinuteWalkTestDistance", name: "Six-Minute Walk",
                 group: Group.gait, unit: .meter(), label: "m"),
        quantity(.stairAscentSpeed, key: "stairAscentSpeed", name: "Stair Ascent Speed",
                 group: Group.gait, unit: mps, label: "m/s"),
        quantity(.stairDescentSpeed, key: "stairDescentSpeed", name: "Stair Descent Speed",
                 group: Group.gait, unit: mps, label: "m/s"),
    ]

    private static let audioExposure: [SyncedType] = [
        quantity(.environmentalAudioExposure, key: "environmentalAudioExposure", name: "Environmental Sound",
                 group: Group.audio, unit: .decibelAWeightedSoundPressureLevel(), label: "dBASPL"),
        quantity(.headphoneAudioExposure, key: "headphoneAudioExposure", name: "Headphone Audio",
                 group: Group.audio, unit: .decibelAWeightedSoundPressureLevel(), label: "dBASPL"),
    ]

    private static let nutrition: [SyncedType] = [
        quantity(.dietaryEnergyConsumed, key: "dietaryEnergyConsumed", name: "Dietary Energy",
                 group: Group.nutrition, unit: .kilocalorie(), label: "kcal"),
        quantity(.dietaryProtein, key: "dietaryProtein", name: "Protein",
                 group: Group.nutrition, unit: .gram(), label: "g"),
        quantity(.dietaryCarbohydrates, key: "dietaryCarbohydrates", name: "Carbohydrates",
                 group: Group.nutrition, unit: .gram(), label: "g"),
        quantity(.dietaryFatTotal, key: "dietaryFatTotal", name: "Total Fat",
                 group: Group.nutrition, unit: .gram(), label: "g"),
        quantity(.dietaryFiber, key: "dietaryFiber", name: "Fiber",
                 group: Group.nutrition, unit: .gram(), label: "g"),
        quantity(.dietarySugar, key: "dietarySugar", name: "Sugar",
                 group: Group.nutrition, unit: .gram(), label: "g"),
        quantity(.dietarySodium, key: "dietarySodium", name: "Sodium",
                 group: Group.nutrition, unit: .gramUnit(with: .milli), label: "mg"),
        quantity(.dietaryWater, key: "dietaryWater", name: "Water",
                 group: Group.nutrition, unit: .literUnit(with: .milli), label: "mL"),
        quantity(.dietaryCaffeine, key: "dietaryCaffeine", name: "Caffeine",
                 group: Group.nutrition, unit: .gramUnit(with: .milli), label: "mg"),
        quantity(.numberOfAlcoholicBeverages, key: "numberOfAlcoholicBeverages", name: "Alcoholic Beverages",
                 group: Group.nutrition, unit: .count(), label: "count"),
    ]

    private static let lifestyle: [SyncedType] = [
        SyncedType(
            key: "sexualActivity", displayName: "Sexual Activity", group: Group.lifestyle,
            sampleType: HKCategoryType(.sexualActivity),
            frequency: .hourly,
            serialize: Serializers.sexualActivity
        ),
    ]

    // MARK: - Public surface

    private static let original: [SyncedType] =
        sleepAndCircadian + workouts + energyAndActivity + cardioAndRecovery
            + body + runningAndGait + audioExposure + nutrition + lifestyle

    static let all: [SyncedType] = {
        var types = original
        var identifiers = Set(types.map { $0.sampleType.identifier })
        for (identifier, kind, minimum) in sdkCatalogue {
            guard UIDeviceVersion.supports(minimum), !identifiers.contains(identifier) else { continue }
            let sample: HKSampleType?
            if kind == "Quantity" {
                sample = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier))
            } else {
                sample = HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: identifier))
            }
            if let sample {
                types.append(row(sample, group: kind == "Category" ? "Symptoms & Categories" : "Other Metrics"))
                identifiers.insert(identifier)
            }
        }
        types += [row(HKSeriesType.workoutRoute(), key: "workoutRoute", group: Group.workouts),
                  row(HKObjectType.electrocardiogramType(), key: "electrocardiogram", group: Group.cardio),
                  row(HKObjectType.correlationType(forIdentifier: .bloodPressure)!, key: "bloodPressure", group: Group.cardio)]
        if #available(iOS 18.0, *) { types.append(row(HKObjectType.stateOfMindType(), key: "stateOfMind", group: "Mental Health")) }
        if #available(iOS 26.0, *) { types.append(row(HKObjectType.medicationDoseEventType(), key: "medicationDoseEvent", group: "Medications")) }
        return types
    }()

    private static func row(_ type: HKSampleType, key explicitKey: String? = nil, group: String) -> SyncedType {
        let name = type.identifier.replacingOccurrences(of: "HK", with: "")
            .replacingOccurrences(of: "QuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "CategoryTypeIdentifier", with: "")
        let key = explicitKey ?? (name.prefix(1).lowercased() + name.dropFirst())
        return SyncedType(key: key, displayName: name, group: group, sampleType: type,
                          frequency: .immediate, serialize: { sample, context in
            var dto = Serializers.base(sample, type: key, context: context)
            if let category = sample as? HKCategorySample { dto.value = .number(Double(category.value)) }
            return dto
        })
    }

    /// Group names in registry order, for UI sections.
    static let groups: [String] = {
        var seen = Set<String>()
        return all.compactMap { seen.insert($0.group).inserted ? $0.group : nil }
    }()

    static func type(for key: String) -> SyncedType? {
        all.first { $0.key == key }
    }

    static var readTypes: Set<HKObjectType> {
        // Correlations inherit member permissions. Per-object types (medications)
        // must never enter the ordinary authorization/status APIs: HealthKit throws
        // an Objective-C exception rather than a catchable Swift error.
        Set(all.filter {
            // Dose events inherit medication permissions but report false for
            // requiresPerObjectAuthorization(), so exclude them explicitly too.
            $0.key != "medicationDoseEvent" && !($0.sampleType is HKCorrelationType)
                && !$0.sampleType.requiresPerObjectAuthorization()
        }.map { $0.sampleType as HKObjectType })
    }
}
private enum UIDeviceVersion {
    static func supports(_ version: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: parts[0], minorVersion: parts.count > 1 ? parts[1] : 0, patchVersion: 0))
    }
}

// BEGIN SDK CATALOGUE — generated by scripts/generate-health-types.py
extension TypeRegistry {
    static let sdkCatalogue: [(String, String, String)] = [
        ("HKQuantityTypeIdentifierAppleSleepingWristTemperature", "Quantity", "16.0"),
        ("HKQuantityTypeIdentifierBodyFatPercentage", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierBodyMass", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierBodyMassIndex", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierElectrodermalActivity", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierHeight", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierLeanBodyMass", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierWaistCircumference", "Quantity", "11.0"),
        ("HKQuantityTypeIdentifierActiveEnergyBurned", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierAppleExerciseTime", "Quantity", "9.3"),
        ("HKQuantityTypeIdentifierAppleMoveTime", "Quantity", "14.5"),
        ("HKQuantityTypeIdentifierAppleStandTime", "Quantity", "13.0"),
        ("HKQuantityTypeIdentifierBasalEnergyBurned", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierCrossCountrySkiingSpeed", "Quantity", "18.0"),
        ("HKQuantityTypeIdentifierCyclingCadence", "Quantity", "17.0"),
        ("HKQuantityTypeIdentifierCyclingFunctionalThresholdPower", "Quantity", "17.0"),
        ("HKQuantityTypeIdentifierCyclingPower", "Quantity", "17.0"),
        ("HKQuantityTypeIdentifierCyclingSpeed", "Quantity", "17.0"),
        ("HKQuantityTypeIdentifierDistanceCrossCountrySkiing", "Quantity", "18.0"),
        ("HKQuantityTypeIdentifierDistanceCycling", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDistanceDownhillSnowSports", "Quantity", "11.2"),
        ("HKQuantityTypeIdentifierDistancePaddleSports", "Quantity", "18.0"),
        ("HKQuantityTypeIdentifierDistanceRowing", "Quantity", "18.0"),
        ("HKQuantityTypeIdentifierDistanceSkatingSports", "Quantity", "18.0"),
        ("HKQuantityTypeIdentifierDistanceSwimming", "Quantity", "10.0"),
        ("HKQuantityTypeIdentifierDistanceWalkingRunning", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDistanceWheelchair", "Quantity", "10.0"),
        ("HKQuantityTypeIdentifierEstimatedWorkoutEffortScore", "Quantity", "18.0"),
        ("HKQuantityTypeIdentifierFlightsClimbed", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierNikeFuel", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierPaddleSportsSpeed", "Quantity", "18.0"),
        ("HKQuantityTypeIdentifierPhysicalEffort", "Quantity", "17.0"),
        ("HKQuantityTypeIdentifierPushCount", "Quantity", "10.0"),
        ("HKQuantityTypeIdentifierRowingSpeed", "Quantity", "18.0"),
        ("HKQuantityTypeIdentifierRunningPower", "Quantity", "16.0"),
        ("HKQuantityTypeIdentifierRunningSpeed", "Quantity", "16.0"),
        ("HKQuantityTypeIdentifierStepCount", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierSwimmingStrokeCount", "Quantity", "10.0"),
        ("HKQuantityTypeIdentifierUnderwaterDepth", "Quantity", "16.0"),
        ("HKQuantityTypeIdentifierWorkoutEffortScore", "Quantity", "18.0"),
        ("HKQuantityTypeIdentifierEnvironmentalAudioExposure", "Quantity", "13.0"),
        ("HKQuantityTypeIdentifierEnvironmentalSoundReduction", "Quantity", "16.0"),
        ("HKQuantityTypeIdentifierHeadphoneAudioExposure", "Quantity", "13.0"),
        ("HKQuantityTypeIdentifierAtrialFibrillationBurden", "Quantity", "16.0"),
        ("HKQuantityTypeIdentifierHeartRate", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierHeartRateRecoveryOneMinute", "Quantity", "16.0"),
        ("HKQuantityTypeIdentifierHeartRateVariabilityRMSSD", "Quantity", "27.0"),
        ("HKQuantityTypeIdentifierHeartRateVariabilitySDNN", "Quantity", "11.0"),
        ("HKQuantityTypeIdentifierPeripheralPerfusionIndex", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierRestingHeartRate", "Quantity", "11.0"),
        ("HKQuantityTypeIdentifierVO2Max", "Quantity", "11.0"),
        ("HKQuantityTypeIdentifierWalkingHeartRateAverage", "Quantity", "11.0"),
        ("HKQuantityTypeIdentifierAppleWalkingSteadiness", "Quantity", "15.0"),
        ("HKQuantityTypeIdentifierRunningGroundContactTime", "Quantity", "16.0"),
        ("HKQuantityTypeIdentifierRunningStrideLength", "Quantity", "16.0"),
        ("HKQuantityTypeIdentifierRunningVerticalOscillation", "Quantity", "16.0"),
        ("HKQuantityTypeIdentifierSixMinuteWalkTestDistance", "Quantity", "14.0"),
        ("HKQuantityTypeIdentifierStairAscentSpeed", "Quantity", "14.0"),
        ("HKQuantityTypeIdentifierStairDescentSpeed", "Quantity", "14.0"),
        ("HKQuantityTypeIdentifierWalkingAsymmetryPercentage", "Quantity", "14.0"),
        ("HKQuantityTypeIdentifierWalkingDoubleSupportPercentage", "Quantity", "14.0"),
        ("HKQuantityTypeIdentifierWalkingSpeed", "Quantity", "14.0"),
        ("HKQuantityTypeIdentifierWalkingStepLength", "Quantity", "14.0"),
        ("HKQuantityTypeIdentifierDietaryBiotin", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryCaffeine", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryCalcium", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryCarbohydrates", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryChloride", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryCholesterol", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryChromium", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryCopper", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryEnergyConsumed", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryFatMonounsaturated", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryFatPolyunsaturated", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryFatSaturated", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryFatTotal", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryFiber", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryFolate", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryIodine", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryIron", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryMagnesium", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryManganese", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryMolybdenum", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryNiacin", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryPantothenicAcid", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryPhosphorus", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryPotassium", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryProtein", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryRiboflavin", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietarySelenium", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietarySodium", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietarySugar", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryThiamin", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryVitaminA", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryVitaminB12", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryVitaminB6", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryVitaminC", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryVitaminD", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryVitaminE", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryVitaminK", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierDietaryWater", "Quantity", "9.0"),
        ("HKQuantityTypeIdentifierDietaryZinc", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierBloodAlcoholContent", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierBloodPressureDiastolic", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierBloodPressureSystolic", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierInsulinDelivery", "Quantity", "11.0"),
        ("HKQuantityTypeIdentifierNumberOfAlcoholicBeverages", "Quantity", "15.0"),
        ("HKQuantityTypeIdentifierNumberOfTimesFallen", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierTimeInDaylight", "Quantity", "17.0"),
        ("HKQuantityTypeIdentifierUVExposure", "Quantity", "9.0"),
        ("HKQuantityTypeIdentifierWaterTemperature", "Quantity", "16.0"),
        ("HKQuantityTypeIdentifierBasalBodyTemperature", "Quantity", "9.0"),
        ("HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances", "Quantity", "18.0"),
        ("HKQuantityTypeIdentifierForcedExpiratoryVolume1", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierForcedVitalCapacity", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierInhalerUsage", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierOxygenSaturation", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierPeakExpiratoryFlowRate", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierRespiratoryRate", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierBloodGlucose", "Quantity", "8.0"),
        ("HKQuantityTypeIdentifierBodyTemperature", "Quantity", "8.0"),
        ("HKCategoryTypeIdentifierAppleStandHour", "Category", "9.0"),
        ("HKCategoryTypeIdentifierEnvironmentalAudioExposureEvent", "Category", "14.0"),
        ("HKCategoryTypeIdentifierHeadphoneAudioExposureEvent", "Category", "14.2"),
        ("HKCategoryTypeIdentifierHighHeartRateEvent", "Category", "12.2"),
        ("HKCategoryTypeIdentifierHypertensionEvent", "Category", "26.2"),
        ("HKCategoryTypeIdentifierIrregularHeartRhythmEvent", "Category", "12.2"),
        ("HKCategoryTypeIdentifierLowCardioFitnessEvent", "Category", "14.3"),
        ("HKCategoryTypeIdentifierLowHeartRateEvent", "Category", "12.2"),
        ("HKCategoryTypeIdentifierMindfulSession", "Category", "10.0"),
        ("HKCategoryTypeIdentifierAppleWalkingSteadinessEvent", "Category", "15.0"),
        ("HKCategoryTypeIdentifierHandwashingEvent", "Category", "14.0"),
        ("HKCategoryTypeIdentifierToothbrushingEvent", "Category", "13.0"),
        ("HKCategoryTypeIdentifierBleedingAfterMenopause", "Category", "27.0"),
        ("HKCategoryTypeIdentifierBleedingAfterPregnancy", "Category", "18.0"),
        ("HKCategoryTypeIdentifierBleedingDuringPregnancy", "Category", "18.0"),
        ("HKCategoryTypeIdentifierCervicalMucusQuality", "Category", "9.0"),
        ("HKCategoryTypeIdentifierContraceptive", "Category", "14.3"),
        ("HKCategoryTypeIdentifierInfrequentMenstrualCycles", "Category", "16.0"),
        ("HKCategoryTypeIdentifierIntermenstrualBleeding", "Category", "9.0"),
        ("HKCategoryTypeIdentifierIrregularMenstrualCycles", "Category", "16.0"),
        ("HKCategoryTypeIdentifierLactation", "Category", "14.3"),
        ("HKCategoryTypeIdentifierMenopausalState", "Category", "27.0"),
        ("HKCategoryTypeIdentifierMenstrualFlow", "Category", "9.0"),
        ("HKCategoryTypeIdentifierOvulationTestResult", "Category", "9.0"),
        ("HKCategoryTypeIdentifierPersistentIntermenstrualBleeding", "Category", "16.0"),
        ("HKCategoryTypeIdentifierPregnancy", "Category", "14.3"),
        ("HKCategoryTypeIdentifierPregnancyTestResult", "Category", "15.0"),
        ("HKCategoryTypeIdentifierProgesteroneTestResult", "Category", "15.0"),
        ("HKCategoryTypeIdentifierProlongedMenstrualPeriods", "Category", "16.0"),
        ("HKCategoryTypeIdentifierSexualActivity", "Category", "9.0"),
        ("HKCategoryTypeIdentifierSleepApneaEvent", "Category", "18.0"),
        ("HKCategoryTypeIdentifierSleepAnalysis", "Category", "8.0"),
        ("HKCategoryTypeIdentifierAbdominalCramps", "Category", "13.6"),
        ("HKCategoryTypeIdentifierAcne", "Category", "13.6"),
        ("HKCategoryTypeIdentifierAppetiteChanges", "Category", "13.6"),
        ("HKCategoryTypeIdentifierBladderIncontinence", "Category", "14.0"),
        ("HKCategoryTypeIdentifierBloating", "Category", "13.6"),
        ("HKCategoryTypeIdentifierBreastPain", "Category", "13.6"),
        ("HKCategoryTypeIdentifierChestTightnessOrPain", "Category", "13.6"),
        ("HKCategoryTypeIdentifierChills", "Category", "13.6"),
        ("HKCategoryTypeIdentifierConstipation", "Category", "13.6"),
        ("HKCategoryTypeIdentifierCoughing", "Category", "13.6"),
        ("HKCategoryTypeIdentifierDiarrhea", "Category", "13.6"),
        ("HKCategoryTypeIdentifierDizziness", "Category", "13.6"),
        ("HKCategoryTypeIdentifierDrySkin", "Category", "14.0"),
        ("HKCategoryTypeIdentifierFainting", "Category", "13.6"),
        ("HKCategoryTypeIdentifierFatigue", "Category", "13.6"),
        ("HKCategoryTypeIdentifierFever", "Category", "13.6"),
        ("HKCategoryTypeIdentifierGeneralizedBodyAche", "Category", "13.6"),
        ("HKCategoryTypeIdentifierHairLoss", "Category", "14.0"),
        ("HKCategoryTypeIdentifierHeadache", "Category", "13.6"),
        ("HKCategoryTypeIdentifierHeartburn", "Category", "13.6"),
        ("HKCategoryTypeIdentifierHotFlashes", "Category", "13.6"),
        ("HKCategoryTypeIdentifierLossOfSmell", "Category", "13.6"),
        ("HKCategoryTypeIdentifierLossOfTaste", "Category", "13.6"),
        ("HKCategoryTypeIdentifierLowerBackPain", "Category", "13.6"),
        ("HKCategoryTypeIdentifierMemoryLapse", "Category", "14.0"),
        ("HKCategoryTypeIdentifierMoodChanges", "Category", "13.6"),
        ("HKCategoryTypeIdentifierNausea", "Category", "13.6"),
        ("HKCategoryTypeIdentifierNightSweats", "Category", "14.0"),
        ("HKCategoryTypeIdentifierPelvicPain", "Category", "13.6"),
        ("HKCategoryTypeIdentifierRapidPoundingOrFlutteringHeartbeat", "Category", "13.6"),
        ("HKCategoryTypeIdentifierRunnyNose", "Category", "13.6"),
        ("HKCategoryTypeIdentifierShortnessOfBreath", "Category", "13.6"),
        ("HKCategoryTypeIdentifierSinusCongestion", "Category", "13.6"),
        ("HKCategoryTypeIdentifierSkippedHeartbeat", "Category", "13.6"),
        ("HKCategoryTypeIdentifierSleepChanges", "Category", "13.6"),
        ("HKCategoryTypeIdentifierSoreThroat", "Category", "13.6"),
        ("HKCategoryTypeIdentifierVaginalDryness", "Category", "14.0"),
        ("HKCategoryTypeIdentifierVomiting", "Category", "13.6"),
        ("HKCategoryTypeIdentifierWheezing", "Category", "13.6"),
    ]
}
