// FineTuneTests/ParametricEQTests.swift
// Device parametric EQ: shared coefficient math, ParametricEQProcessor and the
// ParametricEQSettings model (validation, quantization, tolerant decoding).

import Accelerate
import Foundation
import Testing
@testable import FineTune

// MARK: - Helpers

/// Magnitude response in dB of a cascade of vDSP-format sections [b0, b1, b2, a1, a2]...
private func magnitudeDB(_ coefficients: [Double], frequency: Double, sampleRate: Double) -> Double {
    let w = 2 * Double.pi * frequency / sampleRate
    let (c1, s1, c2, s2) = (cos(w), -sin(w), cos(2 * w), -sin(2 * w))
    var total = 0.0
    for section in stride(from: 0, to: coefficients.count, by: 5) {
        let c = Array(coefficients[section..<section + 5])
        let nr = c[0] + c[1] * c1 + c[2] * c2, ni = c[1] * s1 + c[2] * s2
        let dr = 1 + c[3] * c1 + c[4] * c2, di = c[3] * s1 + c[4] * s2
        total += 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
    }
    return total
}

/// Flat settings with one band replaced.
private func settings(band index: Int, frequency: Double, gainDB: Float, q: Double) -> ParametricEQSettings {
    var s = ParametricEQSettings()
    s.bands[index] = ParametricBand(frequency: frequency, gainDB: gainDB, q: q)
    return s
}

/// Stereo interleaved sine (same signal on both channels).
private func stereoSine(frequency: Double, amplitude: Double, sampleRate: Double, frames: Int) -> [Float] {
    var samples = [Float](repeating: 0, count: frames * 2)
    for f in 0..<frames {
        let v = Float(amplitude * sin(2 * Double.pi * frequency * Double(f) / sampleRate))
        samples[f * 2] = v
        samples[f * 2 + 1] = v
    }
    return samples
}

/// Runs `samples` through the processor in place.
private func process(_ processor: BiquadProcessor, _ samples: inout [Float]) {
    let frames = samples.count / 2
    samples.withUnsafeMutableBufferPointer { buf in
        processor.process(input: buf.baseAddress!, output: buf.baseAddress!, frameCount: frames)
    }
}

/// Left-channel RMS ratio (dB) of output vs input over the second half (filter settled).
private func settledGainDB(input: [Float], output: [Float]) -> Double {
    let frames = input.count / 2
    var inSq = 0.0, outSq = 0.0
    for f in (frames / 2)..<frames {
        inSq += Double(input[f * 2]) * Double(input[f * 2])
        outSq += Double(output[f * 2]) * Double(output[f * 2])
    }
    return 10 * log10(outSq / inSq)
}

// MARK: - Coefficient Math

@Suite("BiquadMath — shared section math and parametric bands")
struct ParametricCoefficientTests {

    @Test("coefficientsForAutoEQFilters is bit-identical to the pre-refactor output")
    func autoEQGolden() {
        // Grid and hash were produced by the implementation before `coefficients(type:…)`
        // was extracted (FNV-1a over every coefficient's bit pattern).
        var filters: [AutoEQFilter] = []
        for type in [AutoEQFilter.FilterType.peaking, .lowShelf, .highShelf] {
            for frequency in [20.0, 105.5, 1000.0, 7300.0, 15000.0, 23000.0] {
                for gainDB: Float in [-12.3, -3, 0, 4.7, 9.9] {
                    for q in [0.5, 0.71, 1.41, 4.3] {
                        filters.append(AutoEQFilter(type: type, frequency: frequency, gainDB: gainDB, q: q))
                    }
                }
            }
        }
        var hash: UInt64 = 0xcbf29ce484222325
        var count = 0
        for (rate, optimized) in [(44100.0, 48000.0), (48000.0, 48000.0), (96000.0, 44100.0)] {
            for c in BiquadMath.coefficientsForAutoEQFilters(filters, sampleRate: rate, profileOptimizedRate: optimized) {
                hash = (hash ^ c.bitPattern) &* 0x100000001b3
                count += 1
            }
        }
        #expect(count == 5400)
        #expect(hash == 0x56e9a83361a74394)
    }

