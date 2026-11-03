import Foundation
import ScanTailorContracts

/// Physical 2D dimension specification (`width x height`) supporting imperial, metric, typographic point,
/// and 600-DPI baseline pixel units as well as named bibliographic and ISO/ANSI book presets.
///
/// Used by `--page-size`, `--content-box-size`, `MarginHarmonizer.Configuration`, and `BookProcessingManifest`
/// to deterministically control output page trim dimensions and canonical text block frames.
public struct PhysicalSizeSpec: Sendable, Equatable, Codable, CustomStringConvertible {
    /// Supported linear unit of measurement for 2D physical size specifications.
    public enum Unit: String, Sendable, Equatable, Codable, CaseIterable {
        case inches = "in"
        case millimeters = "mm"
        case centimeters = "cm"
        case points = "pt"
        case pixels = "px"

        /// Converts a scalar length in this unit to physical inches.
        /// - Parameter value: Scalar length in this unit.
        /// - Returns: Equivalent length in physical inches.
        public func toInches(_ value: Double) -> Double {
            switch self {
            case .inches:
                return value
            case .millimeters:
                return value / 25.4
            case .centimeters:
                return value / 2.54
            case .points:
                return value / 72.0
            case .pixels:
                // Matches `PublicationMargins.MarginUnit.pixels` 600-DPI baseline convention.
                return value / 600.0
            }
        }
    }

    /// Standard bibliographic book trim sizes and ISO/ANSI paper presets.
    public enum Preset: String, Sendable, Equatable, Codable, CaseIterable {
        /// Standard US Octavo (`6.0 x 9.0 in` / `152.4 x 228.6 mm`).
        case octavo = "octavo"
        /// US Trade Paperback / Digest (`5.5 x 8.5 in` / `139.7 x 215.9 mm`).
        case tradePaperback = "trade-paperback"
        /// Academic Royal Octavo (`156 x 234 mm` / `6.14 x 9.21 in`).
        case royalOctavo = "royal-octavo"
        /// Crown Octavo (`5.0 x 7.5 in` / `127.0 x 190.5 mm`).
        case crownOctavo = "crown-octavo"
        /// Demy Octavo (`138 x 216 mm` / `5.43 x 8.50 in`).
        case demyOctavo = "demy-octavo"
        /// Duodecimo / 12mo (`5.0 x 7.375 in`).
        case duodecimo = "duodecimo"
        /// Mass-Market Paperback / Sexto (`4.25 x 6.875 in`).
        case massMarket = "mass-market"
        /// Quarto / 4to (`9.0 x 12.0 in`).
        case quarto = "quarto"
        /// Folio (`12.0 x 15.0 in`).
        case folio = "folio"
        /// ISO A4 (`210 x 297 mm` / `8.27 x 11.69 in`).
        case a4 = "a4"
        /// ISO A5 (`148 x 210 mm` / `5.83 x 8.27 in`).
        case a5 = "a5"
        /// ISO A6 (`105 x 148 mm` / `4.13 x 5.83 in`).
        case a6 = "a6"
        /// ISO B5 (`176 x 250 mm` / `6.93 x 9.84 in`).
        case b5 = "b5"
        /// JIS B5 (`182 x 257 mm` / `7.17 x 10.12 in`).
        case jisB5 = "jis-b5"
        /// ANSI Letter (`8.5 x 11.0 in`).
        case letter = "letter"
        /// ANSI Legal (`8.5 x 14.0 in`).
        case legal = "legal"
        /// ANSI Executive (`7.25 x 10.5 in`).
        case executive = "executive"

