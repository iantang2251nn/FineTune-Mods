// FineTune/Views/ParametricEQPanelView.swift
import SwiftUI

/// Device parametric EQ panel, shown inside an output device row.
/// Same recessed background, padding and header structure as `EQPanelView`.
struct ParametricEQPanelView: View {
    @Binding var settings: ParametricEQSettings
    /// Owned by the popup so the selection survives collapsing the panel.
    @Binding var selectedBand: Int
    let presets: [UserParametricPreset]
    let sampleRate: Double
    let onSettingsChanged: (ParametricEQSettings) -> Void
    let onSavePreset: (String, ParametricEQSettings) -> Void
    let onDeletePreset: (UUID) -> Void
    let onRenamePreset: (UUID, String) -> Void
    var onImport: (() -> Void)? = nil
    var onExport: (() -> Void)? = nil
    /// Result of the last import/export, shown under the header.
    var statusMessage: String? = nil

    @State private var isSaving = false
    @State private var savePresetName = ""
    @FocusState private var isSaveFieldFocused: Bool

    @State private var isRenaming = false
    @State private var renamePresetName = ""
    @State private var renamingPresetID: UUID?
    @FocusState private var isRenameFieldFocused: Bool

    private var bandIndex: Int { min(max(selectedBand, 0), ParametricEQSettings.bandCount - 1) }
    private var band: ParametricBand { settings.bands[bandIndex] }

    /// Applies an edit, stores it at storage resolution and reports it.
    private func update(_ change: (inout ParametricEQSettings) -> Void) {
        var updated = settings
        change(&updated)
        settings = updated.validated()
        onSettingsChanged(settings)
    }

    // MARK: - Preset Matching

    /// The user preset whose curve matches the current curve, if any (ignores the on/off toggle).
    private var currentPreset: UserParametricPreset? {
        presets.first { $0.settings.curveEquals(settings) }
    }

    /// The currently selected picker item ("Flat", a user preset, or nil for "Custom").
    private var selectedPickerItem: ParametricPickerItem? {
        if settings.curveEquals(.flat) { return .flat }
        if let preset = currentPreset { return ParametricPickerItem(preset: preset) }
        return nil
    }

