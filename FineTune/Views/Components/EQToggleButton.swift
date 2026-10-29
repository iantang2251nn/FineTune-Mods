// FineTune/Views/Components/EQToggleButton.swift
import SwiftUI

/// The `slider.vertical.3` / `xmark` button that opens and closes an EQ panel.
/// Shared by app rows and output device rows.
struct EQToggleButton: View {
    let isExpanded: Bool
    /// Tints the closed icon to signal an active curve (device rows).
    var isActive: Bool = false
    let onToggle: () -> Void

    @State private var isHovered = false

    private var color: Color {
        if isExpanded {
            return DesignTokens.Colors.interactiveActive
        } else if isActive {
            return DesignTokens.Colors.accentPrimary
        } else if isHovered {
            return DesignTokens.Colors.interactiveHover
        } else {
            return DesignTokens.Colors.interactiveDefault
        }
    }

    var body: some View {
        Button {
            onToggle()
        } label: {
            ZStack {
                Image(systemName: "slider.vertical.3")
                    .opacity(isExpanded ? 0 : 1)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))

                Image(systemName: "xmark")
                    .opacity(isExpanded ? 1 : 0)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .font(.system(size: 12))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .frame(
                minWidth: DesignTokens.Dimensions.minTouchTarget,
                minHeight: DesignTokens.Dimensions.minTouchTarget
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Close Equalizer" : "Equalizer")
        .onHover { isHovered = $0 }
        .help(isExpanded ? "Close Equalizer" : "Equalizer")
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isExpanded)
        .animation(DesignTokens.Animation.hover, value: isHovered)
    }
}