        /// Canonical dimensions and native unit for this preset.
        public var specification: PhysicalSizeSpec {
            switch self {
            case .octavo:
                return PhysicalSizeSpec(width: 6.0, height: 9.0, unit: .inches, preset: self)
            case .tradePaperback:
                return PhysicalSizeSpec(width: 5.5, height: 8.5, unit: .inches, preset: self)
            case .royalOctavo:
                return PhysicalSizeSpec(width: 156.0, height: 234.0, unit: .millimeters, preset: self)
            case .crownOctavo:
                return PhysicalSizeSpec(width: 5.0, height: 7.5, unit: .inches, preset: self)
            case .demyOctavo:
                return PhysicalSizeSpec(width: 138.0, height: 216.0, unit: .millimeters, preset: self)
            case .duodecimo:
                return PhysicalSizeSpec(width: 5.0, height: 7.375, unit: .inches, preset: self)
            case .massMarket:
                return PhysicalSizeSpec(width: 4.25, height: 6.875, unit: .inches, preset: self)
            case .quarto:
                return PhysicalSizeSpec(width: 9.0, height: 12.0, unit: .inches, preset: self)
            case .folio:
                return PhysicalSizeSpec(width: 12.0, height: 15.0, unit: .inches, preset: self)
            case .a4:
                return PhysicalSizeSpec(width: 210.0, height: 297.0, unit: .millimeters, preset: self)
            case .a5:
                return PhysicalSizeSpec(width: 148.0, height: 210.0, unit: .millimeters, preset: self)
            case .a6:
                return PhysicalSizeSpec(width: 105.0, height: 148.0, unit: .millimeters, preset: self)
            case .b5:
                return PhysicalSizeSpec(width: 176.0, height: 250.0, unit: .millimeters, preset: self)
            case .jisB5:
                return PhysicalSizeSpec(width: 182.0, height: 257.0, unit: .millimeters, preset: self)
            case .letter:
                return PhysicalSizeSpec(width: 8.5, height: 11.0, unit: .inches, preset: self)
            case .legal:
                return PhysicalSizeSpec(width: 8.5, height: 14.0, unit: .inches, preset: self)
            case .executive:
                return PhysicalSizeSpec(width: 7.25, height: 10.5, unit: .inches, preset: self)
            }
        }
    }

    /// Positive width value in `unit`.
    public var width: Double

    /// Positive height value in `unit`.
    public var height: Double

    /// Measurement unit for `width` and `height`.
    public var unit: Unit

    /// Optional named preset when constructed from a standard book or paper preset.
    public var preset: Preset?

    /// Creates a physical size specification.
    /// - Parameters:
    ///   - width: Positive width in `unit`.
    ///   - height: Positive height in `unit`.
    ///   - unit: Linear measurement unit (default: `.inches`).
    ///   - preset: Optional named preset tag.
    public init(
        width: Double,
        height: Double,
        unit: Unit = .inches,
        preset: Preset? = nil
    ) {
        self.width = max(1e-4, width)
        self.height = max(1e-4, height)
        self.unit = unit
        self.preset = preset
    }

    /// Creates a physical size specification from a standard named preset.
    /// - Parameter preset: Standard bibliographic or paper preset.
    /// - Returns: The corresponding `PhysicalSizeSpec`.
    public static func preset(_ preset: Preset) -> PhysicalSizeSpec {
        preset.specification
    }

    /// Equivalent physical dimensions in inches (`width`, `height`).
    public var sizeInInches: Size2D {
        Size2D(
            width: unit.toInches(width),
            height: unit.toInches(height)
        )
    }

    /// Equivalent physical dimensions in 72-DPI PDF points (`width`, `height`).
    public var sizeInPoints: Size2D {
        if unit == .points {
            return Size2D(width: width, height: height)
        }
        let inches = sizeInInches
        return Size2D(width: inches.width * 72.0, height: inches.height * 72.0)
    }

    /// Equivalent physical dimensions in millimeters (`width`, `height`).
    public var sizeInMillimeters: Size2D {
        switch unit {
        case .millimeters:
            return Size2D(width: width, height: height)
        case .centimeters:
            return Size2D(width: width * 10.0, height: height * 10.0)
        case .inches, .points, .pixels:
            let inches = sizeInInches
            return Size2D(width: inches.width * 25.4, height: inches.height * 25.4)
        }
    }

