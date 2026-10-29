// FineTuneTests/ParametricEQFileTests.swift
// EqualizerAPO / REW parsing fixes and device parametric EQ import/export.

import Foundation
import Testing
@testable import FineTune

// MARK: - Parser

@Suite("AutoEQParser — filter lists")
struct AutoEQParserFilterListTests {

    @Test("Existing AutoEQ files parse exactly as before")
    func classicAutoEQUnchanged() throws {
        let text = """
        Preamp: -6.2 dB
        Filter 1: ON LSC Fc 105 Hz Gain 7.0 dB Q 0.71
        Filter 2: ON PK Fc 100 Hz Gain -2.3 dB Q 1.41
        Filter 3: ON HSC Fc 10000 Hz Gain -4.1 dB Q 0.71
        """
        let profile = try #require(AutoEQParser.parse(text: text, name: "X", source: .imported, id: "x"))
        #expect(profile.preampDB == -6.2)
        #expect(profile.filters == [
            AutoEQFilter(type: .lowShelf, frequency: Double(Float(105)), gainDB: 7.0, q: Double(Float(0.71))),
            AutoEQFilter(type: .peaking, frequency: Double(Float(100)), gainDB: -2.3, q: Double(Float(1.41))),
            AutoEQFilter(type: .highShelf, frequency: Double(Float(10000)), gainDB: -4.1, q: Double(Float(0.71))),
        ])
    }

    @Test("Shelves without Q default to 0.707; peaks without Q are still rejected")
    func shelvesWithoutQ() {
        let list = AutoEQParser.parseFilterList(text: """
        Filter 1: ON LS Fc 344.0 Hz Gain 5.90 dB
        Filter 2: ON HS Fc 8000 Hz Gain -3 dB
        Filter 3: ON PK Fc 1000 Hz Gain -3 dB
        """)
        #expect(list.filters.count == 2)
        #expect(list.filters[0].filter == AutoEQFilter(type: .lowShelf, frequency: 344, gainDB: 5.9, q: Double(Float(0.707))))
        #expect(list.filters[1].filter.type == .highShelf)
        #expect(list.filters[1].filter.q == Double(Float(0.707)))
    }

    @Test("BW Oct N converts to Q = √(2ᴺ) / (2ᴺ − 1)")
    func bandwidthSyntax() throws {
        let list = AutoEQParser.parseFilterList(text: "Filter 1: ON PK Fc 1000 Hz Gain -3 dB BW Oct 1.0")
        let q = try #require(list.filters.first?.filter.q)
        #expect(abs(q - 2.0.squareRoot()) < 1e-6)
    }

    @Test("OFF lines are listed as disabled but never reach an AutoEQ profile")
    func offLines() throws {
        let text = """
        Filter 1: OFF PK Fc 1000 Hz Gain -3 dB Q 1
        Filter 2: ON PK Fc 2000 Hz Gain 2 dB Q 1
        """
        let list = AutoEQParser.parseFilterList(text: text)
        #expect(list.filters.map(\.isOn) == [false, true])
        let profile = try #require(AutoEQParser.parse(text: text, name: "X", source: .imported, id: "x"))
        #expect(profile.filters.map(\.frequency) == [2000])
    }

    @Test("Header and unsupported lines are skipped")
    func headerLines() {
        let list = AutoEQParser.parseFilterList(text: """
        Filter Settings file
        # comment
        Equaliser: Generic
        Filter  3: ON  None
        Filter  4: ON  PK       Fc   130.0 Hz  Gain  -7.10 dB  Q 10.000
        """)
        #expect(list.filters.count == 1)
        #expect(list.filters[0].filter.frequency == 130)
    }

    @Test("More than 10 filters: AutoEQ keeps the first 10")
    func moreThanTenFilters() throws {
        let text = (1...12).map { "Filter \($0): ON PK Fc \($0 * 100) Hz Gain -1 dB Q 1" }.joined(separator: "\n")
        #expect(AutoEQParser.parseFilterList(text: text).filters.count == 12)
        let profile = try #require(AutoEQParser.parse(text: text, name: "X", source: .imported, id: "x"))
        #expect(profile.filters.count == 10)
    }

    @Test("REW-format sample: shelf without Q and None slots")
    func rewFormatSample() throws {
        // Written by hand in REW's "Filter Settings file" text layout, not a real export.
        let text = """
        Filter Settings file

        Room EQ V5.31.3
        Dated: 28-Oct-2026 20:00:00

        Notes:

        Equaliser: Generic
        Average 1
        Filter  1: ON  PK       Fc   130.0 Hz  Gain  -7.10 dB  Q 10.000
        Filter  2: ON  LS       Fc   344.0 Hz  Gain   5.90 dB
        Filter  3: ON  PK       Fc   58.20 Hz  Gain  -4.50 dB  Q  4.200
        Filter  4: ON  None
        Filter  5: ON  None
        """
        let result = try #require(ParametricEQFile.importSettings(from: text))
        #expect(result.importedCount == 3)
        #expect(result.droppedCount == 0)
        #expect(result.settings.bands[0] == ParametricBand(frequency: 344, gainDB: 5.9, q: 0.71))
        #expect(result.settings.bands[1] == ParametricBand(frequency: 130, gainDB: -7.1, q: 10))
        #expect(result.settings.bands[2] == ParametricBand(frequency: 58.2, gainDB: -4.5, q: 4.2))
        #expect(result.settings.bands[9] == ParametricEQSettings.defaultBand(9))
    }
}

