// FineTune/Audio/Engine/TapInitialState.swift
import Foundation

/// Persisted settings applied to a fresh ProcessTapController before its IOProc starts.
struct TapInitialState {
    var eqSettings: EQSettings = .flat
    var deviceEQ: ParametricEQSettings = .flat
    var autoEQProfile: AutoEQProfile? = nil
    var autoEQPreampEnabled: Bool = false
    var loudnessVolume: Float = 1.0
    var loudnessCompensationEnabled: Bool = false
    var loudnessEqualizerSettings: LoudnessEqualizerSettings = .init()
}

/// What the destination of a device switch needs from its first callback: that output's
/// effective volume, device EQ, AutoEQ profile and loudness level. Without it the incoming side
/// of a crossfade plays the old device's settings and the right ones land afterwards as a step.
struct TapHandoff {
    var volume: Float
    var deviceEQ: ParametricEQSettings
    var autoEQProfile: AutoEQProfile?
    var loudnessVolume: Float
    var loudnessCompensationEnabled: Bool
}
