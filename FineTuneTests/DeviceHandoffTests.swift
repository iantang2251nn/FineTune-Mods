// FineTuneTests/DeviceHandoffTests.swift
// Moving apps between output devices: retries while a device comes up, routing that always
// matches where the audio plays, and replug / unplug recovery.

import AppKit
import CoreAudio
import Foundation
import Testing
@testable import FineTune

// MARK: - Mock tap

/// Tap whose device switches can be made to fail, to stand in for a device that isn't ready.
@MainActor
final class HandoffTap: ProcessTapControlling {
    let app: AudioApp
    var volume: Float = 1.0
    var isMuted = false
    var currentDeviceVolume: Float = 1.0
    var isDeviceMuted = false
    var audioLevel: Float = 0
    private(set) var currentDeviceUIDs: [String]
    var currentDeviceUID: String? { currentDeviceUIDs.first }
    var tapSourceDeviceUID: String? = nil

    /// Devices whose switches fail; `failuresLeft` of them, then they succeed (nil = always fail).
    var failingDevices: Set<String> = []
    var failuresLeft: Int? = nil
    private(set) var switchAttempts: [String] = []
    private(set) var loudnessUpdates: [Float] = []
    private(set) var sourceRefreshes: [String?] = []

    // Handover (output-list choice): prepared targets, and what happened to them
    var failPrepare = false
    var prepareDelay: Duration? = nil
    var onPrepare: () -> Void = {}
    var onRefresh: () -> Void = {}
    private(set) var preparedHandovers: [String] = []
    private(set) var completedHandovers = 0
    private(set) var cancelledHandovers = 0
    private var pendingHandover: (uids: [String], source: String?)?

    init(app: AudioApp, deviceUIDs: [String]) {
        self.app = app
        self.currentDeviceUIDs = deviceUIDs
    }

    func activate(initial: TapInitialState) throws {}
    func invalidate() {}
    func updateEQSettings(_ settings: EQSettings) {}
    func updateDeviceEQ(_ settings: ParametricEQSettings) {}
    func updateAutoEQProfile(_ profile: AutoEQProfile?) {}
    func setAutoEQPreampEnabled(_ enabled: Bool) {}
    func updateLoudnessCompensation(volume: Float, enabled: Bool) { loudnessUpdates.append(volume) }
    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings) {}

    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        switchAttempts.append(newDeviceUID)
        if failingDevices.contains(newDeviceUID) {
            if let left = failuresLeft {
                if left > 0 {
                    failuresLeft = left - 1
                    throw CrossfadeError.deviceNotReady
                }
            } else {
                throw CrossfadeError.deviceNotReady
            }
        }
        currentDeviceUIDs = [newDeviceUID]
        tapSourceDeviceUID = preferredTapSourceDeviceUID
    }

    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        currentDeviceUIDs = newDeviceUIDs
    }

    func hasRecentAudioCallback(within seconds: Double) -> Bool { true }
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool { false }

    func refreshTapSource(_ preferredDeviceUID: String?) async throws {
        onRefresh()
        sourceRefreshes.append(preferredDeviceUID)
        tapSourceDeviceUID = preferredDeviceUID
    }

    func prepareHandover(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?) async throws {
        onPrepare()
        preparedHandovers.append(newDeviceUIDs[0])
        if let prepareDelay { try? await Task.sleep(for: prepareDelay) }
        if failPrepare { throw CrossfadeError.deviceNotReady }
        pendingHandover = (newDeviceUIDs, preferredTapSourceDeviceUID)
    }

    func completeHandover() async -> Bool {
        guard let pending = pendingHandover else { return false }
        pendingHandover = nil
        completedHandovers += 1
        currentDeviceUIDs = pending.uids
        tapSourceDeviceUID = pending.source
        return true
    }

    func cancelHandover() {
        guard pendingHandover != nil else { return }
        pendingHandover = nil
        cancelledHandovers += 1
    }
}

// MARK: - Fixture