// MARK: - Import Mapping

@Suite("ParametricEQFile — import onto the fixed layout")
struct ParametricEQImportTests {

    @Test("A FineTune-layout file maps by position, including OFF bands")
    func fineTuneLayoutByPosition() throws {
        var lines = ["Preamp: -3.0 dB", "Filter 1: ON LSC Fc 80.0 Hz Gain 4.0 dB Q 0.71"]
        for i in 2...9 {
            lines.append("Filter \(i): \(i == 5 ? "OFF" : "ON") PK Fc \(i * 200).0 Hz Gain -2.0 dB Q 1.50")
        }
        lines.append("Filter 10: OFF HSC Fc 12000.0 Hz Gain 3.0 dB Q 0.71")
        let result = try #require(ParametricEQFile.importSettings(from: lines.joined(separator: "\n")))

        #expect(result.importedCount == 10)
        #expect(result.settings.outputGainDB == -3)
        #expect(result.settings.bands[0] == ParametricBand(frequency: 80, gainDB: 4, q: 0.71))
        #expect(result.settings.bands[4] == ParametricBand(frequency: 1000, gainDB: -2, q: 1.5, isEnabled: false))
        #expect(result.settings.bands[9] == ParametricBand(frequency: 12000, gainDB: 3, q: 0.71, isEnabled: false))
    }