    private var isCustomCurve: Bool { selectedPickerItem == nil }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 10) {
            header
                .zIndex(1)  // Ensure dropdown renders above the curve

            if let statusMessage {
                Text(statusMessage)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            VStack(spacing: 8) {
                ParametricEQCurveView(
                    settings: settings,
                    sampleRate: sampleRate,
                    selectedBand: bandIndex,
                    onSelectBand: { selectedBand = $0 },
                    onBandChange: { index, frequency, gainDB in
                        update { s in
                            s.bands[index].frequency = frequency
                            s.bands[index].gainDB = gainDB
                        }
                    },
                    onResetGain: { index in update { $0.bands[index].gainDB = 0 } },
                    onQChange: { index, q in update { $0.bands[index].q = q } }
                )
                .frame(height: 80)

                bandRow
                controlStrip
            }
            .opacity(settings.isEnabled ? 1.0 : 0.3)
            .allowsHitTesting(settings.isEnabled)
            .animation(.easeInOut(duration: 0.2), value: settings.isEnabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(DesignTokens.Colors.recessedBackground)
        }
        .padding(.horizontal, 2)
        .padding(.top, DesignTokens.Spacing.xs)
        .padding(.bottom, DesignTokens.Spacing.xs)
        .animation(DesignTokens.Animation.quick, value: isSaving)
        .animation(DesignTokens.Animation.quick, value: isRenaming)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                Toggle("", isOn: Binding(
                    get: { settings.isEnabled },
                    set: { isOn in update { $0.isEnabled = isOn } }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.7)
                .labelsHidden()
                Text("Device EQ")
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundStyle(.primary)
            }

            if isRenaming {
                renamePresetField
                    .transition(.blurReplace.combined(with: .opacity))
            } else if isSaving {
                savePresetField
                    .transition(.blurReplace.combined(with: .opacity))
            } else {
                Spacer()

                if currentPreset != nil {
                    renameButton
                        .transition(.blurReplace.combined(with: .opacity))
                } else if isCustomCurve {
                    saveButton
                        .transition(.blurReplace.combined(with: .opacity))
                }
            }

            HStack(spacing: DesignTokens.Spacing.sm) {
                Text("Preset")
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)

                ParametricPresetPicker(
                    selectedItem: selectedPickerItem,
                    presets: presets,
                    onFlatSelected: {
                        update { s in
                            s.bands = ParametricEQSettings.flat.bands
                            s.outputGainDB = 0
                        }
                    },
                    onPresetSelected: { preset in
                        // Copies the curve; the device keeps its own on/off state.
                        update { s in
                            s.bands = preset.settings.bands
                            s.outputGainDB = preset.settings.outputGainDB
                        }
                    },
                    onDeletePreset: onDeletePreset,
                    onImport: onImport,
                    onExport: onExport
                )
            }
        }
    }

    // MARK: - Band Row

    private var bandRow: some View {
        HStack(spacing: 4) {
            ForEach(0..<ParametricEQSettings.bandCount, id: \.self) { index in
                bandChip(index)
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            trimField("L", channel: "Left", \.leftTrimDB)
            trimField("R", channel: "Right", \.rightTrimDB)

            ScrubValueField(
                label: "OUTPUT",
                value: Double(settings.outputGainDB),
                range: Double(ParametricEQSettings.outputGainRange.lowerBound)...Double(ParametricEQSettings.outputGainRange.upperBound),
                scale: .linear(perPoint: 0.1),
                format: ParametricValueFormat.gain,
                parse: ParametricValueFormat.parseGain,
                onChange: { value in update { $0.outputGainDB = Float(value) } },
                onReset: { update { $0.outputGainDB = 0 } },
                resetHelp: "Double-click to reset to 0 dB"
            )
        }
    }

    /// A channel trim field, with the same input as OUTPUT.
    private func trimField(_ label: String, channel: String, _ trim: WritableKeyPath<ParametricEQSettings, Float>) -> some View {
        ScrubValueField(
            label: label,
            value: Double(settings[keyPath: trim]),
            range: Double(ParametricEQSettings.trimRange.lowerBound)...Double(ParametricEQSettings.trimRange.upperBound),
            scale: .linear(perPoint: 0.1),
            format: ParametricValueFormat.trim,
            parse: { ParametricValueFormat.parseTrim($0, channel: Character(label)) },
            onChange: { value in update { $0[keyPath: trim] = Float(value) } },
            onReset: { update { $0[keyPath: trim] = 0 } },
            resetHelp: "\(channel) channel trim in dB. Double-click to reset to 0 dB"
        )
        .frame(width: 44, alignment: .leading)
    }

    private func bandChip(_ index: Int) -> some View {
        let chipBand = settings.bands[index]
        let isSelected = index == bandIndex
        return Text("\(index + 1)")
            .font(DesignTokens.Typography.eqLabel)
            .foregroundStyle(isSelected ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
            .frame(width: 22, height: 18)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? DesignTokens.Colors.accentPrimary.opacity(0.25) : DesignTokens.Colors.pickerBackground)
            }
            .overlay(alignment: .topTrailing) {
                // Bands in use are visible at a glance.
                if chipBand.gainDB != 0 {
                    Circle()
                        .fill(DesignTokens.Colors.accentPrimary)
                        .frame(width: 4, height: 4)
                        .offset(x: -2, y: 2)
                }
            }
            .opacity(chipBand.isEnabled ? 1.0 : 0.4)
            .contentShape(Rectangle())
            .onTapGesture { selectedBand = index }
            // Simultaneous so the single-click selection isn't delayed waiting for a second click.
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                update { $0.bands[index].gainDB = 0 }
            })
            .help(Self.chipHelp(index))
            .accessibilityLabel("Band \(index + 1), \(Self.roleName(index))")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Control Strip

    private var controlStrip: some View {
        HStack(alignment: .bottom, spacing: DesignTokens.Spacing.md) {
            Text("\(bandIndex + 1) · \(Self.roleName(bandIndex).uppercased())")
                .font(DesignTokens.Typography.caption.weight(.semibold))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .frame(width: 96, alignment: .leading)
                .padding(.bottom, 2)

            ScrubValueField(
                label: "GAIN",
                value: Double(band.gainDB),
                range: Double(ParametricEQSettings.gainRange.lowerBound)...Double(ParametricEQSettings.gainRange.upperBound),
                scale: .linear(perPoint: 0.1),
                format: ParametricValueFormat.gain,
                parse: ParametricValueFormat.parseGain,
                onChange: { value in update { $0.bands[bandIndex].gainDB = Float(value) } },
                onReset: { update { $0.bands[bandIndex].gainDB = 0 } },
                resetHelp: "Double-click to reset to 0 dB"
            )
            .frame(width: 64, alignment: .leading)

            ScrubValueField(
                label: "FREQ",
                value: band.frequency,
                range: ParametricEQSettings.frequencyRange,
                scale: .log2(perPoint: 1.0 / 48.0),
                format: ParametricValueFormat.frequency,
                parse: ParametricValueFormat.parseFrequency,
                onChange: { value in update { $0.bands[bandIndex].frequency = value } },
                onReset: {
                    update { $0.bands[bandIndex].frequency = ParametricEQSettings.defaultFrequencies[bandIndex] }
                },
                resetHelp: "Double-click to reset to this band's default"
            )
            .frame(width: 72, alignment: .leading)

            ScrubValueField(
                label: "Q",
                value: band.q,
                range: ParametricEQSettings.qRange(ofBand: bandIndex),
                scale: .log2(perPoint: 1.0 / 100.0),
                format: ParametricValueFormat.q,
                parse: ParametricValueFormat.parseQ,
                onChange: { value in update { $0.bands[bandIndex].q = value } },
                onReset: { update { $0.bands[bandIndex].q = ParametricEQSettings.defaultQ(ofBand: bandIndex) } },
                resetHelp: "Double-click to reset to \(ParametricValueFormat.q(ParametricEQSettings.defaultQ(ofBand: bandIndex)))"
            )
            .frame(width: 48, alignment: .leading)

            Spacer(minLength: 0)

            Toggle("", isOn: Binding(
                get: { band.isEnabled },
                set: { isOn in update { $0.bands[bandIndex].isEnabled = isOn } }
            ))
            .toggleStyle(.switch)
            .scaleEffect(0.7)
            .labelsHidden()
            .help("Turn band \(bandIndex + 1) on or off")
        }
    }

    // MARK: - Band Roles

    static func roleName(_ index: Int) -> String {
        switch ParametricEQSettings.type(ofBand: index) {
        case .lowShelf: return "Low shelf"
        case .highShelf: return "High shelf"
        case .peaking: return "Peak"
        }
    }

    static func chipHelp(_ index: Int) -> String {
        let role = ParametricEQSettings.type(ofBand: index) == .peaking ? "" : "\(roleName(index)). "
        return "\(role)Double-click to reset gain to 0 dB"
    }

    // MARK: - Save Button

    private var saveButton: some View {
        Button {
            savePresetName = ""
            isSaving = true
            Task { @MainActor in
                isSaveFieldFocused = true
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 13))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DesignTokens.Colors.interactiveDefault)
        }
        .buttonStyle(.plain)
        .help("Save current curve as preset")
        .accessibilityLabel("Save current device EQ curve as a new preset")
    }

    // MARK: - Save Preset Field

    private var savePresetField: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            TextField("Preset name", text: $savePresetName)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .focused($isSaveFieldFocused)
                .onSubmit { commitSave() }
                .onExitCommand { cancelSave() }

            Button {
                commitSave()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(
                        savePresetName.trimmingCharacters(in: .whitespaces).isEmpty
                            ? DesignTokens.Colors.textTertiary
                            : DesignTokens.Colors.accentPrimary
                    )
            }
            .buttonStyle(.plain)
            .disabled(savePresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Save preset")
            .accessibilityLabel("Confirm save preset")

            Button {
                cancelSave()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
            .accessibilityLabel("Cancel saving preset")
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .strokeBorder(DesignTokens.Colors.menuBorderHover, lineWidth: 0.5)
        }
    }

    // MARK: - Save Actions

    private func commitSave() {
        let trimmed = savePresetName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Store with isEnabled = true and trims at 0 dB — all per-device state, not preset state
        var presetSettings = settings
        presetSettings.isEnabled = true
        presetSettings.leftTrimDB = 0
        presetSettings.rightTrimDB = 0
        onSavePreset(trimmed, presetSettings)
        isSaving = false
        savePresetName = ""
    }

    private func cancelSave() {
        isSaving = false
        savePresetName = ""
    }

    // MARK: - Rename Button

    private var renameButton: some View {
        Button {
            if let preset = currentPreset {
                renamingPresetID = preset.id
                renamePresetName = preset.name
                isRenaming = true
                Task { @MainActor in
                    isRenameFieldFocused = true
                }
            }
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 12))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DesignTokens.Colors.interactiveDefault)
        }
        .buttonStyle(.plain)
        .help("Rename preset")
        .accessibilityLabel("Rename current preset")
    }

    // MARK: - Rename Preset Field

    private var renamePresetField: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            TextField("Preset name", text: $renamePresetName)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .focused($isRenameFieldFocused)
                .onSubmit { commitRename() }
                .onExitCommand { cancelRename() }

            Button {
                commitRename()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(
                        renamePresetName.trimmingCharacters(in: .whitespaces).isEmpty
                            ? DesignTokens.Colors.textTertiary
                            : DesignTokens.Colors.accentPrimary
                    )
            }
            .buttonStyle(.plain)
            .disabled(renamePresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Confirm rename")
            .accessibilityLabel("Confirm rename preset")

            Button {
                cancelRename()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
            .accessibilityLabel("Cancel renaming preset")
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .strokeBorder(DesignTokens.Colors.menuBorderHover, lineWidth: 0.5)
        }
    }

    // MARK: - Rename Actions

    private func commitRename() {
        let trimmed = renamePresetName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let id = renamingPresetID else { return }
        onRenamePreset(id, trimmed)
        isRenaming = false
        renamePresetName = ""
        renamingPresetID = nil
    }

    private func cancelRename() {
        isRenaming = false
        renamePresetName = ""
        renamingPresetID = nil
    }
}