    @Test("Peak 130 Hz, −7.11 dB, Q 10: analytic magnitude", arguments: [44100.0, 48000.0, 96000.0, 192000.0])
    func peakAnalyticMagnitude(sampleRate: Double) {
        let c = BiquadMath.coefficients(type: .peaking, frequency: 130, gainDB: -7.11, q: 10, sampleRate: sampleRate)
        #expect(abs(magnitudeDB(c, frequency: 130, sampleRate: sampleRate) - -7.11) < 0.01)
        #expect(abs(magnitudeDB(c, frequency: 100, sampleRate: sampleRate) - -0.27) < 0.01)
        #expect(abs(magnitudeDB(c, frequency: 170, sampleRate: sampleRate) - -0.26) < 0.01)
    }

    @Test("Band roles come from position; disabled and 0 dB bands are identity sections")
    func bandRolesAndDisabledBands() {
        #expect(ParametricEQSettings.type(ofBand: 0) == .lowShelf)
        #expect(ParametricEQSettings.type(ofBand: 9) == .highShelf)
        for index in 1...8 {
            #expect(ParametricEQSettings.type(ofBand: index) == .peaking)
        }

        var s = ParametricEQSettings()
        s.bands[0] = ParametricBand(frequency: 80, gainDB: 4, q: 0.71)
        s.bands[3] = ParametricBand(frequency: 400, gainDB: -6, q: 2, isEnabled: false)
        s.bands[9] = ParametricBand(frequency: 10000, gainDB: -3, q: 0.71)
        let c = BiquadMath.coefficientsForParametricBands(s.bands, sampleRate: 48000)

        #expect(c.count == ParametricEQSettings.bandCount * 5)
        #expect(Array(c[15..<20]) == [1, 0, 0, 0, 0])  // disabled
        #expect(Array(c[5..<10]) == [1, 0, 0, 0, 0])   // enabled at 0 dB
        #expect(Array(c[0..<5]) == BiquadMath.coefficients(type: .lowShelf, frequency: 80, gainDB: 4, q: 0.71, sampleRate: 48000))
        #expect(Array(c[45..<50]) == BiquadMath.coefficients(type: .highShelf, frequency: 10000, gainDB: -3, q: 0.71, sampleRate: 48000))
    }

    @Test("Band at or above Nyquist is identity (20 kHz at 32 kHz)")
    func aboveNyquistIsIdentity() {
        let c = BiquadMath.coefficients(type: .peaking, frequency: 20000, gainDB: -12, q: 1, sampleRate: 32000)
        #expect(c == [1, 0, 0, 0, 0])
    }
}

// MARK: - Processor

@Suite("ParametricEQProcessor — signal behavior")
@MainActor
struct ParametricEQProcessorTests {

    @Test("Processed 130 Hz sine is attenuated by the band's gain", arguments: [44100.0, 48000.0, 96000.0, 192000.0])
    func attenuationAtCenter(sampleRate: Double) {
        let processor = ParametricEQProcessor(sampleRate: sampleRate)
        // −7.11 dB is stored at 0.1 dB resolution (−7.1 dB); the criterion is unchanged.
        processor.updateSettings(settings(band: 2, frequency: 130, gainDB: -7.11, q: 10))

        let input = stereoSine(frequency: 130, amplitude: 0.25, sampleRate: sampleRate, frames: Int(sampleRate))
        var output = input
        process(processor, &output)

        #expect(abs(settledGainDB(input: input, output: output) - -7.11) < 0.2)
    }

