import Foundation
import ScanTailorContracts

/// Publication margin specification supporting asymmetric book margins (top, bottom, left, right,
/// inner/gutter, and outer) expressed in multiple units (inches `in`, points `pt`, millimeters `mm`, or pixels `px`).
public struct PublicationMargins: Sendable, Equatable, Codable {
    /// Supported unit of measurement for margins.
    public enum MarginUnit: String, Sendable, Equatable, Codable, CaseIterable {
        case inches = "in"
        case points = "pt"
        case millimeters = "mm"
        case pixels = "px"

        /// Converts a scalar value in this unit to pixels at the specified DPI.
        public func toPixels(_ value: Double, dpi: Int) -> Int {
            let px: Double
            switch self {
            case .inches:
                px = value * Double(dpi)
            case .points:
                px = (value / 72.0) * Double(dpi)
            case .millimeters:
                px = (value / 25.4) * Double(dpi)
            case .pixels:
                // Pixels are assumed to be defined at 600 DPI baseline if not specified otherwise
                px = value * (Double(dpi) / 600.0)
            }
            return max(0, Int(px.rounded()))
        }
    }

    /// Single margin dimension value with associated unit.
    public struct Dimension: Sendable, Equatable, Codable {
        public var value: Double
        public var unit: MarginUnit

        public init(value: Double, unit: MarginUnit = .inches) {
            self.value = max(0.0, value)
            self.unit = unit
        }

        public func toPixels(atDPI dpi: Int) -> Int {
            unit.toPixels(value, dpi: dpi)
        }

        /// Parses a string representation like `"0.25in"`, `"150px"`, `"18pt"`, `"12.7mm"`, or `"0.5"`.
        public static func parse(_ string: String) -> Dimension? {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { return nil }

            // Check known unit suffixes
            for unit in MarginUnit.allCases {
                let suffix = unit.rawValue
                if trimmed.hasSuffix(suffix) {
                    let numStr = trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
                    guard let val = Double(numStr), val >= 0 else { return nil }
                    return Dimension(value: val, unit: unit)
                }
            }

            // Also check alternate spelling aliases
            if trimmed.hasSuffix("inch") || trimmed.hasSuffix("inches") {
                let suffixLen = trimmed.hasSuffix("inches") ? 6 : 4
                let numStr = trimmed.dropLast(suffixLen).trimmingCharacters(in: .whitespaces)
                guard let val = Double(numStr), val >= 0 else { return nil }
                return Dimension(value: val, unit: .inches)
            }
            if trimmed.hasSuffix("pts") || trimmed.hasSuffix("point") || trimmed.hasSuffix("points") {
                let numStr = trimmed.filter { $0.isNumber || $0 == "." || $0 == "-" }
                guard let val = Double(numStr), val >= 0 else { return nil }
                return Dimension(value: val, unit: .points)
            }
            if trimmed.hasSuffix("mm") || trimmed.hasSuffix("millimeter") || trimmed.hasSuffix("millimeters") {
                let numStr = trimmed.filter { $0.isNumber || $0 == "." || $0 == "-" }
                guard let val = Double(numStr), val >= 0 else { return nil }
                return Dimension(value: val, unit: .millimeters)
            }
            if trimmed.hasSuffix("px") || trimmed.hasSuffix("pixel") || trimmed.hasSuffix("pixels") {
                let numStr = trimmed.filter { $0.isNumber || $0 == "." || $0 == "-" }
                guard let val = Double(numStr), val >= 0 else { return nil }
                return Dimension(value: val, unit: .pixels)
            }

            // If bare number, default to inches
            if let val = Double(trimmed), val >= 0 {
                return Dimension(value: val, unit: .inches)
            }

            return nil
        }
    }

    /// Top margin above the detected text block.
    public var top: Dimension
    /// Bottom margin below the detected text block.
    public var bottom: Dimension
    /// Left margin for single or non-book pages (or outer margin on Verso if inner/outer not specified).
    public var left: Dimension
    /// Right margin for single or non-book pages (or outer margin on Recto if inner/outer not specified).
    public var right: Dimension
    /// Optional inner (gutter/binding) margin. When specified, overrides inner edge (right on Verso, left on Recto).
    public var inner: Dimension?
    /// Optional outer margin. When specified, overrides outer edge (left on Verso, right on Recto).
    public var outer: Dimension?

    /// Default publication margins per Section 6.4 of the White Paper:
    /// - Top & Bottom: 0.25″ (150 px at 600 DPI)
    /// - Left & Right: 0.50″ (300 px at 600 DPI)
    public static let publicationDefault = PublicationMargins(
        top: Dimension(value: 0.25, unit: .inches),
        bottom: Dimension(value: 0.25, unit: .inches),
        left: Dimension(value: 0.50, unit: .inches),
        right: Dimension(value: 0.50, unit: .inches)
    )