// MARK: - Response Curve

/// Log-frequency response of the device curve (20 Hz–20 kHz, −24 to +12 dB) with one node per band.
/// Drag a node to move its frequency (horizontal) and gain (vertical), scroll over it for Q,
/// double-click it to reset its gain.
struct ParametricEQCurveView: View {
    let settings: ParametricEQSettings
    let sampleRate: Double
    let selectedBand: Int
    let onSelectBand: (Int) -> Void
    var onBandChange: (Int, Double, Float) -> Void = { _, _, _ in }
    var onResetGain: (Int) -> Void = { _ in }
    var onQChange: (Int, Double) -> Void = { _, _ in }

    static let minFrequency = 20.0
    static let maxFrequency = 20000.0
    static let maxDB = 12.0
    static let minDB = -24.0
    static let pointCount = 256

    @State private var response: [Double] = []
    /// Pointer offset from the dragged node's center, so grabbing off-center doesn't jump.
    @State private var dragOffset: CGSize?

    private static let coordinateSpaceName = "parametricEQCurve"

    static func frequency(atFraction x: Double) -> Double {
        minFrequency * pow(maxFrequency / minFrequency, x)
    }

    static func fraction(ofFrequency f: Double) -> Double {
        log(f / minFrequency) / log(maxFrequency / minFrequency)
    }

