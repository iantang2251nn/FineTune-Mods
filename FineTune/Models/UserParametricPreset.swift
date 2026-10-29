import Foundation

/// A user-created parametric EQ preset — a named device curve that can be applied to any output.
/// Kept separate from graphic `UserEQPreset`s. Applying a preset copies its curve to the device,
/// so deleting the preset later leaves the device curve intact.
struct UserParametricPreset: Codable, Equatable, Identifiable {
    /// Stable unique identifier for this preset.
    let id: UUID

    /// User-provided display name.
    var name: String

    /// The curve. `isEnabled` is ignored for presets — it's per-device state.
    var settings: ParametricEQSettings

    /// When the preset was created (for display ordering).
    let createdAt: Date

    init(id: UUID = UUID(), name: String, settings: ParametricEQSettings, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.settings = settings
        self.createdAt = createdAt
    }
}
