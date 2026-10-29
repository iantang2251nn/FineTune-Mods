// FineTune/Views/Components/ParametricPresetPicker.swift
import SwiftUI

/// Sections for the parametric preset picker: "Flat" first, then the user's presets,
/// then file import/export.
enum ParametricPickerSection: String, Identifiable, Hashable {
    case defaults = "Default"
    case myPresets = "My Presets"
    case file = "File"

    var id: String { rawValue }
}

/// A single item in the picker — "Flat" or a user parametric preset.
struct ParametricPickerItem: Identifiable, Hashable {
    let id: String
    let name: String
    let presetID: UUID?

    static let flat = ParametricPickerItem(id: "flat", name: "Flat", presetID: nil)
    static let importFile = ParametricPickerItem(id: "import", name: "Import…", presetID: nil)
    static let exportFile = ParametricPickerItem(id: "export", name: "Export…", presetID: nil)

    init(preset: UserParametricPreset) {
        self.id = "parametric-\(preset.id.uuidString)"
        self.name = preset.name
        self.presetID = preset.id
    }

    private init(id: String, name: String, presetID: UUID?) {
        self.id = id
        self.name = name
        self.presetID = presetID
    }

    static func == (lhs: ParametricPickerItem, rhs: ParametricPickerItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Parametric Preset Picker

/// Sibling of `EQPresetPicker` for device parametric curves, with the same visuals.
/// Shows "Custom" when no item matches the current curve.
struct ParametricPresetPicker: View {
    let selectedItem: ParametricPickerItem?
    let presets: [UserParametricPreset]
    let onFlatSelected: () -> Void
    let onPresetSelected: (UserParametricPreset) -> Void
    let onDeletePreset: (UUID) -> Void
    var onImport: (() -> Void)? = nil
    var onExport: (() -> Void)? = nil

    private var sections: [ParametricPickerSection] {
        var result: [ParametricPickerSection] = [.defaults]
        if !presets.isEmpty { result.append(.myPresets) }
        if onImport != nil || onExport != nil { result.append(.file) }
        return result
    }

    private func items(for section: ParametricPickerSection) -> [ParametricPickerItem] {
        switch section {
        case .defaults: return [.flat]
        case .myPresets: return presets.map { ParametricPickerItem(preset: $0) }
        case .file:
            return (onImport != nil ? [.importFile] : []) + (onExport != nil ? [.exportFile] : [])
        }
    }

    private func handleSelect(_ item: ParametricPickerItem) {
        if let id = item.presetID, let preset = presets.first(where: { $0.id == id }) {
            onPresetSelected(preset)
        } else if item == .flat {
            onFlatSelected()
        } else if item == .importFile {
            onImport?()
        } else if item == .exportFile {
            onExport?()
        }
    }

    var body: some View {
        GroupedDropdownMenu(
            sections: sections,
            itemsForSection: { items(for: $0) },
            sectionTitle: { $0.rawValue },
            selectedItem: selectedItem,
            maxHeight: 320,
            width: 100,
            popoverWidth: 170,
            onSelect: handleSelect
        ) { selected in
            Text(selected?.name ?? "Custom")
        } itemContent: { item, isSelected in
            ParametricPresetItemView(item: item, isSelected: isSelected, onDelete: onDeletePreset)
        }
    }
}

// MARK: - Item (with hover-revealed delete for user presets)

private struct ParametricPresetItemView: View {
    let item: ParametricPickerItem
    let isSelected: Bool
    let onDelete: (UUID) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(item.name)
                .lineLimit(1)
            Spacer(minLength: DesignTokens.Spacing.xs)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            if let presetID = item.presetID {
                Button {
                    onDelete(presetID)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isHovered ? DesignTokens.Colors.interactiveHover : .clear)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete preset \(item.name)")
                .help("Delete preset")
            }
        }
        .whenHovered { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
    }
}