@MainActor
private final class HandoffFixture {
    let engine: AudioEngine
    let settings: SettingsManager
    let monitor: MockAudioDeviceMonitor
    let volumes: MockDeviceVolumeProviding
    let app: AudioApp
    let headphones = AudioDevice(id: AudioDeviceID(301), uid: "uid-headphones", name: "Headphones", icon: nil, supportsAutoEQ: false)
    let speakers = AudioDevice(id: AudioDeviceID(302), uid: "uid-speakers", name: "Speakers", icon: nil, supportsAutoEQ: false)
    let monitors = AudioDevice(id: AudioDeviceID(303), uid: "uid-monitors", name: "Monitors", icon: nil, supportsAutoEQ: false)
    private(set) var createdTaps: [HandoffTap] = []
    /// Devices that are present but not yet alive.
    var notAlive: Set<AudioDeviceID> = []
    /// Applied to every tap the engine creates.
    var configureTap: (HandoffTap) -> Void = { _ in }

    var tap: HandoffTap? { createdTaps.last }

    init() {
        settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var appSettings = settings.appSettings
        appSettings.showDeviceDisconnectAlerts = false  // no notification center in the test runner
        settings.updateAppSettings(appSettings)

        monitor = MockAudioDeviceMonitor()
        volumes = MockDeviceVolumeProviding(deviceMonitor: monitor)
        app = AudioApp(id: 5150, processObjectIDs: [], name: "Player", icon: NSImage(), bundleID: "com.test.handoff")
        let processMonitor = StubProcessMonitor()
        processMonitor.activeApps = [app]
        let permission = AudioRecordingPermission()
        permission.status = .authorized

        // Closures below run only after init, once every stored property is set.
        var holder: HandoffFixture?
        engine = AudioEngine(
            permission: permission,
            settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(),
            deviceProvider: monitor,
            processMonitor: processMonitor,
            deviceVolumeMonitor: volumes,
            tapFactory: { app, uids, source in
                let tap = HandoffTap(app: app, deviceUIDs: uids)
                tap.tapSourceDeviceUID = source
                holder?.configureTap(tap)
                holder?.createdTaps.append(tap)
                return tap
            },
            isAlive: { id in !(holder?.notAlive.contains(id) ?? false) },
            startMonitorsAutomatically: false
        )
        holder = self
        engine.switchRetryDelays = [.milliseconds(5), .milliseconds(5), .milliseconds(5)]

        for device in [headphones, speakers, monitors] {
            monitor.addOutputDevice(device)
            volumes.volumes[device.id] = 0.5
        }
        settings.setDevicePriorityOrder([headphones.uid, speakers.uid, monitors.uid])
    }

    func unplug(_ device: AudioDevice) {
        monitor.removeOutputDevice(uid: device.uid)
        monitor.onDeviceDisconnected?(device.uid, device.name)
    }

    func plug(_ device: AudioDevice) {
        monitor.addOutputDevice(device)
        monitor.onDeviceConnected?(device.uid, device.name)
    }
}

/// Yields to the engine's switch tasks until `condition` holds (or ~2 s pass).
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// Lets in-flight switch tasks run to completion when there is nothing specific to wait for.
@MainActor
private func drain() async {
    try? await Task.sleep(for: .milliseconds(150))
}

// MARK: - Retry and routing

@Suite("Device handoff — retries and routing that matches the audio")
@MainActor
struct DeviceSwitchRetryTests {

    @Test("A switch that fails while the device comes up is retried until it lands")
    func retriesUntilReady() async throws {
        let fix = HandoffFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.headphones.uid)
        let tap = try #require(fix.tap)
        tap.failingDevices = [fix.speakers.uid]
        tap.failuresLeft = 2

        fix.engine.setDevice(for: fix.app, deviceUID: fix.speakers.uid)
        await waitUntil { tap.currentDeviceUID == fix.speakers.uid }

