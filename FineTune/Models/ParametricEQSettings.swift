// FineTune/Models/ParametricEQSettings.swift
import Foundation

/// One band of the device parametric EQ. Its filter type comes from its position
/// (`ParametricEQSettings.type(ofBand:)`) and is never stored.
nonisolated struct ParametricBand: Codable, Equatable {
    var frequency: Double
    var gainDB: Float = 0
    var q: Double
    var isEnabled: Bool = true
}

nonisolated extension ParametricBand {
    /// Tolerant decoding: a missing or malformed field never fails the settings file.
    /// Frequency and Q decode as NaN when absent; `ParametricEQSettings.validated()`
    /// replaces them with the defaults for the band's position.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequency = (try? c.decodeIfPresent(Double.self, forKey: .frequency)) ?? .nan
        gainDB = (try? c.decodeIfPresent(Float.self, forKey: .gainDB)) ?? 0
        q = (try? c.decodeIfPresent(Double.self, forKey: .q)) ?? .nan
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
    }
}

/// Per-device parametric EQ: a fixed layout of 10 bands (band 1 low shelf, bands 2–9 peaks,
/// band 10 high shelf) plus an output gain stage for headroom.
nonisolated struct ParametricEQSettings: Codable, Equatable {
    static let bandCount = 10
    /// Spread evenly on a log scale so the nodes start in order across the curve.
    static let defaultFrequencies: [Double] = [60, 120, 220, 390, 700, 1200, 2200, 3900, 7000, 12000]

    static let frequencyRange: ClosedRange<Double> = 20...20000
    static let gainRange: ClosedRange<Float> = -24...12
    static let outputGainRange: ClosedRange<Float> = -24...12
    static let peakQRange: ClosedRange<Double> = 0.1...20
    /// `BiquadMath` shelves use Q directly; 0.71 is the RBJ slope S = 1 (steepest without overshoot).
    static let shelfQRange: ClosedRange<Double> = 0.3...2.0
    static let peakDefaultQ = 1.0
    static let shelfDefaultQ = 0.71

    /// Band 1 = low shelf, band 10 = high shelf, bands 2–9 = peak. Never stored.
    static func type(ofBand index: Int) -> AutoEQFilter.FilterType {
        switch index {
        case 0: return .lowShelf
        case bandCount - 1: return .highShelf
        default: return .peaking
        }
    }

    static func qRange(ofBand index: Int) -> ClosedRange<Double> {
        type(ofBand: index) == .peaking ? peakQRange : shelfQRange
    }

    static func defaultQ(ofBand index: Int) -> Double {
        type(ofBand: index) == .peaking ? peakDefaultQ : shelfDefaultQ
    }

    static func defaultBand(_ index: Int) -> ParametricBand {
        ParametricBand(frequency: defaultFrequencies[index], q: defaultQ(ofBand: index))
    }

    // MARK: Storage resolution
    //
    // Every stored value is rounded to these steps (0.1 Hz, 0.1 dB, Q 0.01), so curves
    // compare exactly for preset matching and survive a text export → import round trip.

    static func quantizedFrequency(_ hz: Double) -> Double { (hz * 10).rounded() / 10 }
    static func quantizedGain(_ db: Float) -> Float { (db * 10).rounded() / 10 + 0 }  // + 0 turns -0 into 0
    static func quantizedQ(_ q: Double) -> Double { (q * 100).rounded() / 100 }

    var bands: [ParametricBand] = (0..<bandCount).map(defaultBand)
    var outputGainDB: Float = 0
    var isEnabled: Bool = true

    /// True when processing would be identity: every enabled band at 0 dB and output at 0 dB.
    /// A band at 0 dB is exact identity for all three RBJ types (A = 1).
    var isEffectivelyFlat: Bool {
        outputGainDB == 0 && bands.allSatisfy { !$0.isEnabled || $0.gainDB == 0 }
    }

    /// Curve identity for preset matching; ignores the panel on/off toggle.
    func curveEquals(_ other: ParametricEQSettings) -> Bool {
        bands == other.bands && outputGainDB == other.outputGainDB
    }

    /// Exactly `bandCount` bands (pads with defaults, drops extras). Every value is clamped to
    /// its range (Q to the band's own range), rounded to storage resolution, and replaced with
    /// its default when not finite.
    func validated() -> ParametricEQSettings {
        var result = self
        result.bands = (0..<Self.bandCount).map { index in
            let fallback = Self.defaultBand(index)
            guard index < bands.count else { return fallback }
            let band = bands[index]
            let qRange = Self.qRange(ofBand: index)
            return ParametricBand(
                frequency: band.frequency.isFinite
                    ? Self.quantizedFrequency(min(max(band.frequency, Self.frequencyRange.lowerBound), Self.frequencyRange.upperBound))
                    : fallback.frequency,
                gainDB: band.gainDB.isFinite
                    ? Self.quantizedGain(min(max(band.gainDB, Self.gainRange.lowerBound), Self.gainRange.upperBound))
                    : fallback.gainDB,
                q: band.q.isFinite
                    ? Self.quantizedQ(min(max(band.q, qRange.lowerBound), qRange.upperBound))
                    : fallback.q,
                isEnabled: band.isEnabled
            )
        }
        result.outputGainDB = outputGainDB.isFinite
            ? Self.quantizedGain(min(max(outputGainDB, Self.outputGainRange.lowerBound), Self.outputGainRange.upperBound))
            : 0
        return result
    }

    static let flat = ParametricEQSettings()
}

nonisolated extension ParametricEQSettings {
    /// Tolerant decoding: a malformed field falls back to its default instead of failing
    /// the whole settings file (`SettingsManager` resets everything on a decode error).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedBands = (try? c.decodeIfPresent([ParametricBand].self, forKey: .bands))
            ?? (0..<Self.bandCount).map(Self.defaultBand)
        self.init(
            bands: decodedBands,
            outputGainDB: (try? c.decodeIfPresent(Float.self, forKey: .outputGainDB)) ?? 0,
            isEnabled: (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        )
        self = validated()
    }
}