    /// Response in dB at `pointCount` log-spaced frequencies: the same sections the processor
    /// runs, plus the output gain. Frequencies at or past Nyquist read the response just below it.
    static func response(for settings: ParametricEQSettings, sampleRate: Double) -> [Double] {
        let coefficients = BiquadMath.coefficientsForParametricBands(settings.bands, sampleRate: sampleRate)
        let nyquistLimit = sampleRate / 2 * 0.999
        return (0..<pointCount).map { i in
            let f = min(frequency(atFraction: Double(i) / Double(pointCount - 1)), nyquistLimit)
            return BiquadMath.cascadeMagnitudeDB(coefficients, frequency: f, sampleRate: sampleRate)
                + Double(settings.outputGainDB)
        }
    }

    private func point(fraction: Double, db: Double, in size: CGSize) -> CGPoint {
        let clampedDB = min(max(db, Self.minDB), Self.maxDB)
        return CGPoint(
            x: fraction * size.width,
            y: (Self.maxDB - clampedDB) / (Self.maxDB - Self.minDB) * size.height
        )
    }

    private func nodeCenter(_ index: Int, in size: CGSize) -> CGPoint {
        let band = settings.bands[index]
        return point(fraction: Self.fraction(ofFrequency: band.frequency), db: Double(band.gainDB), in: size)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let grid = GraphicsContext.Shading.color(DesignTokens.Colors.textTertiary.opacity(0.35))
                    let labelFont = Font.system(size: 8, weight: .medium, design: .monospaced)

                    // Frequency grid
                    for (f, label) in [(100.0, "100"), (1000.0, "1k"), (10000.0, "10k")] {
                        let x = Self.fraction(ofFrequency: f) * size.width
                        var line = Path()
                        line.move(to: CGPoint(x: x, y: 0))
                        line.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(line, with: grid, lineWidth: 0.5)
                        context.draw(
                            Text(label).font(labelFont).foregroundStyle(DesignTokens.Colors.textTertiary),
                            at: CGPoint(x: x + 2, y: size.height - 1),
                            anchor: .bottomLeading
                        )
                    }

                    // 0 dB line and range labels
                    let zeroY = point(fraction: 0, db: 0, in: size).y
                    var zeroLine = Path()
                    zeroLine.move(to: CGPoint(x: 0, y: zeroY))
                    zeroLine.addLine(to: CGPoint(x: size.width, y: zeroY))
                    context.stroke(zeroLine, with: .color(DesignTokens.Colors.unityMarker.opacity(0.6)), lineWidth: 0.75)
                    for (db, label, anchor) in [(Self.maxDB, "+12", UnitPoint.topLeading), (0, "0", .bottomLeading), (Self.minDB, "\u{2212}24", .bottomLeading)] {
                        context.draw(
                            Text(label).font(labelFont).foregroundStyle(DesignTokens.Colors.textTertiary),
                            at: CGPoint(x: 2, y: point(fraction: 0, db: db, in: size).y),
                            anchor: anchor
                        )
                    }

                    // Response curve
                    if response.count > 1 {
                        var curve = Path()
                        for (i, db) in response.enumerated() {
                            let p = point(fraction: Double(i) / Double(response.count - 1), db: db, in: size)
                            if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
                        }
                        context.stroke(curve, with: .color(DesignTokens.Colors.accentPrimary), lineWidth: 1.5)
                    }

                    // Band nodes: disabled hollow, selected in the accent color
                    for index in 0..<ParametricEQSettings.bandCount {
                        let center = nodeCenter(index, in: size)
                        let node = Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
                        let color = index == selectedBand ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary
                        if settings.bands[index].isEnabled {
                            context.fill(node, with: .color(color))
                        } else {
                            context.stroke(node, with: .color(color), lineWidth: 1)
                        }
                    }

                    // Peak readout (device curve only, not stacked app EQ)
                    if let peak = response.max(), peak > 0.05 {
                        context.draw(
                            Text("peak \(ParametricValueFormat.gain(peak))")
                                .font(labelFont)
                                .foregroundStyle(DesignTokens.Colors.textTertiary),
                            at: CGPoint(x: size.width - 2, y: 1),
                            anchor: .topTrailing
                        )
                    }
                }