    @Test("Float32 error floor at the worst case (130 Hz, Q 10, 192 kHz) is below −110 dBFS")
    func precisionFloor() {
        let sampleRate = 192000.0
        let s = settings(band: 2, frequency: 130, gainDB: -7.11, q: 10)
        let processor = ParametricEQProcessor(sampleRate: sampleRate)
        processor.updateSettings(s)

        let frames = Int(sampleRate)
        let input = stereoSine(frequency: 1000, amplitude: 0.001, sampleRate: sampleRate, frames: frames)  // −60 dBFS
        var output = input
        process(processor, &output)

        // Double-precision reference: same sections, same (float-quantized) input.
        var coefficients = BiquadMath.coefficientsForParametricBands(s.validated().bands, sampleRate: sampleRate)
        let setup = vDSP_biquad_CreateSetupD(&coefficients, vDSP_Length(ParametricEQSettings.bandCount))!
        defer { vDSP_biquad_DestroySetupD(setup) }
        var delay = [Double](repeating: 0, count: 2 * ParametricEQSettings.bandCount + 2)
        let left = (0..<frames).map { Double(input[$0 * 2]) }
        var reference = [Double](repeating: 0, count: frames)
        vDSP_biquadD(setup, &delay, left, 1, &reference, 1, vDSP_Length(frames))

        var errorSq = 0.0
        for f in (frames / 2)..<frames {
            let e = Double(output[f * 2]) - reference[f]
            errorSq += e * e
        }
        let errorDBFS = 10 * log10(errorSq / Double(frames - frames / 2))
        #expect(errorDBFS < -110, "Error floor \(errorDBFS) dBFS")
    }

    @Test("Disabled bands: output matches a cascade of only the enabled bands")
    func disabledBandsMatchEnabledOnlyCascade() {
        let sampleRate = 48000.0
        var s = ParametricEQSettings()
        s.bands[2] = ParametricBand(frequency: 130, gainDB: -7.1, q: 10)
        s.bands[4] = ParametricBand(frequency: 700, gainDB: 9, q: 1.5, isEnabled: false)
        s.bands[6] = ParametricBand(frequency: 2200, gainDB: 5, q: 2)
        for index in [0, 1, 3, 5, 7, 8, 9] { s.bands[index].isEnabled = false }
        let processor = ParametricEQProcessor(sampleRate: sampleRate)
        processor.updateSettings(s)

        let input = stereoSine(frequency: 700, amplitude: 0.3, sampleRate: sampleRate, frames: 9600)
        var output = input
        process(processor, &output)

        // Reference: only bands 3 and 7, single precision like the processor.
        var coefficients = BiquadMath.coefficients(type: .peaking, frequency: 130, gainDB: -7.1, q: 10, sampleRate: sampleRate)
            + BiquadMath.coefficients(type: .peaking, frequency: 2200, gainDB: 5, q: 2, sampleRate: sampleRate)
        let setup = vDSP_biquad_CreateSetup(&coefficients, 2)!
        defer { vDSP_biquad_DestroySetup(setup) }
        var delay = [Float](repeating: 0, count: 6)
        let left = (0..<9600).map { input[$0 * 2] }
        var reference = [Float](repeating: 0, count: 9600)
        vDSP_biquad(setup, &delay, left, 1, &reference, 1, 9600)

        // vDSP rounds a 10-section cascade slightly differently from a 2-section one (~5e-5
        // measured); a disabled −12 dB band leaking through would differ by ~0.3.
        var maxError: Float = 0
        for f in 0..<9600 { maxError = max(maxError, abs(output[f * 2] - reference[f])) }
        #expect(maxError < 1e-3, "Max error \(maxError)")
    }

    @Test("Toggling band 2 off does not shift other bands' filter state")
    func toggleDoesNotShiftSections() {
        // Band 2 sits at 0 dB, so switching it off changes nothing. If sections were compacted
        // on toggle, band 3's state would move into section 2 and the output would jump (~−12 dBFS).
        let sampleRate = 48000.0
        var s = ParametricEQSettings()
        s.bands[0] = ParametricBand(frequency: 60, gainDB: 6, q: 0.71)
        s.bands[2] = ParametricBand(frequency: 130, gainDB: -7.1, q: 10)
        var toggled = s
        toggled.bands[1].isEnabled = false

        let input = stereoSine(frequency: 130, amplitude: 0.5, sampleRate: sampleRate, frames: 48000)
        let half = input.count / 2
        let steady = ParametricEQProcessor(sampleRate: sampleRate)
        steady.updateSettings(s)
        let switching = ParametricEQProcessor(sampleRate: sampleRate)
        switching.updateSettings(s)

        var a = Array(input[..<half]), b = a
        process(steady, &a)
        process(switching, &b)
        switching.updateSettings(toggled)
        var a2 = Array(input[half...]), b2 = a2
        process(steady, &a2)
        process(switching, &b2)

        var maxDiff: Float = 0
        for i in 0..<a2.count { maxDiff = max(maxDiff, abs(a2[i] - b2[i])) }
        #expect(20 * log10(Double(max(maxDiff, .leastNonzeroMagnitude))) < -90, "Max difference \(maxDiff)")
    }

