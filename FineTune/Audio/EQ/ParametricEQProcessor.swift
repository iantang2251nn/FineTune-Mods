// FineTune/Audio/EQ/ParametricEQProcessor.swift
import Foundation
import Accelerate

/// RT-safe per-device parametric EQ processor.
///
/// Subclass of `BiquadProcessor` — inherits delay buffer management, atomic setup swaps,
/// stereo biquad processing, and NaN safety. Always runs `ParametricEQSettings.bandCount`
/// sections with band i in section i (a disabled band is an identity section), so toggling
/// a band never shifts filter state between sections. Output gain and the L/R trims are applied
/// before the cascade as one gain per channel.
final class ParametricEQProcessor: BiquadProcessor, @unchecked Sendable {

    /// Currently applied settings (needed for sample rate recalculation)
    private var _currentSettings: ParametricEQSettings = .flat

    /// Per-channel gain (output gain + that channel's trim) in linear scale (RT-safe atomic reads in process)
    private nonisolated(unsafe) var _leftGain: Float = 1.0
    private nonisolated(unsafe) var _rightGain: Float = 1.0

    /// Read-only access to current settings
    var currentSettings: ParametricEQSettings { _currentSettings }

    init(sampleRate: Double) {
        super.init(
            sampleRate: sampleRate,
            maxSections: ParametricEQSettings.bandCount,
            category: "ParametricEQProcessor"
        )
    }

    // MARK: - Settings Update

    /// Update the device curve (call from main thread). Flat or toggled-off settings
    /// disable processing entirely, so the stage is a bit-exact passthrough.
    func updateSettings(_ settings: ParametricEQSettings) {
        dispatchPrecondition(condition: .onQueue(.main))
        let validated = settings.validated()
        _currentSettings = validated

        guard validated.isEnabled, !validated.isEffectivelyFlat else {
            setEnabled(false)
            return
        }

        let coefficients = BiquadMath.coefficientsForParametricBands(validated.bands, sampleRate: sampleRate)
        guard let newSetup = coefficients.withUnsafeBufferPointer({ ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(ParametricEQSettings.bandCount))
        }) else {
            // Keep the previous setup active — don't break working audio
            logger.warning("vDSP_biquad_CreateSetup returned nil — skipping device EQ update")
            return
        }

        // Atomic state update + setup swap
        (_leftGain, _rightGain) = validated.channelGains
        swapSetup(newSetup)
        setEnabled(true)

        // Note: Do NOT reset delay buffers here - the filter naturally adapts to new
        // coefficients using existing state, producing smooth transitions without clicks.
    }

    // MARK: - BiquadProcessor Overrides

    override func recomputeCoefficients() -> (coefficients: [Double], sectionCount: Int)? {
        let coefficients = BiquadMath.coefficientsForParametricBands(_currentSettings.bands, sampleRate: sampleRate)
        return (coefficients, ParametricEQSettings.bandCount)
    }

    /// Apply output gain and the L/R trims before the biquad cascade (RT-safe).
    override func preProcess(output: UnsafeMutablePointer<Float>, frameCount: Int) {
        var left = _leftGain
        var right = _rightGain
        vDSP_vsmul(output, 2, &left, output, 2, vDSP_Length(frameCount))
        vDSP_vsmul(output.advanced(by: 1), 2, &right, output.advanced(by: 1), 2, vDSP_Length(frameCount))
    }
}