                // Only the nodes take pointer input, so scrolling elsewhere still scrolls the popup.
                ForEach(0..<ParametricEQSettings.bandCount, id: \.self) { index in
                    nodeHandle(index, size: geo.size)
                }
            }
            .coordinateSpace(.named(Self.coordinateSpaceName))
        }
        .onAppear { response = Self.response(for: settings, sampleRate: sampleRate) }
        .onChange(of: settings) { _, newValue in response = Self.response(for: newValue, sampleRate: sampleRate) }
        .onChange(of: sampleRate) { _, newValue in response = Self.response(for: settings, sampleRate: newValue) }
        .accessibilityElement()
        .accessibilityLabel("Device EQ response curve")
    }

    /// Invisible hit area over one node: press selects, drag moves, scroll changes Q,
    /// double-click resets the gain.
    private func nodeHandle(_ index: Int, size: CGSize) -> some View {
        let center = nodeCenter(index, in: size)
        let qRange = ParametricEQSettings.qRange(ofBand: index)
        return Color.clear
            .frame(width: 20, height: 20)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
                    .onChanged { value in
                        if dragOffset == nil {
                            onSelectBand(index)
                            dragOffset = CGSize(
                                width: value.startLocation.x - center.x,
                                height: value.startLocation.y - center.y
                            )
                        }
                        guard let offset = dragOffset, value.translation != .zero, size.width > 0, size.height > 0 else { return }
                        let x = min(max(value.location.x - offset.width, 0), size.width)
                        let y = min(max(value.location.y - offset.height, 0), size.height)
                        let frequency = Self.frequency(atFraction: x / size.width)
                        let gainDB = Self.maxDB - y / size.height * (Self.maxDB - Self.minDB)
                        onBandChange(index, frequency, Float(gainDB))
                    }
                    .onEnded { _ in dragOffset = nil }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { onResetGain(index) })
            .scrollWheelStep(
                Binding(
                    get: { log2(settings.bands[index].q) },
                    set: { onQChange(index, pow(2, $0)) }
                ),
                in: log2(qRange.lowerBound)...log2(qRange.upperBound)
            )
            .help("Band \(index + 1): drag to move, scroll to change Q, double-click to reset gain")
            .position(center)
    }
}
