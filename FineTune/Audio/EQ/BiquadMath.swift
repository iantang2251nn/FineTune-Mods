import Foundation

/// Audio EQ Cookbook biquad coefficient calculations
/// Reference: Robert Bristow-Johnson's Audio EQ Cookbook
enum BiquadMath {
    /// Standard Q for graphic EQ (overlapping bands)
    static let graphicEQQ: Double = 1.4

    /// Compute peaking EQ biquad coefficients
    /// Returns [b0, b1, b2, a1, a2] normalized by a0 for vDSP_biquad
    static func peakingEQCoefficients(
        frequency: Double,
        gainDB: Float,
        q: Double,
        sampleRate: Double
    ) -> [Double] {
        let A = pow(10.0, Double(gainDB) / 40.0)
        let omega = 2.0 * .pi * frequency / sampleRate
        let sinW = sin(omega)
        let cosW = cos(omega)
        let alpha = sinW / (2.0 * q)

        let b0 = 1.0 + alpha * A
        let b1 = -2.0 * cosW
        let b2 = 1.0 - alpha * A
        let a0 = 1.0 + alpha / A
        let a1 = -2.0 * cosW
        let a2 = 1.0 - alpha / A

        // Normalize by a0 for vDSP_biquad format
        // vDSP difference equation: y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]
        // Coefficients are passed as-is (vDSP internally subtracts a1/a2)
        return [
            b0 / a0,
            b1 / a0,
            b2 / a0,
            a1 / a0,
            a2 / a0
        ]
    }