    /// Converts this physical specification into integer pixel dimensions at `dpi`.
    /// - Parameter dpi: Target raster resolution in dots per inch.
    /// - Returns: Pixel dimensions (`>= 1 x 1`).
    public func sizeInPixels(atDPI dpi: Int) -> Size2I {
        let safeDPI = Double(max(1, dpi))
        let inches = sizeInInches
        return Size2I(
            width: max(1, Int((inches.width * safeDPI).rounded())),
            height: max(1, Int((inches.height * safeDPI).rounded()))
        )
    }

    /// Human-readable summary suitable for CLI telemetry logs.
    public var description: String {
        let inches = sizeInInches
        let inchText = String(format: "%.2f\" x %.2f\"", inches.width, inches.height)
        if let preset {
            return "\(preset.rawValue) (\(inchText))"
        }
        if unit == .inches {
            return inchText
        }
        return String(format: "%g x %g %@ (%@)", width, height, unit.rawValue, inchText)
    }

    // MARK: - String Parsing

    /// Parses a named preset (e.g. `"octavo"`, `"trade-paperback"`, `"a5"`, `"letter"`) or an explicit
    /// `<w>x<h>` dimension string (e.g. `"6x9in"`, `"5.5x8.5in"`, `"148x210mm"`, `"15.2x22.9cm"`,
    /// `"432x648pt"`, `"2400x3600px"`, or `"6x9"`).
    ///
    /// When only one side of `<w>x<h>` specifies a unit (such as `"6x9in"` or `"148x210mm"`), both
    /// dimensions inherit that unit. Bare numbers without any unit default to `.inches`.
    /// - Parameter spec: Raw CLI or manifest string specification.
    /// - Returns: Parsed `PhysicalSizeSpec`, or `nil` if invalid or non-positive.
    public static func parse(_ spec: String) -> PhysicalSizeSpec? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. Check standard named book and paper presets first (before splitting on 'x',
        //    since preset names like "executive" and "sexto" contain the letter 'x').
        if let matchedPreset = parsePresetAlias(trimmed) {
            return matchedPreset.specification
        }

        // 2. Split `<lhs> x <rhs>` (supporting ASCII 'x'/'X' and Unicode multiplication '×').
        guard let (lhsRaw, rhsRaw) = splitDimensionPair(trimmed),
              let lhs = parseScalarToken(lhsRaw),
              let rhs = parseScalarToken(rhsRaw)
        else {
            return nil
        }

        switch (lhs.explicitUnit, rhs.explicitUnit) {
        case (nil, nil):
            return PhysicalSizeSpec(width: lhs.value, height: rhs.value, unit: .inches)
        case (let u?, nil):
            return PhysicalSizeSpec(width: lhs.value, height: rhs.value, unit: u)
        case (nil, let u?):
            return PhysicalSizeSpec(width: lhs.value, height: rhs.value, unit: u)
        case (let u1?, let u2?) where u1 == u2:
            return PhysicalSizeSpec(width: lhs.value, height: rhs.value, unit: u1)
        case (let u1?, let u2?):
            return PhysicalSizeSpec(
                width: u1.toInches(lhs.value),
                height: u2.toInches(rhs.value),
                unit: .inches
            )
        }
    }

    private static func parsePresetAlias(_ raw: String) -> Preset? {
        let normalized = raw
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "-")