    public init(
        top: Dimension = Dimension(value: 0.25, unit: .inches),
        bottom: Dimension = Dimension(value: 0.25, unit: .inches),
        left: Dimension = Dimension(value: 0.50, unit: .inches),
        right: Dimension = Dimension(value: 0.50, unit: .inches),
        inner: Dimension? = nil,
        outer: Dimension? = nil
    ) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
        self.inner = inner
        self.outer = outer
    }

    /// Computes effective left and right margin in pixels at `dpi` for a given book page side.
    ///
    /// For `.verso` (left-hand page):
    /// - Inner (binding gutter) is on the right.
    /// - Outer is on the left.
    ///
    /// For `.recto` (right-hand page):
    /// - Inner (binding gutter) is on the left.
    /// - Outer is on the right.
    public func horizontalMargins(for side: MarginHarmonizer.PageSide, dpi: Int) -> (left: Int, right: Int) {
        switch side {
        case .verso:
            let l = (outer ?? left).toPixels(atDPI: dpi)
            let r = (inner ?? right).toPixels(atDPI: dpi)
            return (l, r)
        case .recto:
            let l = (inner ?? left).toPixels(atDPI: dpi)
            let r = (outer ?? right).toPixels(atDPI: dpi)
            return (l, r)
        case .single:
            let l = left.toPixels(atDPI: dpi)
            let r = right.toPixels(atDPI: dpi)
            return (l, r)
        }
    }

    /// Computes top and bottom margin in pixels at `dpi`.
    public func verticalMargins(dpi: Int) -> (top: Int, bottom: Int) {
        (top.toPixels(atDPI: dpi), bottom.toPixels(atDPI: dpi))
    }

    /// Parses a margin specification string such as:
    /// - `"top=0.25in,bottom=0.25in,left=0.5in,right=0.5in"`
    /// - `"0.25in,0.5in"` (shorthand: top/bottom, left/right)
    /// - `"0.25in,0.5in,0.25in,0.5in"` (shorthand: top, right, bottom, left)
    /// - `"inner=0.75in,outer=0.5in,top=0.25in,bottom=0.25in"`
    /// - `"0.5in"` (all margins)
    public static func parse(_ spec: String) -> PublicationMargins? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Check if key=value pairs exist
        if trimmed.contains("=") {
            let pairs = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var top: Dimension?
            var bottom: Dimension?
            var left: Dimension?
            var right: Dimension?
            var inner: Dimension?
            var outer: Dimension?

            for pair in pairs {
                let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2, let dim = Dimension.parse(kv[1]) else { return nil }
                let key = kv[0].lowercased()
                switch key {
                case "t", "top":
                    top = dim
                case "b", "bottom":
                    bottom = dim
                case "l", "left":
                    left = dim
                case "r", "right":
                    right = dim
                case "inner", "gutter", "inside":
                    inner = dim
                case "outer", "outside":
                    outer = dim
                case "v", "vert", "vertical":
                    top = dim
                    bottom = dim
                case "h", "horiz", "horizontal":
                    left = dim
                    right = dim
                case "all":
                    top = dim
                    bottom = dim
                    left = dim
                    right = dim
                default:
                    return nil
                }
            }

            let def = PublicationMargins.publicationDefault
            return PublicationMargins(
                top: top ?? def.top,
                bottom: bottom ?? def.bottom,
                left: left ?? def.left,
                right: right ?? def.right,
                inner: inner,
                outer: outer
            )
        }

        // Positional shorthand comma-separated (CSS style: 1, 2, or 4 components)
        let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        switch parts.count {
        case 1:
            // all edges
            guard let all = Dimension.parse(parts[0]) else { return nil }
            return PublicationMargins(top: all, bottom: all, left: all, right: all)
        case 2:
            // top/bottom, left/right
            guard let tb = Dimension.parse(parts[0]), let lr = Dimension.parse(parts[1]) else { return nil }
            return PublicationMargins(top: tb, bottom: tb, left: lr, right: lr)
        case 4:
            // top, right, bottom, left
            guard let t = Dimension.parse(parts[0]),
                  let r = Dimension.parse(parts[1]),
                  let b = Dimension.parse(parts[2]),
                  let l = Dimension.parse(parts[3]) else { return nil }
            return PublicationMargins(top: t, bottom: b, left: l, right: r)
        default:
            return nil
        }
    }
}
