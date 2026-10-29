// FineTune/Audio/EQ/ParametricEQFile.swift
import Foundation

/// EqualizerAPO / REW filter-list import and export for the device parametric EQ.
nonisolated enum ParametricEQFile {

    struct ImportResult: Equatable {
        /// The imported curve (validated). The caller copies bands and output gain onto the
        /// device and keeps the device's own on/off state.
        var settings: ParametricEQSettings
        var importedCount: Int
        /// Extra shelves and peaks beyond the eight peak bands.
        var droppedCount: Int
        /// Filters (and the preamp) with a value outside the band's range.
        var clampedCount: Int

        /// Status line shown in the panel after an import.
        var summary: String {
            var parts = ["Imported \(importedCount) filter\(importedCount == 1 ? "" : "s")"]
            if droppedCount > 0 { parts.append("dropped \(droppedCount)") }
            if clampedCount > 0 { parts.append("clamped \(clampedCount)") }
            return parts.joined(separator: ", ")
        }
    }

    /// Maps a filter list onto the fixed layout (band 1 low shelf, 2–9 peaks, 10 high shelf).
    ///
    /// - A file with exactly 10 filters ordered LS, 8 × PK, HS (FineTune's own export) maps by
    ///   position, including `OFF` bands.
    /// - Any other file starts flat and uses `ON` filters only: the low and high shelf with the
    ///   largest absolute gain go to bands 1 and 10; the 8 peaks with the largest absolute gain
    ///   go to bands 2–9 in file order. Bands without a filter keep their defaults at 0 dB.
    /// - `Preamp:` becomes the output gain.
    ///
    /// Returns nil when the file has no usable filters.
    static func importSettings(from text: String) -> ImportResult? {
        let list = AutoEQParser.parseFilterList(text: text)
        let bandCount = ParametricEQSettings.bandCount
        var mapped: [(index: Int, filter: AutoEQFilter, isOn: Bool)] = []
        var droppedCount = 0

        let isFineTuneLayout = list.filters.count == bandCount
            && list.filters.indices.allSatisfy { list.filters[$0].filter.type == ParametricEQSettings.type(ofBand: $0) }

        if isFineTuneLayout {
            mapped = list.filters.indices.map { ($0, list.filters[$0].filter, list.filters[$0].isOn) }
        } else {
            let enabled = list.filters.filter(\.isOn).map(\.filter)
            let lowShelves = enabled.filter { $0.type == .lowShelf }
            let highShelves = enabled.filter { $0.type == .highShelf }
            if let low = strongest(lowShelves) {
                mapped.append((0, low, true))
            }
            if let high = strongest(highShelves) {
                mapped.append((bandCount - 1, high, true))
            }
            droppedCount += max(0, lowShelves.count - 1) + max(0, highShelves.count - 1)

            // The 8 strongest peaks, kept in file order (ties go to the earlier filter).
            let peaks = enabled.filter { $0.type == .peaking }
            let peakSlots = bandCount - 2
            let keptOffsets = peaks.indices
                .sorted { abs(peaks[$0].gainDB) != abs(peaks[$1].gainDB) ? abs(peaks[$0].gainDB) > abs(peaks[$1].gainDB) : $0 < $1 }
                .prefix(peakSlots)
                .sorted()
            droppedCount += peaks.count - keptOffsets.count
            for (slot, offset) in keptOffsets.enumerated() {
                mapped.append((1 + slot, peaks[offset], true))
            }
        }

        guard !mapped.isEmpty else { return nil }

        var settings = ParametricEQSettings.flat
        var clampedCount = 0
        for entry in mapped {
            let band = ParametricBand(
                frequency: entry.filter.frequency,
                gainDB: entry.filter.gainDB,
                q: entry.filter.q,
                isEnabled: entry.isOn
            )
            if !isInRange(band, index: entry.index) { clampedCount += 1 }
            settings.bands[entry.index] = band
        }
        settings.outputGainDB = list.preampDB
        if !ParametricEQSettings.outputGainRange.contains(list.preampDB) { clampedCount += 1 }

        return ImportResult(
            settings: settings.validated(),
            importedCount: mapped.count,
            droppedCount: droppedCount,
            clampedCount: clampedCount
        )
    }

    /// EqualizerAPO text for the curve: the preamp, then all 10 bands in band order
    /// (band 1 `LSC`, bands 2–9 `PK`, band 10 `HSC`). Disabled bands are written `OFF`, which
    /// EqualizerAPO ignores; 0 dB bands are included (they are identity). Values are written at
    /// storage resolution, so `importSettings` reads back the identical curve.
    static func export(_ settings: ParametricEQSettings) -> String {
        let curve = settings.validated()
        var lines = [String(format: "Preamp: %.1f dB", curve.outputGainDB)]
        for (index, band) in curve.bands.enumerated() {
            let type: String
            switch ParametricEQSettings.type(ofBand: index) {
            case .lowShelf: type = "LSC"
            case .peaking: type = "PK"
            case .highShelf: type = "HSC"
            }
            let values = String(format: "Fc %.1f Hz Gain %.1f dB Q %.2f", band.frequency, band.gainDB, band.q)
            lines.append("Filter \(index + 1): \(band.isEnabled ? "ON" : "OFF") \(type) \(values)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The filter with the largest absolute gain (the earlier one on ties).
    private static func strongest(_ filters: [AutoEQFilter]) -> AutoEQFilter? {
        filters.reduce(nil) { best, filter in
            guard let best else { return filter }
            return abs(filter.gainDB) > abs(best.gainDB) ? filter : best
        }
    }

    private static func isInRange(_ band: ParametricBand, index: Int) -> Bool {
        ParametricEQSettings.frequencyRange.contains(band.frequency)
            && ParametricEQSettings.gainRange.contains(band.gainDB)
            && ParametricEQSettings.qRange(ofBand: index).contains(band.q)
    }
}