        switch normalized {
        case "octavo", "8vo", "standard-octavo":
            return .octavo
        case "trade-paperback", "trade", "tradepaperback", "digest", "half-letter", "statement", "us-trade":
            return .tradePaperback
        case "royal-octavo", "royal-8vo", "royaloctavo":
            return .royalOctavo
        case "crown-octavo", "crown-8vo", "crownoctavo":
            return .crownOctavo
        case "demy-octavo", "demy-8vo", "demyoctavo":
            return .demyOctavo
        case "duodecimo", "12mo", "twelvemo":
            return .duodecimo
        case "mass-market", "massmarket", "pocket", "sexto":
            return .massMarket
        case "quarto", "4to":
            return .quarto
        case "folio":
            return .folio
        case "a4", "iso-a4", "journal-a4":
            return .a4
        case "a5", "iso-a5":
            return .a5
        case "a6", "iso-a6":
            return .a6
        case "b5", "iso-b5":
            return .b5
        case "jis-b5", "jisb5":
            return .jisB5
        case "letter", "us-letter", "ansi-a":
            return .letter
        case "legal", "us-legal":
            return .legal
        case "executive":
            return .executive
        default:
            return nil
        }
    }

    private static func splitDimensionPair(_ input: String) -> (String, String)? {
        if input.contains("×") {
            let parts = input.split(separator: "×", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }

        let chars = Array(input)
        var separatorIndices: [Int] = []
        for idx in chars.indices {
            let ch = chars[idx]
            if ch == "x" || ch == "X" {
                let prevLower: Character? = idx > 0 ? Character(chars[idx - 1].lowercased()) : nil
                // Ignore 'x' inside unit tokens "px", "pixel", or "pixels".
                if prevLower == "p" || prevLower == "i" {
                    continue
                }
                separatorIndices.append(idx)
            }
        }

        guard separatorIndices.count == 1 else { return nil }
        let sep = separatorIndices[0]
        guard sep > 0 && sep + 1 < chars.count else { return nil }
        let lhs = String(chars[0..<sep])
        let rhs = String(chars[(sep + 1)..<chars.count])
        return (lhs, rhs)
    }

    private static func parseScalarToken(_ rawToken: String) -> (value: Double, explicitUnit: Unit?)? {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }

        let chars = Array(token)
        var numEnd = 0
        while numEnd < chars.count {
            let ch = chars[numEnd]
            if ch.isNumber || ch == "." || (numEnd == 0 && (ch == "+" || ch == "-")) {
                numEnd += 1
            } else {
                break
            }
        }

        guard numEnd > 0 else { return nil }
        let numStr = String(chars[0..<numEnd])
        let unitStr = String(chars[numEnd..<chars.count])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard let value = Double(numStr), value.isFinite, value > 0.0 else {
            return nil
        }

        if unitStr.isEmpty {
            return (value, nil)
        }

        let unit: Unit
        switch unitStr {
        case "in", "inch", "inches", "\"":
            unit = .inches
        case "mm", "millimeter", "millimeters":
            unit = .millimeters
        case "cm", "centimeter", "centimeters":
            unit = .centimeters
        case "pt", "pts", "point", "points":
            unit = .points
        case "px", "pixel", "pixels":
            unit = .pixels
        default:
            return nil
        }

        return (value, unit)
    }

    // MARK: - Codable (Supports Both Keyed JSON Object & Compact String Shorthand)

    private enum CodingKeys: String, CodingKey {
        case width
        case height
        case unit
        case preset
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let rawString = try? single.decode(String.self)
        {
            guard let parsed = Self.parse(rawString) else {
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "Invalid PhysicalSizeSpec string '\(rawString)'."
                )
            }
            self = parsed
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let width = try container.decode(Double.self, forKey: .width)
        let height = try container.decode(Double.self, forKey: .height)
        guard width.isFinite, height.isFinite, width > 0.0, height > 0.0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .width,
                in: container,
                debugDescription: "PhysicalSizeSpec width and height must be finite positive numbers."
            )
        }
        let unit = try container.decodeIfPresent(Unit.self, forKey: .unit) ?? .inches
        let preset = try container.decodeIfPresent(Preset.self, forKey: .preset)
        self.init(width: width, height: height, unit: unit, preset: preset)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(unit, forKey: .unit)
        try container.encodeIfPresent(preset, forKey: .preset)
    }
}