    @Test("Two low shelves: the larger absolute gain wins and one is reported dropped")
    func twoLowShelves() throws {
        let result = try #require(ParametricEQFile.importSettings(from: """
        Filter 1: ON LSC Fc 80 Hz Gain 3 dB Q 0.71
        Filter 2: ON LSC Fc 120 Hz Gain -6 dB Q 0.71
        Filter 3: ON PK Fc 500 Hz Gain 1 dB Q 1
        """))
        #expect(result.settings.bands[0].frequency == 120)
        #expect(result.settings.bands[0].gainDB == -6)
        #expect(result.droppedCount == 1)
        #expect(result.importedCount == 2)
    }

    @Test("12 peaks: the 8 largest are kept in file order and 4 are reported dropped")
    func twelvePeaks() throws {
        // Gains 1…12 dB in file order: the 8 largest are filters 5–12.
        let text = (1...12).map { "Filter \($0): ON PK Fc \($0 * 100) Hz Gain \($0) dB Q 1" }.joined(separator: "\n")
        let result = try #require(ParametricEQFile.importSettings(from: text))
        #expect(result.droppedCount == 4)
        #expect(result.settings.bands[1...8].map(\.frequency) == (5...12).map { Double($0 * 100) })
        #expect(result.clampedCount == 0)
    }

    @Test("No shelves: bands 1 and 10 stay at their defaults")
    func noShelves() throws {
        let result = try #require(ParametricEQFile.importSettings(from: "Filter 1: ON PK Fc 130 Hz Gain -7.1 dB Q 10"))
        #expect(result.settings.bands[0] == ParametricEQSettings.defaultBand(0))
        #expect(result.settings.bands[9] == ParametricEQSettings.defaultBand(9))
        #expect(result.settings.bands[1] == ParametricBand(frequency: 130, gainDB: -7.1, q: 10))
    }

    @Test("Only OFF lines in a non-FineTune file: import fails")
    func onlyOffLinesFails() {
        #expect(ParametricEQFile.importSettings(from: """
        Filter 1: OFF PK Fc 130 Hz Gain -7.1 dB Q 10
        Filter 2: OFF LSC Fc 80 Hz Gain 3 dB Q 0.71
        """) == nil)
        #expect(ParametricEQFile.importSettings(from: "Preamp: -3 dB") == nil)
    }

    @Test("Out-of-range values are clamped and counted")
    func clampedValues() throws {
        let result = try #require(ParametricEQFile.importSettings(from: """
        Preamp: -28 dB
        Filter 1: ON LSC Fc 80 Hz Gain 3 dB Q 5
        Filter 2: ON PK Fc 130 Hz Gain -27 dB Q 10
        """))
        #expect(result.clampedCount == 3)
        #expect(result.settings.bands[0].q == 2.0)
        #expect(result.settings.bands[1].gainDB == -24)
        #expect(result.settings.outputGainDB == -24)
        #expect(result.summary == "Imported 2 filters, clamped 3")
    }
}

// MARK: - Export

@Suite("ParametricEQFile — export")
struct ParametricEQExportTests {

    private func sampleCurve() -> ParametricEQSettings {
        var s = ParametricEQSettings()
        s.bands[0] = ParametricBand(frequency: 49.1, gainDB: 3.4, q: 0.85)
        s.bands[2] = ParametricBand(frequency: 130.1, gainDB: -7.1, q: 10)
        s.bands[4] = ParametricBand(frequency: 733.3, gainDB: 2.2, q: 0.37, isEnabled: false)
        s.bands[7] = ParametricBand(frequency: 3456.7, gainDB: -0.1, q: 19.99)
        s.bands[9] = ParametricBand(frequency: 15000, gainDB: -2.5, q: 0.71, isEnabled: false)
        s.outputGainDB = -4.3
        return s.validated()
    }

    @Test("Writes the preamp and all 10 bands as LSC, 8 × PK, HSC with OFF for disabled bands")
    func layout() {
        let lines = ParametricEQFile.export(sampleCurve()).split(separator: "\n").map(String.init)
        #expect(lines.count == 11)
        #expect(lines[0] == "Preamp: -4.3 dB")
        #expect(lines[1] == "Filter 1: ON LSC Fc 49.1 Hz Gain 3.4 dB Q 0.85")
        #expect(lines[2] == "Filter 2: ON PK Fc 120.0 Hz Gain 0.0 dB Q 1.00")
        #expect(lines[5] == "Filter 5: OFF PK Fc 733.3 Hz Gain 2.2 dB Q 0.37")
        #expect(lines[10] == "Filter 10: OFF HSC Fc 15000.0 Hz Gain -2.5 dB Q 0.71")
    }

    @Test("Export → import round trip is identical, including disabled bands")
    func roundTrip() throws {
        let curve = sampleCurve()
        let result = try #require(ParametricEQFile.importSettings(from: ParametricEQFile.export(curve)))
        #expect(result.settings == curve)
        #expect(result.importedCount == 10)
        #expect(result.droppedCount == 0 && result.clampedCount == 0)
    }

    @Test("Default curve round-trips (shelf Q 0.71 survives Float32 parsing)")
    func defaultRoundTrip() throws {
        let result = try #require(ParametricEQFile.importSettings(from: ParametricEQFile.export(.flat)))
        #expect(result.settings == .flat)
    }

    @Test("A file saved by the app's Export re-imports and re-exports byte for byte")
    func appExportFixture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/volt-476p-finetune-export.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        let result = try #require(ParametricEQFile.importSettings(from: text))

        #expect(result.importedCount == 10)
        #expect(result.droppedCount == 0 && result.clampedCount == 0)
        #expect(result.settings.outputGainDB == 0)
        #expect(result.settings.bands == [
            ParametricBand(frequency: 60, gainDB: 1.5, q: 0.7),
            ParametricBand(frequency: 129.7, gainDB: -9, q: 20),
            ParametricBand(frequency: 130, gainDB: 1.1, q: 0.71),
            ParametricBand(frequency: 390, gainDB: -1.5, q: 1),
            ParametricBand(frequency: 700, q: 1),
            ParametricBand(frequency: 1201, q: 1),
            ParametricBand(frequency: 2196.1, q: 1),
            ParametricBand(frequency: 3892.7, q: 1),
            ParametricBand(frequency: 7000, gainDB: 1.1, q: 1),
            ParametricBand(frequency: 12000, gainDB: 1, q: 0.71),
        ])
        #expect(ParametricEQFile.export(result.settings) == text)
        #expect(ParametricEQFile.importSettings(from: ParametricEQFile.export(result.settings))?.settings == result.settings)
    }
}
