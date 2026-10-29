// FineTune/Views/Components/ScrubValueField.swift
import SwiftUI
import AppKit

/// A label above a monospaced value. The value changes by vertical drag (Shift for fine),
/// scroll wheel, or clicking it to type; double-clicking the label resets it.
struct ScrubValueField: View {
    /// How drag distance maps onto the value.
    enum Scale {
        /// `perPoint` units per point of drag.
        case linear(perPoint: Double)
        /// `perPoint` octaves (factors of 2) per point of drag; scroll steps in the log2 domain.
        case log2(perPoint: Double)

        func apply(_ value: Double, points: Double) -> Double {
            switch self {
            case .linear(let perPoint): return value + points * perPoint
            case .log2(let perPoint): return value * pow(2, points * perPoint)
            }
        }
    }

    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let scale: Scale
    let format: (Double) -> String
    let parse: (String) -> Double?
    let onChange: (Double) -> Void
    let onReset: () -> Void
    var resetHelp: String = "Double-click to reset"

    @State private var isEditing = false
    @State private var inputText = ""
    @State private var isHovered = false
    @State private var dragValue: Double?
    @State private var lastDragY: CGFloat = 0
    @FocusState private var isFocused: Bool
    @State private var coordinator = ClickOutsideCoordinator()
    @State private var componentFrame: CGRect = .zero
    @Environment(PopupTextEntryCoordinator.self) private var textEntry: PopupTextEntryCoordinator?

    private func clamped(_ v: Double) -> Double {
        min(max(v, range.lowerBound), range.upperBound)
    }

    /// Scroll-wheel binding: linear values step directly, log values step in the log2 domain.
    private var scrollBinding: Binding<Double> {
        switch scale {
        case .linear:
            return Binding(get: { value }, set: { onChange(clamped($0)) })
        case .log2:
            return Binding(get: { Foundation.log2(value) }, set: { onChange(clamped(pow(2, $0))) })
        }
    }

    private var scrollRange: ClosedRange<Double> {
        switch scale {
        case .linear: return range
        case .log2: return Foundation.log2(range.lowerBound)...Foundation.log2(range.upperBound)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onReset() }
                .help(resetHelp)
                .accessibilityAction(named: "Reset \(label)") { onReset() }

            valueView
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var valueView: some View {
        Group {
            if isEditing {
                TextField("", text: $inputText)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit { commit() }
                    .onExitCommand { cancel() }
            } else {
                Text(format(value))
                    .foregroundStyle(isHovered || dragValue != nil ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
                    .contentShape(Rectangle())
                    .gesture(scrubGesture)
                    .onTapGesture { startEditing() }
                    .scrollWheelStep(scrollBinding, in: scrollRange)
                    .help("Drag up or down to adjust (Shift for fine), scroll, or click to type")
            }
        }
        .font(DesignTokens.Typography.percentage)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background {
            GeometryReader { geo in
                Color.clear
                    .preference(key: ScrubFramePreferenceKey.self, value: geo.frame(in: .global))
            }
        }
        .onPreferenceChange(ScrubFramePreferenceKey.self) { frame in
            componentFrame = screenFrame(from: frame)
        }
        .background {
            if isEditing {
                RoundedRectangle(cornerRadius: 4)
                    .fill(DesignTokens.Colors.accentPrimary.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(DesignTokens.Colors.accentPrimary.opacity(0.4), lineWidth: 1)
                    }
            } else if isHovered || dragValue != nil {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.08))
            }
        }
        .onHover { isHovered = $0 }
        .onChange(of: isEditing) { _, editing in
            if !editing {
                coordinator.removeMonitors()
                // Mouse edit released first responder; ask the popup to refocus the nav anchor.
                textEntry?.navRestoreNonce += 1
            }
        }
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }

    /// Vertical drag: up increases. Accumulates unrounded so slow and Shift drags still move
    /// past the stored value's resolution.
    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { gesture in
                let start = dragValue ?? value
                let dy = gesture.translation.height - lastDragY
                lastDragY = gesture.translation.height
                let factor = NSEvent.modifierFlags.contains(.shift) ? 0.1 : 1.0
                let next = clamped(scale.apply(start, points: -Double(dy) * factor))
                dragValue = next
                onChange(next)
            }
            .onEnded { _ in
                dragValue = nil
                lastDragY = 0
            }
    }

    private func startEditing() {
        textEntry?.buffer = nil
        inputText = format(value)
        isEditing = true
        coordinator.install(excludingFrame: componentFrame) { [self] in
            commit()
        }
        Task { @MainActor in
            isFocused = true
        }
    }

    /// Valid input applies (clamped); anything else reverts.
    private func commit() {
        guard isEditing else { return }
        if let parsed = parse(inputText), parsed.isFinite {
            onChange(clamped(parsed))
        }
        isEditing = false
    }

    private func cancel() {
        isEditing = false
    }
}

private struct ScrubFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

// MARK: - Formatting and Parsing

/// Display and typed-input rules for the parametric EQ value fields.
enum ParametricValueFormat {
    /// `49.1 Hz`, `130 Hz`, `1.20 kHz`, `12.0 kHz`
    static func frequency(_ hz: Double) -> String {
        if hz >= 10_000 { return String(format: "%.1f kHz", hz / 1000) }
        if hz >= 1000 { return String(format: "%.2f kHz", hz / 1000) }
        if hz >= 100 { return String(format: "%.0f Hz", hz) }
        return String(format: "%.1f Hz", hz)
    }

    /// `−7.1 dB`, `+3.0 dB`, `0.0 dB`
    static func gain(_ db: Double) -> String {
        let magnitude = String(format: "%.1f", abs(db))
        if magnitude == "0.0" { return "0.0 dB" }
        return (db < 0 ? "\u{2212}" : "+") + magnitude + " dB"
    }

    /// `10.00`
    static func q(_ q: Double) -> String {
        String(format: "%.2f", q)
    }

    /// Accepts `130`, `130 Hz`, `1.2k`, `1.2 kHz`, `1200`.
    static func parseFrequency(_ text: String) -> Double? {
        var cleaned = text.lowercased().replacingOccurrences(of: " ", with: "")
        if cleaned.hasSuffix("hz") { cleaned.removeLast(2) }
        var multiplier = 1.0
        if cleaned.hasSuffix("k") {
            multiplier = 1000
            cleaned.removeLast()
        }
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return value * multiplier
    }

    /// Accepts `-7.1`, `−7.1`, `+3`, `-7.1 dB`.
    static func parseGain(_ text: String) -> Double? {
        var cleaned = text.lowercased()
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: " ", with: "")
        if cleaned.hasSuffix("db") { cleaned.removeLast(2) }
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }

    /// Accepts `10`, `10.00`, `q 10`.
    static func parseQ(_ text: String) -> Double? {
        var cleaned = text.lowercased().replacingOccurrences(of: " ", with: "")
        if cleaned.hasPrefix("q") { cleaned.removeFirst() }
        guard let value = Double(cleaned), value.isFinite, value > 0 else { return nil }
        return value
    }
}