    @Test("Flat or toggled-off settings disable the processor")
    func flatOrOffDisables() {
        let processor = ParametricEQProcessor(sampleRate: 48000)
        processor.updateSettings(.flat)
        #expect(!processor.isEnabled)

        var off = settings(band: 2, frequency: 130, gainDB: -7.1, q: 10)
        processor.updateSettings(off)
        #expect(processor.isEnabled)
        off.isEnabled = false
        processor.updateSettings(off)
        #expect(!processor.isEnabled)

        var disabledBand = settings(band: 2, frequency: 130, gainDB: -7.1, q: 10)
        disabledBand.bands[2].isEnabled = false
        processor.updateSettings(disabledBand)
        #expect(!processor.isEnabled)
    }

    @Test("Output gain +6.0 dB scales amplitude by ×1.9953")
    func outputGain() {
        // Stored at 0.1 dB resolution, so +6.02 dB is held as +6.0 dB.
        let processor = ParametricEQProcessor(sampleRate: 48000)
        var s = ParametricEQSettings()
        s.outputGainDB = 6.0
        processor.updateSettings(s)
        #expect(processor.isEnabled)

        var samples: [Float] = Array(repeating: 0.25, count: 4800)
        process(processor, &samples)
        // Band sections at 0 dB are identity, so the settled level is just the gain.
        #expect(abs(samples[4798] / 0.25 - 1.99526) < 0.001)
    }

    @Test("Sample rate change keeps the notch at 130 Hz")
    func sampleRateChange() {
        let processor = ParametricEQProcessor(sampleRate: 48000)
        processor.updateSettings(settings(band: 2, frequency: 130, gainDB: -7.1, q: 10))
        processor.updateSampleRate(96000)

        let input = stereoSine(frequency: 130, amplitude: 0.25, sampleRate: 96000, frames: 96000)
        var output = input
        process(processor, &output)
        #expect(abs(settledGainDB(input: input, output: output) - -7.1) < 0.2)
    }
}

// MARK: - Model

@Suite("ParametricEQSettings — validation, quantization and decoding")
struct ParametricEQSettingsTests {

    @Test("validated() always yields exactly 10 bands")
    func exactlyTenBands() {
        var short = ParametricEQSettings()
        short.bands = [ParametricBand(frequency: 100, gainDB: 3, q: 1)]
        let padded = short.validated()
        #expect(padded.bands.count == 10)
        #expect(padded.bands[5] == ParametricEQSettings.defaultBand(5))

        var long = ParametricEQSettings()
        long.bands += [ParametricBand(frequency: 100, gainDB: 3, q: 1)]
        #expect(long.validated().bands.count == 10)
    }

    @Test("validated() clamps to each band's own ranges")
    func clampsRanges() {
        var s = ParametricEQSettings()
        s.bands[0] = ParametricBand(frequency: 5, gainDB: 40, q: 10)      // shelf Q range 0.3–2.0
        s.bands[4] = ParametricBand(frequency: 30000, gainDB: -40, q: 50) // peak Q range 0.1–20
        s.bands[9] = ParametricBand(frequency: 12000, gainDB: 0, q: 0.01)
        s.outputGainDB = -99
        let v = s.validated()
        #expect(v.bands[0] == ParametricBand(frequency: 20, gainDB: 12, q: 2.0))
        #expect(v.bands[4] == ParametricBand(frequency: 20000, gainDB: -24, q: 20))
        #expect(v.bands[9].q == 0.3)
        #expect(v.outputGainDB == -24)
    }

    @Test("validated() replaces NaN and Inf with defaults")
    func replacesNonFinite() {
        var s = ParametricEQSettings()
        s.bands[3] = ParametricBand(frequency: .nan, gainDB: .infinity, q: -.infinity)
        s.outputGainDB = .nan
        let v = s.validated()
        #expect(v.bands[3] == ParametricEQSettings.defaultBand(3))
        #expect(v.outputGainDB == 0)
    }