        #expect(tap.currentDeviceUID == fix.speakers.uid)
        #expect(tap.switchAttempts == [fix.speakers.uid, fix.speakers.uid, fix.speakers.uid])
        #expect(fix.engine.getDeviceUID(for: fix.app) == fix.speakers.uid)
    }

    @Test("When every attempt fails, the app's routing points back at the device it plays on")
    func givesUpAndRollsBack() async throws {
        let fix = HandoffFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.headphones.uid)
        let tap = try #require(fix.tap)
        tap.failingDevices = [fix.speakers.uid]

        fix.engine.setDevice(for: fix.app, deviceUID: fix.speakers.uid)
        await waitUntil { tap.switchAttempts.count == 4 && fix.engine.getDeviceUID(for: fix.app) != fix.speakers.uid }

        #expect(tap.switchAttempts.count == 1 + fix.engine.switchRetryDelays.count)
        #expect(tap.currentDeviceUID == fix.headphones.uid)
        #expect(fix.engine.getDeviceUID(for: fix.app) == fix.headphones.uid)
    }

    @Test("Picking the device again after a failed switch tries again")
    func reselectRetries() async throws {
        let fix = HandoffFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.headphones.uid)
        let tap = try #require(fix.tap)
        tap.failingDevices = [fix.speakers.uid]
        fix.engine.setDevice(for: fix.app, deviceUID: fix.speakers.uid)
        await waitUntil { fix.engine.getDeviceUID(for: fix.app) == fix.headphones.uid && tap.switchAttempts.count == 4 }

        tap.failingDevices = []
        fix.engine.setDevice(for: fix.app, deviceUID: fix.speakers.uid)
        await waitUntil { tap.currentDeviceUID == fix.speakers.uid }

        #expect(tap.currentDeviceUID == fix.speakers.uid)
        #expect(fix.engine.getDeviceUID(for: fix.app) == fix.speakers.uid)
    }

    @Test("A newer selection stops the retries for the old one")
    func newerSelectionWins() async throws {
        let fix = HandoffFixture()
        fix.engine.switchRetryDelays = [.milliseconds(40), .milliseconds(40), .milliseconds(40)]
        fix.engine.setDevice(for: fix.app, deviceUID: fix.headphones.uid)
        let tap = try #require(fix.tap)
        tap.failingDevices = [fix.speakers.uid]

        fix.engine.setDevice(for: fix.app, deviceUID: fix.speakers.uid)
        await waitUntil { tap.switchAttempts.count == 1 }
        fix.engine.setDevice(for: fix.app, deviceUID: fix.monitors.uid)
        await waitUntil { tap.currentDeviceUID == fix.monitors.uid }
        await drain()

        #expect(tap.currentDeviceUID == fix.monitors.uid)
        #expect(fix.engine.getDeviceUID(for: fix.app) == fix.monitors.uid)
        #expect(tap.switchAttempts.filter { $0 == fix.speakers.uid }.count == 1)
    }
}

// MARK: - Replug

@Suite("Device handoff — replugging a device")
@MainActor
struct DeviceReplugTests {

    @Test("A replugged device that isn't alive yet: apps stay put until it is, then move back")
    func waitsUntilAlive() async throws {
        let fix = HandoffFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.headphones.uid)
        let tap = try #require(fix.tap)
        fix.unplug(fix.headphones)
        await waitUntil { tap.currentDeviceUID == fix.speakers.uid }

        fix.notAlive = [fix.headphones.id]
        fix.plug(fix.headphones)
        await drain()
        #expect(!tap.switchAttempts.contains(fix.headphones.uid))
        #expect(tap.currentDeviceUID == fix.speakers.uid)
        #expect(fix.engine.getDeviceUID(for: fix.app) == fix.speakers.uid)

