// FineTuneTests/DeviceEQSettingsTests.swift
// Persistence of per-device parametric EQ curves and parametric presets in SettingsManager.

import Foundation
import Testing
@testable import FineTune

private func makeManager() -> (SettingsManager, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FineTuneTests-\(UUID().uuidString)")
    return (SettingsManager(directory: dir), dir)
}

private func curve(gainDB: Float = -7.1) -> ParametricEQSettings {
    var s = ParametricEQSettings()
    s.bands[2] = ParametricBand(frequency: 130, gainDB: gainDB, q: 10)
    return s
}

@Suite("SettingsManager — device parametric EQ")
@MainActor
struct DeviceEQSettingsTests {

    @Test("Unknown device returns .flat")
    func unknownDeviceIsFlat() {
        let (manager, _) = makeManager()
        #expect(manager.getDeviceEQ(for: "missing") == .flat)
    }

    @Test("setDeviceEQ stores a validated copy (NaN never reaches the encoder)")
    func setValidates() throws {
        let (manager, _) = makeManager()
        var bad = curve()
        bad.bands[4].frequency = .nan
        bad.bands[5].gainDB = .infinity
        bad.outputGainDB = 99
        manager.setDeviceEQ(bad, for: "dev")

        let stored = manager.getDeviceEQ(for: "dev")
        #expect(stored == bad.validated())
        #expect(stored.bands[4] == ParametricEQSettings.defaultBand(4))
        #expect(stored.outputGainDB == 12)
        _ = try JSONEncoder().encode(stored)
    }

    @Test("A settings file without the new keys decodes to empty collections")
    func legacyFileDecodes() throws {
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: Data(#"{"version": 12}"#.utf8))
        #expect(decoded.deviceEQ.isEmpty)
        #expect(decoded.userParametricPresets.isEmpty)
    }

    @Test("A malformed deviceEQ entry does not reset every other setting")
    func malformedDeviceEQIsIsolated() throws {
        let json = #"{"version": 12, "appVolumes": {"com.a": 0.5}, "deviceEQ": "oops", "userParametricPresets": 7}"#
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: Data(json.utf8))
        #expect(decoded.appVolumes["com.a"] == 0.5)
        #expect(decoded.deviceEQ.isEmpty)
        #expect(decoded.userParametricPresets.isEmpty)
    }

    @Test("Settings round-trip keeps device curves and presets, clamped on decode")
    func settingsRoundTrip() throws {
        var settings = SettingsManager.Settings()
        settings.deviceEQ["dev"] = curve()
        settings.userParametricPresets = [UserParametricPreset(name: "Room", settings: curve())]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.deviceEQ["dev"] == curve())
        #expect(decoded.userParametricPresets.first?.settings == curve())

        var raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let band: [String: Any] = ["frequency": 50, "gainDB": 40, "q": 10]
        let deviceCurve: [String: Any] = ["bands": [band], "outputGainDB": -60]
        raw["deviceEQ"] = ["dev": deviceCurve]
        let clamped = try JSONDecoder().decode(
            SettingsManager.Settings.self,
            from: JSONSerialization.data(withJSONObject: raw)
        )
        #expect(clamped.deviceEQ["dev"]?.bands[0] == ParametricBand(frequency: 50, gainDB: 12, q: 2.0))
        #expect(clamped.deviceEQ["dev"]?.outputGainDB == -24)
    }

    @Test("A device's curve survives a restart while the device is disconnected")
    func curveSurvivesReload() {
        let (manager, dir) = makeManager()
        manager.setDeviceEQ(curve(), for: "usb-interface")
        manager.flushSync()

        let reloaded = SettingsManager(directory: dir)
        #expect(reloaded.getDeviceEQ(for: "usb-interface") == curve())
    }

    @Test("resetAllSettings clears device curves and parametric presets")
    func resetClears() {
        let (manager, _) = makeManager()
        manager.setDeviceEQ(curve(), for: "dev")
        manager.createParametricPreset(name: "Room", settings: curve())
        manager.resetAllSettings()
        #expect(manager.getDeviceEQ(for: "dev") == .flat)
        #expect(manager.getParametricPresets().isEmpty)
    }
}

@Suite("SettingsManager — parametric presets")
@MainActor
struct ParametricPresetTests {

    @Test("Create trims, falls back to Untitled and suffixes duplicates Finder-style")
    func createNaming() {
        let (manager, _) = makeManager()
        #expect(manager.createParametricPreset(name: "  Room  ", settings: curve()).name == "Room")
        #expect(manager.createParametricPreset(name: "Room", settings: curve()).name == "Room (2)")
        #expect(manager.createParametricPreset(name: "Room", settings: curve()).name == "Room (3)")
        #expect(manager.createParametricPreset(name: "   ", settings: curve()).name == "Untitled")
    }

    @Test("Graphic and parametric preset names don't collide with each other")
    func separateNamespaces() {
        let (manager, _) = makeManager()
        manager.createUserPreset(name: "Room", settings: .flat)
        #expect(manager.createParametricPreset(name: "Room", settings: curve()).name == "Room")
    }

    @Test("Rename suffixes collisions, keeps its own name, rejects empty names")
    func rename() {
        let (manager, _) = makeManager()
        let a = manager.createParametricPreset(name: "A", settings: curve())
        manager.createParametricPreset(name: "B", settings: curve())
        manager.renameParametricPreset(id: a.id, name: "B")
        #expect(manager.getParametricPresets().first { $0.id == a.id }?.name == "B (2)")
        manager.renameParametricPreset(id: a.id, name: "B (2)")
        #expect(manager.getParametricPresets().first { $0.id == a.id }?.name == "B (2)")
        manager.renameParametricPreset(id: a.id, name: "  ")
        #expect(manager.getParametricPresets().first { $0.id == a.id }?.name == "B (2)")
    }

    @Test("Deleting a preset leaves a device curve applied from it intact")
    func deleteKeepsDeviceCurve() {
        let (manager, _) = makeManager()
        let preset = manager.createParametricPreset(name: "Room", settings: curve())
        manager.setDeviceEQ(preset.settings, for: "dev")
        manager.deleteParametricPreset(id: preset.id)
        #expect(manager.getParametricPresets().isEmpty)
        #expect(manager.getDeviceEQ(for: "dev") == curve())
    }

    @Test("Presets are listed newest first and stored validated")
    func orderingAndValidation() {
        let (manager, _) = makeManager()
        var raw = curve()
        raw.bands[2].q = 50
        manager.createParametricPreset(name: "Old", settings: raw)
        manager.createParametricPreset(name: "New", settings: curve())
        let presets = manager.getParametricPresets()
        #expect(presets.map(\.name) == ["New", "Old"])
        #expect(presets[1].settings.bands[2].q == 20)
    }
}