    /// Compute low shelf biquad coefficients (RBJ cookbook)
    /// Returns [b0, b1, b2, a1, a2] normalized by a0 for vDSP_biquad
    static func lowShelfCoefficients(
        frequency: Double,
        gainDB: Float,
        q: Double,
        sampleRate: Double
    ) -> [Double] {
        let A = pow(10.0, Double(gainDB) / 40.0)
        let omega = 2.0 * .pi * frequency / sampleRate
        let sinW = sin(omega)
        let cosW = cos(omega)
        let alpha = sinW / (2.0 * q)
        let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha

        let b0 = A * ((A + 1.0) - (A - 1.0) * cosW + twoSqrtAAlpha)
        let b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosW)
        let b2 = A * ((A + 1.0) - (A - 1.0) * cosW - twoSqrtAAlpha)
        let a0 = (A + 1.0) + (A - 1.0) * cosW + twoSqrtAAlpha
        let a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosW)
        let a2 = (A + 1.0) + (A - 1.0) * cosW - twoSqrtAAlpha

        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }

    /// Compute high shelf biquad coefficients (RBJ cookbook)
    /// Returns [b0, b1, b2, a1, a2] normalized by a0 for vDSP_biquad
    static func highShelfCoefficients(
        frequency: Double,
        gainDB: Float,
        q: Double,
        sampleRate: Double
    ) -> [Double] {
        let A = pow(10.0, Double(gainDB) / 40.0)
        let omega = 2.0 * .pi * frequency / sampleRate
        let sinW = sin(omega)
        let cosW = cos(omega)
        let alpha = sinW / (2.0 * q)
        let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha

        let b0 = A * ((A + 1.0) + (A - 1.0) * cosW + twoSqrtAAlpha)
        let b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosW)
        let b2 = A * ((A + 1.0) + (A - 1.0) * cosW - twoSqrtAAlpha)
        let a0 = (A + 1.0) - (A - 1.0) * cosW + twoSqrtAAlpha
        let a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosW)
        let a2 = (A + 1.0) - (A - 1.0) * cosW - twoSqrtAAlpha

        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }

    /// Compute high-pass biquad coefficients (RBJ cookbook, 2nd-order Butterworth)
    /// Returns [b0, b1, b2, a1, a2] normalized by a0 for vDSP_biquad
    static func highPassCoefficients(
        frequency: Double,
        q: Double,
        sampleRate: Double
    ) -> [Double] {
        let omega = 2.0 * .pi * frequency / sampleRate
        let sinW = sin(omega)
        let cosW = cos(omega)
        let alpha = sinW / (2.0 * q)

        let b0 =  (1.0 + cosW) / 2.0
        let b1 = -(1.0 + cosW)
        let b2 =  (1.0 + cosW) / 2.0
        let a0 =  1.0 + alpha
        let a1 = -2.0 * cosW
        let a2 =  1.0 - alpha

        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }

    /// Correct a filter frequency optimized at `sourceRate` for use at `targetRate`.
    /// Uses inverse bilinear transform (digital→analog) then forward (analog→digital).
    static func preWarpFrequency(
        _ freq: Double,
        from sourceRate: Double,
        to targetRate: Double
    ) -> Double {
        // Map from source digital domain to analog (undo source bilinear transform)
        let fAnalog = (sourceRate / .pi) * tan(.pi * freq / sourceRate)
        // Map from analog to target digital domain (apply target bilinear transform)
        return (targetRate / .pi) * atan(.pi * fAnalog / targetRate)
    }

    /// Compute coefficients for AutoEQ filters (peaking, lowShelf, highShelf).
    /// Returns flat array of 5*N Doubles for vDSP_biquad_CreateSetup.
    ///
    /// - Parameters:
    ///   - filters: Filter parameters from an AutoEQ profile.
    ///   - sampleRate: Device's actual sample rate (Hz).
    ///   - profileOptimizedRate: Sample rate the profile was optimized for (Hz).
    ///     When different from `sampleRate`, filter frequencies are pre-warped to
    ///     compensate for the bilinear transform's frequency warping.
    static func coefficientsForAutoEQFilters(
        _ filters: [AutoEQFilter],
        sampleRate: Double,
        profileOptimizedRate: Double = 48000
    ) -> [Double] {
        var allCoeffs: [Double] = []
        allCoeffs.reserveCapacity(filters.count * 5)

        let needsPreWarp = abs(profileOptimizedRate - sampleRate) > 1.0

        for filter in filters {
            var frequency = filter.frequency

            // Pre-warp frequency if profile was optimized for a different sample rate
            if needsPreWarp {
                frequency = preWarpFrequency(frequency, from: profileOptimizedRate, to: sampleRate)
            }

            allCoeffs.append(contentsOf: coefficients(
                type: filter.type, frequency: frequency,
                gainDB: filter.gainDB, q: filter.q, sampleRate: sampleRate))
        }

        return allCoeffs
    }

    /// Compute one RBJ section of the given type. Shared by AutoEQ and the device parametric EQ.
    /// Returns [b0, b1, b2, a1, a2] normalized by a0 for vDSP_biquad.
    static func coefficients(
        type: AutoEQFilter.FilterType,
        frequency: Double,
        gainDB: Float,
        q: Double,
        sampleRate: Double
    ) -> [Double] {
        // Bypass invalid or above-Nyquist filters (pre-warp can produce
        // negative frequencies when the source filter is above its own Nyquist)
        guard frequency > 0, frequency < sampleRate / 2.0 else {
            return [1.0, 0.0, 0.0, 0.0, 0.0]
        }

        switch type {
        case .peaking:
            return peakingEQCoefficients(frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate)
        case .lowShelf:
            return lowShelfCoefficients(frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate)
        case .highShelf:
            return highShelfCoefficients(frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate)
        }
    }

    /// Compute coefficients for the device parametric EQ: exactly `ParametricEQSettings.bandCount`
    /// sections, band i in section i, so toggling a band never shifts filter state between sections.
    /// Band types come from their position; a disabled band is an identity section.
    /// PEQ bands are designed at the device's actual sample rate, so there is no pre-warp.
    static func coefficientsForParametricBands(
        _ bands: [ParametricBand],
        sampleRate: Double
    ) -> [Double] {
        var allCoeffs: [Double] = []
        allCoeffs.reserveCapacity(ParametricEQSettings.bandCount * 5)

        for index in 0..<ParametricEQSettings.bandCount {
            // A 0 dB band is identity for all three RBJ types (A = 1). Emitting an exact identity
            // section avoids the float32 rounding a b == a section adds near its center frequency.
            guard index < bands.count, bands[index].isEnabled, bands[index].gainDB != 0 else {
                allCoeffs.append(contentsOf: [1.0, 0.0, 0.0, 0.0, 0.0])
                continue
            }
            let band = bands[index]
            allCoeffs.append(contentsOf: coefficients(
                type: ParametricEQSettings.type(ofBand: index), frequency: band.frequency,
                gainDB: band.gainDB, q: band.q, sampleRate: sampleRate))
        }

        return allCoeffs
    }

    /// Compute coefficients for all 10 bands
    /// Returns 50 Doubles: [band0: b0,b1,b2,a1,a2, band1: ..., ...]
    static func coefficientsForAllBands(
        gains: [Float],
        sampleRate: Double
    ) -> [Double] {
        guard gains.count == EQSettings.bandCount else {
            // Return unity (passthrough) coefficients for all bands
            return (0..<EQSettings.bandCount).flatMap { _ in [1.0, 0.0, 0.0, 0.0, 0.0] }
        }

        var allCoeffs: [Double] = []
        allCoeffs.reserveCapacity(50)

        for (index, frequency) in EQSettings.frequencies.enumerated() {
            // Bands at or above Nyquist cannot exist in the signal — bypass with unity gain.
            // Without this guard, omega > pi produces negative alpha, yielding unstable
            // biquad coefficients (poles outside the unit circle) that cause exponentially
            // growing output heard as robotic/static distortion.
            if frequency >= sampleRate / 2.0 {
                allCoeffs.append(contentsOf: [1.0, 0.0, 0.0, 0.0, 0.0])
                continue
            }
            let bandCoeffs = peakingEQCoefficients(
                frequency: frequency,
                gainDB: gains[index],
                q: graphicEQQ,
                sampleRate: sampleRate
            )
            allCoeffs.append(contentsOf: bandCoeffs)
        }

        return allCoeffs
    }
}