        // The device comes alive; the alive watcher runs the connect path again.
        fix.notAlive = []
        fix.monitor.onDeviceConnected?(fix.headphones.uid, fix.headphones.name)
        await waitUntil { tap.currentDeviceUID == fix.headphones.uid }
        #expect(tap.currentDeviceUID == fix.headphones.uid)
        #expect(fix.engine.getDeviceUID(for: fix.app) == fix.headphones.uid)
        #expect(!fix.engine.isFollowingDefault(for: fix.app))
    }

    @Test("A replugged device whose first switches fail still gets the app back")
    func firstSwitchFails() async throws {
        let fix = HandoffFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.headphones.uid)
        let tap = try #require(fix.tap)
        fix.unplug(fix.headphones)
        await waitUntil { tap.currentDeviceUID == fix.speakers.uid }

        tap.failingDevices = [fix.headphones.uid]
        tap.failuresLeft = 2
        fix.plug(fix.headphones)
        await waitUntil { tap.currentDeviceUID == fix.headphones.uid }

        #expect(tap.currentDeviceUID == fix.headphones.uid)
        #expect(fix.engine.getDeviceUID(for: fix.app) == fix.headphones.uid)
    }

    @Test("Picking another device while a replug restore is still retrying: the pick wins and stays explicit")
    func pickDuringRestore() async throws {
        let fix = HandoffFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.headphones.uid)
        let tap = try #require(fix.tap)
        fix.unplug(fix.headphones)
        await waitUntil { tap.currentDeviceUID == fix.speakers.uid }

        fix.engine.switchRetryDelays = [.milliseconds(40), .milliseconds(40), .milliseconds(40)]
        tap.failingDevices = [fix.headphones.uid]
        fix.plug(fix.headphones)
        await waitUntil { tap.switchAttempts.contains(fix.headphones.uid) }
        fix.engine.setDevice(for: fix.app, deviceUID: fix.monitors.uid)
        await waitUntil { tap.currentDeviceUID == fix.monitors.uid }
        await drain()

        #expect(tap.currentDeviceUID == fix.monitors.uid)
        #expect(fix.engine.getDeviceUID(for: fix.app) == fix.monitors.uid)
        #expect(!fix.engine.isFollowingDefault(for: fix.app))
        #expect(fix.createdTaps.count == 1)
    }

    @Test("If every attempt fails, the app stays on the fallback and moves back on the next connect event")
    func retriedOnNextConnect() async throws {
        let fix = HandoffFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.headphones.uid)
        let tap = try #require(fix.tap)
        fix.unplug(fix.headphones)
        await waitUntil { tap.currentDeviceUID == fix.speakers.uid }

        tap.failingDevices = [fix.headphones.uid]
        fix.plug(fix.headphones)
        await waitUntil { tap.switchAttempts.filter { $0 == fix.headphones.uid }.count == 4 && fix.engine.isFollowingDefault(for: fix.app) }
        #expect(tap.currentDeviceUID == fix.speakers.uid)
        #expect(fix.engine.getDeviceUID(for: fix.app) == fix.speakers.uid)
        #expect(fix.engine.isFollowingDefault(for: fix.app), "shown as displaced while on the fallback")

        tap.failingDevices = []
        fix.monitor.onDeviceConnected?(fix.headphones.uid, fix.headphones.name)
        await waitUntil { tap.currentDeviceUID == fix.headphones.uid }
        #expect(tap.currentDeviceUID == fix.headphones.uid)
        #expect(fix.engine.getDeviceUID(for: fix.app) == fix.headphones.uid)
    }
}

// MARK: - Rebuilding a stuck tap

@Suite("Device handoff — rebuilding a tap that can't move")
@MainActor
struct DeviceRebuildTests {

    @Test("Unplugged, and the tap can't move to the fallback: it is rebuilt there instead")
    func rebuiltOnFallback() async throws {
        let fix = HandoffFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.headphones.uid)
        let stuck = try #require(fix.tap)
        stuck.failingDevices = [fix.speakers.uid]

        fix.unplug(fix.headphones)
        await waitUntil { fix.createdTaps.count == 2 }

        let rebuilt = try #require(fix.tap)
        #expect(rebuilt !== stuck)
        #expect(rebuilt.currentDeviceUID == fix.speakers.uid)
        #expect(fix.engine.getDeviceUID(for: fix.app) == fix.speakers.uid)
        #expect(fix.engine.isFollowingDefault(for: fix.app), "shown as displaced while on the fallback")
    }

    @Test("The rebuilt tap goes back to the device once it is replugged")
    func rebuiltTapReturns() async throws {
        let fix = HandoffFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.headphones.uid)
        try #require(fix.tap).failingDevices = [fix.speakers.uid]
        fix.unplug(fix.headphones)
        await waitUntil { fix.createdTaps.count == 2 }
        let rebuilt = try #require(fix.tap)

        fix.plug(fix.headphones)
        await waitUntil { rebuilt.currentDeviceUID == fix.headphones.uid }

        #expect(rebuilt.currentDeviceUID == fix.headphones.uid)
        #expect(fix.engine.getDeviceUID(for: fix.app) == fix.headphones.uid)
        #expect(!fix.engine.isFollowingDefault(for: fix.app))
    }
}

