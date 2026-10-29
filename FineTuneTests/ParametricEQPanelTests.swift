// FineTuneTests/ParametricEQPanelTests.swift
// Pure logic behind the device EQ panel: value formatting/parsing, scrub scaling, response curve.

import Foundation
import Testing
@testable import FineTune

@Suite("Device EQ panel — value fields")
@MainActor
struct ParametricValueFieldTests {

    @Test("Frequency display: 49.1 Hz, 130 Hz, 1.20 kHz, 12.0 kHz")
    func frequencyDisplay() {
        #expect(ParametricValueFormat.frequency(49.1) == "49.1 Hz")
        #expect(ParametricValueFormat.frequency(130) == "130 Hz")
        #expect(ParametricValueFormat.frequency(1200) == "1.20 kHz")
        #expect(ParametricValueFormat.frequency(12000) == "12.0 kHz")
    }

    @Test("Gain display uses a true minus sign and shows 0.0 dB unsigned")
    func gainDisplay() {
        #expect(ParametricValueFormat.gain(-7.1) == "\u{2212}7.1 dB")
        #expect(ParametricValueFormat.gain(3) == "+3.0 dB")
        #expect(ParametricValueFormat.gain(0) == "0.0 dB")
        #expect(ParametricValueFormat.gain(-0.01) == "0.0 dB")
    }

    @Test("Q display: two decimals")
    func qDisplay() {
        #expect(ParametricValueFormat.q(10) == "10.00")
        #expect(ParametricValueFormat.q(0.71) == "0.71")
    }

    @Test("Typed frequency accepts 130, 130 Hz, 1.2k, 1.2 kHz and 1200")
    func frequencyParsing() {
        #expect(ParametricValueFormat.parseFrequency("130") == 130)
        #expect(ParametricValueFormat.parseFrequency("130 Hz") == 130)
        #expect(ParametricValueFormat.parseFrequency("1.2k") == 1200)
        #expect(ParametricValueFormat.parseFrequency("1.2 kHz") == 1200)
        #expect(ParametricValueFormat.parseFrequency("1200") == 1200)
        // The field's own display text parses back.
        #expect(ParametricValueFormat.parseFrequency(ParametricValueFormat.frequency(1200)) == 1200)
    }

    @Test("Invalid and non-finite typed input is rejected", arguments: ["abc", "", "nan", "inf", "-inf", "1.2.3"])
    func rejectsInvalidInput(text: String) {
        #expect(ParametricValueFormat.parseFrequency(text) == nil)
        #expect(ParametricValueFormat.parseGain(text) == nil)
        #expect(ParametricValueFormat.parseQ(text) == nil)
    }

    @Test("Typed gain accepts ASCII and Unicode minus, with or without dB")
    func gainParsing() {
        #expect(ParametricValueFormat.parseGain("-7.1") == -7.1)
        #expect(ParametricValueFormat.parseGain("\u{2212}7.1 dB") == -7.1)
        #expect(ParametricValueFormat.parseGain("+3") == 3)
    }

    @Test("Typed Q accepts plain numbers and rejects non-positive values")
    func qParsing() {
        #expect(ParametricValueFormat.parseQ("10") == 10)
        #expect(ParametricValueFormat.parseQ("10.00") == 10)
        #expect(ParametricValueFormat.parseQ("0") == nil)
        #expect(ParametricValueFormat.parseQ("-1") == nil)
    }

    @Test("Trim display is signed with a true minus and no unit; 0.0 unsigned")
    func trimDisplay() {
        #expect(ParametricValueFormat.trim(0.5) == "+0.5")
        #expect(ParametricValueFormat.trim(-1.5) == "\u{2212}1.5")
        #expect(ParametricValueFormat.trim(0) == "0.0")
        #expect(ParametricValueFormat.trim(-0.01) == "0.0")
        #expect(ParametricValueFormat.trim(-12) == "\u{2212}12.0")
        #expect(ParametricValueFormat.trim(12) == "+12.0")
    }

    @Test("Every trim display string types back to its value", arguments: [-12.0, -1.5, -0.1, 0, 0.1, 0.5, 12])
    func trimRoundTrip(value: Double) {
        #expect(ParametricValueFormat.parseTrim(ParametricValueFormat.trim(value), channel: "L") == value)
    }