    @Test("validated() rounds to storage resolution and is idempotent")
    func quantizes() {
        var s = ParametricEQSettings()
        s.bands[2] = ParametricBand(frequency: 130.4729, gainDB: -7.1149, q: 9.8765)
        s.outputGainDB = -0.04
        let v = s.validated()
        #expect(v.bands[2] == ParametricBand(frequency: 130.5, gainDB: -7.1, q: 9.88))
        #expect(v.outputGainDB == 0 && v.outputGainDB.sign == .plus)
        #expect(v.validated() == v)
    }

    @Test("Values parsed back from Float32 text land on the same stored values")
    func float32RoundTripLandsOnGrid() {
        // The EqualizerAPO parser reads Float; quantization maps those back exactly.
        var s = ParametricEQSettings()
        s.bands[0].q = 0.71
        s.bands[2] = ParametricBand(frequency: 130.1, gainDB: -7.1, q: 10)
        let v = s.validated()
        var reparsed = v
        for i in 0..<10 {
            reparsed.bands[i].frequency = Double(Float(String(format: "%.1f", v.bands[i].frequency))!)
            reparsed.bands[i].q = Double(Float(String(format: "%.2f", v.bands[i].q))!)
            reparsed.bands[i].gainDB = Float(String(format: "%.1f", v.bands[i].gainDB))!
        }
        #expect(reparsed != v)
        #expect(reparsed.validated() == v)
    }

    @Test("isEffectivelyFlat: enabled bands at 0 dB and output at 0 dB")
    func effectivelyFlat() {
        #expect(ParametricEQSettings.flat.isEffectivelyFlat)
        var s = settings(band: 2, frequency: 130, gainDB: -7.1, q: 10)
        #expect(!s.isEffectivelyFlat)
        s.bands[2].isEnabled = false
        #expect(s.isEffectivelyFlat)
        s.outputGainDB = -3
        #expect(!s.isEffectivelyFlat)
    }

    @Test("curveEquals ignores the on/off toggle")
    func curveEqualsIgnoresToggle() {
        let a = settings(band: 2, frequency: 130, gainDB: -7.1, q: 10)
        var b = a
        b.isEnabled = false
        #expect(a.curveEquals(b))
        #expect(a != b)
        b.bands[2].gainDB = -7.0
        #expect(!a.curveEquals(b))
    }

    @Test("Encoding round-trips")
    func codableRoundTrip() throws {
        var s = settings(band: 2, frequency: 130, gainDB: -7.1, q: 10)
        s.bands[5].isEnabled = false
        s.outputGainDB = -2.5
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(ParametricEQSettings.self, from: data) == s)
    }

    @Test("Missing and malformed fields decode to defaults instead of throwing")
    func tolerantDecoding() throws {
        let json = """
        {"bands":[{"frequency":80,"gainDB":4},{"gainDB":"loud"},{"frequency":130,"gainDB":-7.1,"q":10,"isEnabled":false}],"outputGainDB":"x"}
        """
        let s = try JSONDecoder().decode(ParametricEQSettings.self, from: Data(json.utf8))
        #expect(s.bands.count == 10)
        #expect(s.bands[0] == ParametricBand(frequency: 80, gainDB: 4, q: 0.71))
        #expect(s.bands[1] == ParametricEQSettings.defaultBand(1))
        #expect(s.bands[2] == ParametricBand(frequency: 130, gainDB: -7.1, q: 10, isEnabled: false))
        #expect(s.outputGainDB == 0)
        #expect(s.isEnabled)
    }

    @Test("Out-of-range persisted values are clamped on decode")
    func clampedOnDecode() throws {
        let json = """
        {"bands":[{"frequency":80,"gainDB":4,"q":10}],"outputGainDB":50,"isEnabled":true}
        """
        let s = try JSONDecoder().decode(ParametricEQSettings.self, from: Data(json.utf8))
        #expect(s.bands[0].q == 2.0)
        #expect(s.outputGainDB == 12)
    }
}