// MARK: - Destination chain

@Suite("Device handoff — the new device's chain from the first callback")
@MainActor
struct DeviceHandoffChainTests {

    @Test("The handoff carries the destination's volume, device EQ and loudness level")
    func handoffForDestination() throws {
        let fix = HandoffFixture()
        var appSettings = fix.settings.appSettings
        appSettings.loudnessCompensationEnabled = true
        fix.settings.updateAppSettings(appSettings)
        fix.volumes.volumes[fix.headphones.id] = 0.25
        fix.volumes.volumes[fix.speakers.id] = 0.9
        var speakerCurve = ParametricEQSettings()
        speakerCurve.bands[2] = ParametricBand(frequency: 130, gainDB: -6, q: 4)
        speakerCurve.rightTrimDB = -1
        fix.engine.setDeviceEQ(speakerCurve, for: fix.speakers.uid)
        fix.engine.setDevice(for: fix.app, deviceUID: fix.headphones.uid)
        fix.engine.setVolume(for: fix.app, to: 0.6)

        let handoff = try #require(fix.engine.handoff(for: fix.app, to: [fix.speakers.uid]))
        #expect(handoff.volume == 0.6)
        #expect(handoff.deviceEQ == speakerCurve)
        #expect(handoff.autoEQProfile == nil, "speakers don't take AutoEQ")
        #expect(handoff.loudnessVolume == Float(0.9) * Float(0.6))
        #expect(handoff.loudnessCompensationEnabled)
        #expect(fix.engine.handoff(for: fix.app, to: []) == nil)
    }

    @Test("After a switch, loudness compensation follows the new device's volume")
    func loudnessFollowsDevice() async throws {
        let fix = HandoffFixture()
        var appSettings = fix.settings.appSettings
        appSettings.loudnessCompensationEnabled = true
        fix.settings.updateAppSettings(appSettings)
        fix.volumes.volumes[fix.headphones.id] = 0.25
        fix.volumes.volumes[fix.speakers.id] = 0.9
        fix.engine.setDevice(for: fix.app, deviceUID: fix.headphones.uid)
        let tap = try #require(fix.tap)
        fix.engine.setVolume(for: fix.app, to: 1.0)
        #expect(tap.loudnessUpdates.last == 0.25)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.speakers.uid)
        await waitUntil { tap.currentDeviceUID == fix.speakers.uid && tap.loudnessUpdates.last == 0.9 }
        #expect(tap.loudnessUpdates.last == 0.9)
    }

    @Test("A replacement leveler carries on at the current gain instead of restarting at 0 dB")
    func levelerCarriesOn() {
        var settings = LoudnessEqualizerSettings()
        settings.enabled = true
        let sampleRate: Float = 48000
        let frames = 512
        func quietBlock(_ n: Int) -> [Float] {
            var block = [Float](repeating: 0, count: frames * 2)
            for f in 0..<frames {
                let v = 0.02 * sin(2 * Float.pi * 440 * Float(n * frames + f) / sampleRate)
                block[f * 2] = v
                block[f * 2 + 1] = v
            }
            return block
        }
        func run(_ leveler: LoudnessEqualizer, _ n: Int) -> Float {
            var block = quietBlock(n)
            block.withUnsafeMutableBufferPointer {
                leveler.process(input: $0.baseAddress!, output: $0.baseAddress!, frameCount: frames, channelCount: 2)
            }
            return sqrt(block.reduce(0) { $0 + $1 * $1 } / Float(block.count))
        }

        // Eight seconds of quiet audio: the leveler has raised its gain.
        let current = LoudnessEqualizer(settings: settings, sampleRate: sampleRate)
        let blocks = Int(sampleRate) * 8 / frames
        for n in 0..<blocks { _ = run(current, n) }
        #expect(current.currentGainDb > 3)

        let seeded = LoudnessEqualizer(settings: settings, sampleRate: sampleRate, initialGainDb: current.currentGainDb)
        let fresh = LoudnessEqualizer(settings: settings, sampleRate: sampleRate)
        let reference = run(current, blocks)
        let seededJump = 20 * log10(run(seeded, blocks) / reference)
        let freshJump = 20 * log10(run(fresh, blocks) / reference)
        #expect(abs(seededJump) < 0.5, "seeded replacement moved the level by \(seededJump) dB")
        #expect(freshJump < -3, "an unseeded replacement drops the level (\(freshJump) dB)")
    }