    @Test("Typed trim accepts the field's own channel letter, and rejects the other one")
    func trimParsing() {
        #expect(ParametricValueFormat.parseTrim("L +0.5 dB", channel: "L") == 0.5)
        #expect(ParametricValueFormat.parseTrim("l-1.5", channel: "L") == -1.5)
        #expect(ParametricValueFormat.parseTrim("+0.5", channel: "L") == 0.5)
        #expect(ParametricValueFormat.parseTrim("\u{2212}1.5 dB", channel: "R") == -1.5)
        #expect(ParametricValueFormat.parseTrim("R 2", channel: "R") == 2)
        #expect(ParametricValueFormat.parseTrim("R +0.5", channel: "L") == nil)
        #expect(ParametricValueFormat.parseTrim("L -1", channel: "R") == nil)
        #expect(ParametricValueFormat.parseTrim("L", channel: "L") == nil)
        #expect(ParametricValueFormat.parseTrim("", channel: "L") == nil)
        #expect(ParametricValueFormat.parseTrim("L inf", channel: "L") == nil)
    }

    @Test("Scrub scaling: 0.1 dB per pt, 1/48 octave per pt, ×2 Q per 100 pt")
    func scrubScaling() {
        #expect(abs(ScrubValueField.Scale.linear(perPoint: 0.1).apply(0, points: 10) - 1.0) < 1e-12)
        #expect(abs(ScrubValueField.Scale.log2(perPoint: 1.0 / 48.0).apply(130, points: 48) - 260) < 1e-9)
        #expect(abs(ScrubValueField.Scale.log2(perPoint: 1.0 / 100.0).apply(1, points: 100) - 2) < 1e-12)
        #expect(abs(ScrubValueField.Scale.log2(perPoint: 1.0 / 100.0).apply(1, points: -10) - pow(2, -0.1)) < 1e-12)
    }
}

@Suite("Device EQ panel — response curve")
@MainActor
struct ParametricEQCurveTests {

    @Test("Flat curve is 0 dB everywhere")
    func flatIsZero() {
        let response = ParametricEQCurveView.response(for: .flat, sampleRate: 48000)
        #expect(response.count == ParametricEQCurveView.pointCount)
        #expect(response.allSatisfy { abs($0) < 1e-9 })
    }

    @Test("Curve uses the processor's sections plus output gain")
    func curveMatchesSections() {
        var s = ParametricEQSettings()
        s.bands[2] = ParametricBand(frequency: 130, gainDB: -7.1, q: 10)
        s.outputGainDB = -2
        let response = ParametricEQCurveView.response(for: s, sampleRate: 48000)

        let coefficients = BiquadMath.coefficientsForParametricBands(s.bands, sampleRate: 48000)
        for i in [0, 64, 128, 255] {
            let f = ParametricEQCurveView.frequency(atFraction: Double(i) / 255)
            let expected = BiquadMath.cascadeMagnitudeDB(coefficients, frequency: f, sampleRate: 48000) - 2
            #expect(abs(response[i] - expected) < 1e-9)
        }
        // The deepest point sits near 130 Hz at about −9.1 dB (−7.1 dB band, −2 dB output).
        #expect(abs((response.min() ?? 0) - -9.1) < 0.2)
    }

    @Test("Peak readout source: boosted curve rises above 0 dB")
    func boostedCurvePeaks() {
        var s = ParametricEQSettings()
        s.bands[9].gainDB = 6
        let peak = ParametricEQCurveView.response(for: s, sampleRate: 48000).max() ?? 0
        #expect(abs(peak - 6) < 0.3)
    }

    @Test("Log frequency axis spans 20 Hz–20 kHz and round-trips")
    func logAxis() {
        #expect(abs(ParametricEQCurveView.frequency(atFraction: 0) - 20) < 1e-9)
        #expect(abs(ParametricEQCurveView.frequency(atFraction: 1) - 20000) < 1e-6)
        #expect(abs(ParametricEQCurveView.fraction(ofFrequency: 1000) - log(50) / log(1000)) < 1e-12)
    }

    @Test("Band role labels match the fixed layout")
    func roleLabels() {
        #expect(ParametricEQPanelView.roleName(0) == "Low shelf")
        #expect(ParametricEQPanelView.roleName(2) == "Peak")
        #expect(ParametricEQPanelView.roleName(9) == "High shelf")
    }
}