    @Test("AutoEQ's preamp mode is readable, so a replacement processor can copy it")
    func preampModeReadable() {
        let processor = AutoEQProcessor(sampleRate: 48000)
        #expect(processor.isPreampEnabled)
        processor.setPreampEnabled(false)
        #expect(!processor.isPreampEnabled)
    }
}

// MARK: - Capture source (level)

/// Follow-default apps are captured from the default device's stream. App-wide (stereo mixdown)
/// capture plays quieter on interfaces with more than two outputs, so switching away and back
/// must always land on the stream again, or the level doesn't come back.
@Suite("Device handoff — switching back restores the exact capture")
@MainActor
struct DeviceCaptureSourceTests {

    @Test("Choosing outputs in the device list: follow-default apps capture the new default's stream, there and back")
    func outputListRoundTrip() async throws {
        let fix = HandoffFixture()
        fix.volumes.defaultDeviceUID = fix.headphones.uid
        fix.engine.setDevice(for: fix.app, deviceUID: nil)
        let tap = try #require(fix.tap)
        #expect(tap.tapSourceDeviceUID == fix.headphones.uid)

        // macOS hasn't reported the change yet when the apps move (the mock never does).
        fix.engine.setDefaultOutputDevice(fix.speakers.id)
        await waitUntil { tap.currentDeviceUID == fix.speakers.uid }
        #expect(tap.tapSourceDeviceUID == fix.speakers.uid)

        fix.engine.setDefaultOutputDevice(fix.headphones.id)
        await waitUntil { tap.currentDeviceUID == fix.headphones.uid }
        #expect(tap.tapSourceDeviceUID == fix.headphones.uid)
    }

    @Test("Picking the default device by name keeps its stream capture: same level as System Audio, both ways")
    func explicitPickOfDefaultKeepsStream() async throws {
        let fix = HandoffFixture()
        fix.volumes.defaultDeviceUID = fix.headphones.uid
        fix.engine.setDevice(for: fix.app, deviceUID: nil)
        let tap = try #require(fix.tap)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.headphones.uid)
        await drain()
        #expect(tap.tapSourceDeviceUID == fix.headphones.uid)
        #expect(!fix.engine.isFollowingDefault(for: fix.app))

        fix.engine.setDevice(for: fix.app, deviceUID: nil)
        await drain()
        #expect(tap.tapSourceDeviceUID == fix.headphones.uid)
        #expect(fix.engine.isFollowingDefault(for: fix.app))
        #expect(tap.sourceRefreshes.isEmpty, "the capture never changed")
        #expect(tap.switchAttempts.isEmpty)
    }

    @Test("An app moved by name onto the default (from another device) gets the default's stream")
    func explicitMoveOntoDefault() async throws {
        let fix = HandoffFixture()
        fix.volumes.defaultDeviceUID = fix.headphones.uid
        fix.engine.setDevice(for: fix.app, deviceUID: fix.speakers.uid)
        let tap = try #require(fix.tap)
        #expect(tap.tapSourceDeviceUID == nil, "on a non-default device: app-wide")

        fix.engine.setDevice(for: fix.app, deviceUID: fix.headphones.uid)
        await waitUntil { tap.currentDeviceUID == fix.headphones.uid }
        #expect(tap.tapSourceDeviceUID == fix.headphones.uid)
    }

    @Test("A stale app-wide capture on the default is replaced when the default is picked again by name")
    func explicitPickRepairsStaleSource() async throws {
        let fix = HandoffFixture()
        fix.volumes.defaultDeviceUID = fix.headphones.uid
        fix.engine.setDevice(for: fix.app, deviceUID: fix.headphones.uid)
        let tap = try #require(fix.tap)
        tap.tapSourceDeviceUID = nil  // e.g. a stream tap that fell back to mixdown

        fix.engine.setDevice(for: fix.app, deviceUID: fix.headphones.uid)
        await waitUntil { tap.sourceRefreshes.count == 1 }
        #expect(tap.sourceRefreshes == [fix.headphones.uid])
        #expect(tap.tapSourceDeviceUID == fix.headphones.uid)
    }

    @Test("Default moves away from an app picked by name: it switches to app-wide capture before the change")
    func explicitReleasedBeforeDefaultChange() async throws {
        let fix = HandoffFixture()
        fix.volumes.defaultDeviceUID = fix.headphones.uid
        fix.engine.setDevice(for: fix.app, deviceUID: fix.headphones.uid)
        let tap = try #require(fix.tap)
        var defaultChangesAtRefresh: Int?
        tap.onRefresh = { defaultChangesAtRefresh = fix.volumes.setDefaultDeviceCalls.count }

        fix.engine.setDefaultOutputDevice(fix.speakers.id)
        await waitUntil { fix.volumes.setDefaultDeviceCalls.count == 1 }
        await drain()

        #expect(tap.sourceRefreshes == [nil])
        #expect(defaultChangesAtRefresh == 0, "released before macOS moves the app")
        #expect(tap.currentDeviceUID == fix.headphones.uid, "an explicit app stays on its device")
        #expect(fix.engine.getDeviceUID(for: fix.app) == fix.headphones.uid)
    }

    @Test("Default moves onto an app picked by name: it captures that device's stream")
    func explicitPickedUpByDefaultChange() async throws {
        let fix = HandoffFixture()
        fix.volumes.defaultDeviceUID = fix.headphones.uid
        fix.engine.setDevice(for: fix.app, deviceUID: fix.speakers.uid)
        let tap = try #require(fix.tap)
        #expect(tap.tapSourceDeviceUID == nil)

        fix.engine.setDefaultOutputDevice(fix.speakers.id)
        await waitUntil { tap.sourceRefreshes.count == 1 }

        #expect(tap.sourceRefreshes == [fix.speakers.uid])
        #expect(tap.tapSourceDeviceUID == fix.speakers.uid)
        #expect(tap.currentDeviceUID == fix.speakers.uid)
    }

    @Test("System Audio while already capturing the default's stream: no extra refresh")
    func noRedundantRefresh() async throws {
        let fix = HandoffFixture()
        fix.volumes.defaultDeviceUID = fix.headphones.uid
        fix.engine.setDevice(for: fix.app, deviceUID: nil)
        let tap = try #require(fix.tap)

        fix.engine.setDevice(for: fix.app, deviceUID: nil)
        await drain()
        #expect(tap.sourceRefreshes.isEmpty)
    }
}

// MARK: - Output-list handover

/// Choosing an output in the device list: follow-default apps get their new tap before macOS
/// changes the default, so the app's own move hands the sound over with no gap.
@Suite("Device handoff — output list handover")
@MainActor
struct OutputListHandoverTests {

    private func followingApp(_ fix: HandoffFixture) throws -> HandoffTap {
        fix.volumes.defaultDeviceUID = fix.headphones.uid
        fix.engine.setDevice(for: fix.app, deviceUID: nil)
        return try #require(fix.tap)
    }

    @Test("The new tap is prepared before the default changes, then handed over (no crossfade)")
    func preparedBeforeDefaultChange() async throws {
        let fix = HandoffFixture()
        let tap = try followingApp(fix)
        var defaultChangesAtPrepare: Int?
        tap.onPrepare = { defaultChangesAtPrepare = fix.volumes.setDefaultDeviceCalls.count }

        fix.engine.setDefaultOutputDevice(fix.speakers.id)
        await waitUntil { tap.completedHandovers == 1 }

        #expect(defaultChangesAtPrepare == 0)
        #expect(fix.volumes.setDefaultDeviceCalls == [fix.speakers.id])
        #expect(tap.preparedHandovers == [fix.speakers.uid])
        #expect(tap.switchAttempts.isEmpty, "handed over, not crossfaded")
        #expect(tap.currentDeviceUID == fix.speakers.uid)
        #expect(tap.tapSourceDeviceUID == fix.speakers.uid, "captured from the new default's stream")
        #expect(fix.engine.getDeviceUID(for: fix.app) == fix.speakers.uid)
        #expect(fix.engine.isFollowingDefault(for: fix.app))
    }

    @Test("There and back: each choice hands over and lands on that device's stream")
    func roundTrip() async throws {
        let fix = HandoffFixture()
        let tap = try followingApp(fix)

        fix.engine.setDefaultOutputDevice(fix.speakers.id)
        await waitUntil { tap.completedHandovers == 1 }
        fix.engine.setDefaultOutputDevice(fix.headphones.id)
        await waitUntil { tap.completedHandovers == 2 }

        #expect(tap.currentDeviceUID == fix.headphones.uid)
        #expect(tap.tapSourceDeviceUID == fix.headphones.uid)
        #expect(tap.switchAttempts.isEmpty)
    }

    @Test("A tap that can't be prepared moves the usual way once the default has changed")
    func prepareFailsFallsBack() async throws {
        let fix = HandoffFixture()
        let tap = try followingApp(fix)
        tap.failPrepare = true

        fix.engine.setDefaultOutputDevice(fix.speakers.id)
        await waitUntil { tap.currentDeviceUID == fix.speakers.uid }

        #expect(tap.switchAttempts == [fix.speakers.uid])
        #expect(tap.tapSourceDeviceUID == fix.speakers.uid)
        #expect(fix.engine.getDeviceUID(for: fix.app) == fix.speakers.uid)
    }

    @Test("If macOS refuses the new default, the prepared tap is dropped and nothing moves")
    func defaultRefusedCancels() async throws {
        let fix = HandoffFixture()
        let tap = try followingApp(fix)
        fix.volumes.setDefaultDeviceSucceeds = false

        fix.engine.setDefaultOutputDevice(fix.speakers.id)
        await waitUntil { tap.cancelledHandovers == 1 }
        await drain()

        #expect(tap.cancelledHandovers == 1)
        #expect(tap.completedHandovers == 0)
        #expect(tap.currentDeviceUID == fix.headphones.uid)
        #expect(fix.engine.getDeviceUID(for: fix.app) == fix.headphones.uid)
    }

    @Test("A newer choice made while the first is preparing wins, and the default isn't set back")
    func newerChoiceWins() async throws {
        let fix = HandoffFixture()
        let tap = try followingApp(fix)
        tap.prepareDelay = .milliseconds(60)

        fix.engine.setDefaultOutputDevice(fix.speakers.id)
        await waitUntil { tap.preparedHandovers.count == 1 }
        fix.engine.setDefaultOutputDevice(fix.monitors.id)
        await waitUntil { tap.cancelledHandovers == 1 && tap.currentDeviceUID == fix.monitors.uid }
        await drain()

        #expect(fix.volumes.setDefaultDeviceCalls == [fix.monitors.id])
        #expect(tap.currentDeviceUID == fix.monitors.uid)
        #expect(tap.tapSourceDeviceUID == fix.monitors.uid)
        #expect(fix.engine.getDeviceUID(for: fix.app) == fix.monitors.uid)
    }

    @Test("Handover phase: both taps play at full gain and the secondary's warmup is counted")
    func handoverPhaseGains() {
        var state = CrossfadeState()
        state.beginHandover()
        #expect(state.isActive)
        #expect(state.primaryMultiplier == 1)
        #expect(state.secondaryMultiplier == 1)
        _ = state.updateProgress(samples: CrossfadeState.minimumWarmupSamples)
        #expect(state.isWarmupComplete)
        #expect(state.progress == 0, "no fade in a handover")
        state.complete()
        #expect(state.phase == .idle)
    }
}
