import Foundation
import ScanTailorContracts
import ScanTailorCore

// MARK: - Lengths

/// A signed length with a mandatory unit, as written in an adjustments file (`"-2mm"`, `"+0.1in"`, `"52%"`).
///
/// Pixels (`px`) are pixels of the 600 DPI processing raster. Percentages are only meaningful where a
/// field says so (the position of a spread split).
public struct AdjustmentLength: Sendable, Equatable, Codable, CustomStringConvertible {
    /// Unit of an ``AdjustmentLength``.
    public enum Unit: String, Sendable, Equatable, Codable, CaseIterable {
        case inches = "in"
        case millimeters = "mm"
        case centimeters = "cm"
        case points = "pt"
        case pixels = "px"
        case percent = "%"
    }

    public var value: Double
    public var unit: Unit

    public init(value: Double, unit: Unit) {
        self.value = value
        self.unit = unit
    }

    /// Parses `"-2mm"`, `"+0.1in"`, `"36pt"`, `"120px"`, or (when `allowPercent`) `"52%"`. A unit is required.
    public static func parse(_ text: String, allowPercent: Bool = false) -> AdjustmentLength? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        // Longest suffixes first so that "in" is not read out of "min".
        for unit in [Unit.millimeters, .centimeters, .inches, .points, .pixels, .percent] {
            guard trimmed.hasSuffix(unit.rawValue) else { continue }
            if unit == .percent && !allowPercent { return nil }
            var number = trimmed.dropLast(unit.rawValue.count).trimmingCharacters(in: .whitespaces)
            if number.hasPrefix("+") { number.removeFirst() }
            guard let value = Double(number), value.isFinite else { return nil }
            return AdjustmentLength(value: value, unit: unit)
        }
        return nil
    }

    /// The length in pixels at `dpi`. Percentages are taken of `extent` (a width in pixels).
    public func pixels(atDPI dpi: Int, extent: Int = 0) -> Int {
        let d = Double(dpi)
        let px: Double
        switch unit {
        case .inches: px = value * d
        case .millimeters: px = value / 25.4 * d
        case .centimeters: px = value / 2.54 * d
        case .points: px = value / 72.0 * d
        case .pixels: px = value * d / 600.0
        case .percent: px = value / 100.0 * Double(extent)
        }
        return Int(px.rounded())
    }

    public var description: String {
        let number = value == value.rounded() ? String(Int(value)) : String(value)
        return number + unit.rawValue
    }
}

// MARK: - References

/// Names one output page or one scan (half) in an adjustments file or an outlier list.
///
/// - `45` is output page 45 of the run being looked at (1-based, as in `inspect --pages`). Splitting a scan
///   differently, or dropping a blank page, renumbers the output pages after it.
/// - `s12` is scan 12 of the source PDF (1-based, counted from the start of the PDF even with `--page-range`):
///   the single page of a scan, or both halves of a split scan.
/// - `s12L` / `s12R` is the left / right half of a split scan.
///
/// Scan references stay valid when the output numbering shifts, so prefer them.
public enum PageReference: Sendable, Hashable, CustomStringConvertible, Comparable {
    /// Which part of a scan a reference names.
    public enum Half: String, Sendable, Hashable, Comparable {
        case whole = ""
        case left = "L"
        case right = "R"

        public static func < (lhs: Half, rhs: Half) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    case outputPage(Int)
    case scan(Int, Half)

    /// Parses `"45"`, `"s12"`, `"s12L"`, or `"s12r"`.
    public init?(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("s") {
            var digits = t.dropFirst()
            var half = Half.whole
            if digits.hasSuffix("l") { half = .left; digits = digits.dropLast() }
            else if digits.hasSuffix("r") { half = .right; digits = digits.dropLast() }
            guard let n = Int(digits), n >= 1, digits.allSatisfy(\.isNumber) else { return nil }
            self = .scan(n, half)
        } else {
            guard let n = Int(t), n >= 1, t.allSatisfy(\.isNumber) else { return nil }
            self = .outputPage(n)
        }
    }

    public var description: String {
        switch self {
        case .outputPage(let n): return String(n)
        case .scan(let n, let half): return "s\(n)\(half.rawValue)"
        }
    }

    public static func < (lhs: PageReference, rhs: PageReference) -> Bool {
        switch (lhs, rhs) {
        case (.outputPage(let a), .outputPage(let b)): return a < b
        case (.outputPage, .scan): return true
        case (.scan, .outputPage): return false
        case (.scan(let a, let h1), .scan(let b, let h2)): return a != b ? a < b : h1 < h2
        }
    }
}

// MARK: - Adjustments

/// Edge displacements of a content box. Positive moves an edge right or down.
public struct EdgeLengths: Sendable, Equatable {
    public var top: AdjustmentLength?
    public var left: AdjustmentLength?
    public var bottom: AdjustmentLength?
    public var right: AdjustmentLength?

    public init(top: AdjustmentLength? = nil, left: AdjustmentLength? = nil, bottom: AdjustmentLength? = nil, right: AdjustmentLength? = nil) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

/// An absolute content box as `left, top, right, bottom` lengths measured from the page's top-left corner.
public struct BoxLengths: Sendable, Equatable {
    public var left: AdjustmentLength
    public var top: AdjustmentLength
    public var right: AdjustmentLength
    public var bottom: AdjustmentLength
}

/// Edits to one scan (one page of the source PDF) before it is split into pages.
public struct ScanAdjustment: Sendable, Equatable {
    /// Forces a single page (`.singlePage`), a two-page spread (`.twoPageSpread`), or automatic detection.
    public var split: PageSplitMode?
    /// Where a spread is cut, measured from the scan's left edge (`"52%"` or an absolute length). Implies a spread.
    public var splitX: AdjustmentLength?
    public var disableRectification: Bool?
    public var disableDeskMask: Bool?

    public init(split: PageSplitMode? = nil, splitX: AdjustmentLength? = nil, disableRectification: Bool? = nil, disableDeskMask: Bool? = nil) {
        self.split = split
        self.splitX = splitX
        self.disableRectification = disableRectification
        self.disableDeskMask = disableDeskMask
    }

    /// `self` overlaid with `later` (later values win).
    public func merged(with later: ScanAdjustment) -> ScanAdjustment {
        ScanAdjustment(
            split: later.split ?? split,
            splitX: later.splitX ?? splitX,
            disableRectification: later.disableRectification ?? disableRectification,
            disableDeskMask: later.disableDeskMask ?? disableDeskMask
        )
    }

    /// Names of the fields that are set, for reports.
    public var fieldNames: [String] {
        var names: [String] = []
        if split != nil { names.append("split") }
        if splitX != nil { names.append("splitX") }
        if disableRectification != nil { names.append("disableRectification") }
        if disableDeskMask != nil { names.append("disableDeskMask") }
        return names
    }
}

/// Edits to one output page.
public struct PageAdjustment: Sendable, Equatable {
    public var skewDegrees: Double?
    public var disableDewarp: Bool?
    /// Absolute content box (replaces the detected one).
    public var contentBoxRect: BoxLengths?
    /// Edge nudges applied to the detected (or absolute) content box.
    public var contentBoxNudge: EdgeLengths?
    /// Moves the content on its page after all automatic placement.
    public var offsetX: AdjustmentLength?
    public var offsetY: AdjustmentLength?
    public var tier: MarginHarmonizer.PlacementTier?
    /// `true` forces a dimensional outlier, `false` forces a canonical page.
    public var outlier: Bool?
    /// PDF page size of an outlier that has its own canvas (same aspect ratio as its canvas).
    public var pageSize: PhysicalSizeSpec?
    public var keep: Bool?
    public var drop: Bool?
    public var runningHeader: RunningHeaderPolicy?
    public var verticalRegistration: VerticalRegistrationPolicy?
    public var borderFallback: BorderFallbackPolicy?

    public init() {}

    /// `self` overlaid with `later` (later values win).
    public func merged(with later: PageAdjustment) -> PageAdjustment {
        var r = self
        r.skewDegrees = later.skewDegrees ?? skewDegrees
        r.disableDewarp = later.disableDewarp ?? disableDewarp
        r.contentBoxRect = later.contentBoxRect ?? contentBoxRect
        if let n = later.contentBoxNudge {
            var base = contentBoxNudge ?? EdgeLengths()
            base.top = n.top ?? base.top
            base.left = n.left ?? base.left
            base.bottom = n.bottom ?? base.bottom
            base.right = n.right ?? base.right
            r.contentBoxNudge = base
        }
        r.offsetX = later.offsetX ?? offsetX
        r.offsetY = later.offsetY ?? offsetY
        r.tier = later.tier ?? tier
        r.outlier = later.outlier ?? outlier
        r.pageSize = later.pageSize ?? pageSize
        r.keep = later.keep ?? keep
        r.drop = later.drop ?? drop
        r.runningHeader = later.runningHeader ?? runningHeader
        r.verticalRegistration = later.verticalRegistration ?? verticalRegistration
        r.borderFallback = later.borderFallback ?? borderFallback
        return r
    }

    /// Names of the fields that are set, for reports.
    public var fieldNames: [String] {
        var names: [String] = []
        if skewDegrees != nil { names.append("skew") }
        if disableDewarp != nil { names.append("disableDewarp") }
        if contentBoxRect != nil { names.append("contentBox.rect") }
        if contentBoxNudge != nil { names.append("contentBox.nudge") }
        if offsetX != nil || offsetY != nil { names.append("offset") }
        if tier != nil { names.append("tier") }
        if outlier != nil { names.append("outlier") }
        if pageSize != nil { names.append("pageSize") }
        if keep != nil { names.append("keep") }
        if drop != nil { names.append("drop") }
        if runningHeader != nil { names.append("runningHeader") }
        if verticalRegistration != nil { names.append("verticalRegistration") }
        if borderFallback != nil { names.append("borderFallback") }
        return names
    }
}

/// What a run did with an adjustments file: which entries took effect and which found nothing to adjust.
public struct AdjustmentReport: Sendable, Equatable, Codable {
    /// An entry that changed at least one page or scan.
    public struct Applied: Sendable, Equatable, Codable {
        public var reference: String
        public var fields: [String]
        public init(reference: String, fields: [String]) {
            self.reference = reference
            self.fields = fields
        }
    }

    /// An entry (or one of its fields) that had no effect, with the reason.
    public struct Ignored: Sendable, Equatable, Codable {
        public var reference: String
        public var reason: String
        public init(reference: String, reason: String) {
            self.reference = reference
            self.reason = reason
        }
    }

    /// Path of the adjustments file, when one was used.
    public var source: String?
    public var applied: [Applied]
    public var ignored: [Ignored]

    public init(source: String? = nil, applied: [Applied] = [], ignored: [Ignored] = []) {
        self.source = source
        self.applied = applied
        self.ignored = ignored
    }

    private enum CodingKeys: String, CodingKey { case source, applied, ignored }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.source = try c.decodeIfPresent(String.self, forKey: .source)
        self.applied = try c.decodeIfPresent([Applied].self, forKey: .applied) ?? []
        self.ignored = try c.decodeIfPresent([Ignored].self, forKey: .ignored) ?? []
    }
}

/// The adjustments an agent or user wrote for a book (`--apply-manifest`).
public struct PageAdjustments: Sendable, Equatable {
    /// Path the adjustments were read from (informational).
    public var source: String?
    /// Command-line arguments equivalent to the file's `book` section, in a fixed order.
    public var bookArguments: [String]
    /// Per-scan edits, keyed by scan reference (`s12`).
    public var scans: [PageReference: ScanAdjustment]
    /// Per-page edits, keyed by output page (`45`) or scan reference (`s12`, `s12L`).
    public var pages: [PageReference: PageAdjustment]

    public init(source: String? = nil, bookArguments: [String] = [], scans: [PageReference: ScanAdjustment] = [:], pages: [PageReference: PageAdjustment] = [:]) {
        self.source = source
        self.bookArguments = bookArguments
        self.scans = scans
        self.pages = pages
    }

    public static let empty = PageAdjustments()

    /// Whether the file adjusts any scan or page.
    public var isEmpty: Bool { scans.isEmpty && pages.isEmpty }
}

/// All the problems found in an adjustments file, reported together.
public struct AdjustmentsError: Error, CustomStringConvertible, Equatable, Sendable {
    public var problems: [String]
    public init(problems: [String]) { self.problems = problems }

    public var description: String {
        "The adjustments file has \(problems.count) problem(s):\n" + problems.map { "  - \($0)" }.joined(separator: "\n")
    }
}

// MARK: - Parsing

extension PageAdjustments {
    /// Command-line flags that may not appear in the `book` section.
    private static let reservedBookKeys: Set<String> = ["apply-manifest", "o", "output", "input", "stop-after", "help", "h"]

    private static let topLevelKeys = ["version", "book", "scans", "pages"]
    private static let scanKeys = ["split", "splitX", "disableRectification", "disableDeskMask"]
    private static let pageKeys = [
        "skew", "disableDewarp", "contentBox", "offset", "tier", "outlier", "pageSize", "keep", "drop",
        "runningHeader", "verticalRegistration", "borderFallback",
    ]
    private static let contentBoxKeys = ["rect", "nudge"]
    private static let edgeKeys = ["top", "left", "bottom", "right"]

    /// Parses and validates an adjustments file. Every problem is collected; nothing is half-applied.
    ///
    /// Keys starting with `_`, and the keys `note` and `comment`, are ignored everywhere so an agent can leave
    /// itself notes. Any other unknown key is an error with a suggestion.
    public static func parse(_ data: Data, source: String? = nil) throws(AdjustmentsError) -> PageAdjustments {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AdjustmentsError(problems: ["not valid JSON: \(error.localizedDescription)"])
        }
        guard let root = json as? [String: Any] else {
            throw AdjustmentsError(problems: ["the top level must be a JSON object with \"book\", \"scans\" and/or \"pages\""])
        }

        var problems: [String] = []
        var result = PageAdjustments(source: source)

        checkKeys(root, allowed: topLevelKeys, path: "", problems: &problems)
        if let version = root["version"] {
            if let n = version as? Int, n == 1 {} else { problems.append("version: only version 1 is supported") }
        }

        if let book = root["book"] {
            if let dict = book as? [String: Any] {
                result.bookArguments = bookArguments(from: dict, problems: &problems)
            } else {
                problems.append("book: must be an object of command-line options, for example {\"margins\": \"0.75in\"}")
            }
        }

        if let scans = root["scans"] {
            if let dict = scans as? [String: Any] {
                for key in dict.keys.sorted() where !isNote(key) {
                    guard let ref = PageReference(key), case .scan(_, .whole) = ref else {
                        problems.append("scans.\(key): scans are named like \"s12\" (scan 12 of the source PDF)")
                        continue
                    }
                    guard let entry = dict[key] as? [String: Any] else {
                        problems.append("scans.\(key): must be an object")
                        continue
                    }
                    if let adj = scanAdjustment(entry, path: "scans.\(key)", problems: &problems) {
                        result.scans[ref] = adj
                    }
                }
            } else {
                problems.append("scans: must be an object keyed by scan, for example {\"s12\": {\"split\": \"single\"}}")
            }
        }

        if let pages = root["pages"] {
            if let dict = pages as? [String: Any] {
                for key in dict.keys.sorted() where !isNote(key) {
                    guard let ref = PageReference(key) else {
                        problems.append("pages.\(key): pages are named by output page (\"45\") or scan (\"s12\", \"s12L\", \"s12R\")")
                        continue
                    }
                    guard let entry = dict[key] as? [String: Any] else {
                        problems.append("pages.\(key): must be an object")
                        continue
                    }
                    if let adj = pageAdjustment(entry, path: "pages.\(key)", problems: &problems) {
                        result.pages[ref] = adj
                    }
                }
            } else {
                problems.append("pages: must be an object keyed by page, for example {\"s45L\": {\"skew\": -0.4}}")
            }
        }

        if !problems.isEmpty { throw AdjustmentsError(problems: problems) }
        return result
    }

    // MARK: Helpers

    private static func isNote(_ key: String) -> Bool {
        key.hasPrefix("_") || key == "note" || key == "comment" || key == "notes"
    }

    private static func checkKeys(_ dict: [String: Any], allowed: [String], path: String, problems: inout [String]) {
        for key in dict.keys.sorted() where !allowed.contains(key) && !isNote(key) {
            var message = "\(path.isEmpty ? "" : path + ".")\(key): unknown key"
            if let near = closest(to: key, in: allowed) { message += " — did you mean \"\(near)\"?" }
            else { message += " (allowed: \(allowed.joined(separator: ", ")))" }
            problems.append(message)
        }
    }

    /// The allowed key closest to `key` (edit distance of at most 2, or a shared prefix), if any.
    static func closest(to key: String, in candidates: [String]) -> String? {
        let lower = key.lowercased()
        var best: (String, Int)? = nil
        for candidate in candidates {
            let c = candidate.lowercased()
            let d = editDistance(lower, c)
            let prefix = c.hasPrefix(lower) || lower.hasPrefix(c)
            let score = prefix ? 0 : d
            if score <= 2, best == nil || score < best!.1 { best = (candidate, score) }
        }
        return best?.0
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// A JSON `true`/`false` (never a number that happens to be 0 or 1).
    private static func boolean(_ value: Any) -> Bool? {
        #if canImport(Darwin)
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        return nil
        #else
        return value as? Bool
        #endif
    }

    /// A JSON number (never a boolean).
    private static func numeric(_ value: Any) -> Double? {
        guard boolean(value) == nil, let n = value as? NSNumber, n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    private static func bool(_ value: Any, path: String, problems: inout [String]) -> Bool? {
        if let b = boolean(value) { return b }
        problems.append("\(path): must be true or false")
        return nil
    }

    private static func number(_ value: Any, path: String, problems: inout [String]) -> Double? {
        if let d = numeric(value) { return d }
        problems.append("\(path): must be a number")
        return nil
    }

    private static func length(_ value: Any, path: String, allowPercent: Bool = false, problems: inout [String]) -> AdjustmentLength? {
        guard let text = value as? String else {
            problems.append("\(path): needs a unit, so write it as a string such as \"-2mm\", \"0.1in\" or \"36pt\" (a bare number has no unit)")
            return nil
        }
        guard let parsed = AdjustmentLength.parse(text, allowPercent: allowPercent) else {
            problems.append("\(path): \"\(text)\" is not a length; use in, mm, cm, pt or px\(allowPercent ? " (or %)" : ""), for example \"-2mm\"")
            return nil
        }
        return parsed
    }

    private static func policy<T: RawRepresentable & CaseIterableLike>(_ value: Any, as type: T.Type, path: String, problems: inout [String]) -> T? where T.RawValue == String {
        guard let text = value as? String, let parsed = T(rawValue: text) else {
            problems.append("\(path): must be one of \(T.allRawValues.joined(separator: ", "))")
            return nil
        }
        return parsed
    }

    // MARK: Sections

    private static func bookArguments(from dict: [String: Any], problems: inout [String]) -> [String] {
        var args: [String] = []
        for key in dict.keys.sorted() where !isNote(key) {
            let name = key.hasPrefix("--") ? String(key.dropFirst(2)) : key
            if reservedBookKeys.contains(name) {
                problems.append("book.\(key): not allowed here; pass it on the command line")
                continue
            }
            let flag = "--" + name
            let value = dict[key]!
            if let b = boolean(value) {
                if b { args.append(flag) }
            } else if let d = numeric(value) {
                args.append(contentsOf: [flag, d == d.rounded() ? String(Int(d)) : String(d)])
            } else if let s = value as? String {
                args.append(contentsOf: [flag, s])
            } else if let array = value as? [Any] {
                let parts = array.compactMap { item -> String? in
                    if let s = item as? String { return s }
                    if let d = numeric(item), d == d.rounded() { return String(Int(d)) }
                    return nil
                }
                if parts.count == array.count && !parts.isEmpty { args.append(contentsOf: [flag, parts.joined(separator: ",")]) }
                else { problems.append("book.\(key): a list may only hold strings and whole numbers") }
            } else {
                problems.append("book.\(key): must be a string, number, true/false, or a list")
            }
        }
        return args
    }

    private static func scanAdjustment(_ entry: [String: Any], path: String, problems: inout [String]) -> ScanAdjustment? {
        let before = problems.count
        checkKeys(entry, allowed: scanKeys, path: path, problems: &problems)
        var adj = ScanAdjustment()
        if let v = entry["split"] {
            switch (v as? String)?.lowercased() {
            case "single", "singlepage": adj.split = .singlePage
            case "spread", "twopage", "twopagespread": adj.split = .twoPageSpread
            case "auto", "automatic": adj.split = .automatic
            default: problems.append("\(path).split: must be \"single\", \"spread\" or \"auto\"")
            }
        }
        if let v = entry["splitX"], let l = length(v, path: "\(path).splitX", allowPercent: true, problems: &problems) {
            if l.unit == .percent && !(l.value > 5 && l.value < 95) {
                problems.append("\(path).splitX: a split must lie between 5% and 95% of the scan width")
            } else if l.unit != .percent && l.value <= 0 {
                problems.append("\(path).splitX: must be positive (measured from the scan's left edge)")
            } else {
                adj.splitX = l
            }
        }
        if let v = entry["disableRectification"] { adj.disableRectification = bool(v, path: "\(path).disableRectification", problems: &problems) }
        if let v = entry["disableDeskMask"] { adj.disableDeskMask = bool(v, path: "\(path).disableDeskMask", problems: &problems) }
        if adj.split == .singlePage && adj.splitX != nil {
            problems.append("\(path): split \"single\" and splitX contradict each other")
        }
        return problems.count == before ? adj : nil
    }

    private static func pageAdjustment(_ entry: [String: Any], path: String, problems: inout [String]) -> PageAdjustment? {
        let before = problems.count
        checkKeys(entry, allowed: pageKeys, path: path, problems: &problems)
        var adj = PageAdjustment()

        if let v = entry["skew"], let d = number(v, path: "\(path).skew", problems: &problems) {
            if abs(d) > 20 { problems.append("\(path).skew: \(d) degrees is too large (limit 20)") } else { adj.skewDegrees = d }
        }
        if let v = entry["disableDewarp"] { adj.disableDewarp = bool(v, path: "\(path).disableDewarp", problems: &problems) }
        if let v = entry["keep"] { adj.keep = bool(v, path: "\(path).keep", problems: &problems) }
        if let v = entry["drop"] { adj.drop = bool(v, path: "\(path).drop", problems: &problems) }
        if let v = entry["outlier"] { adj.outlier = bool(v, path: "\(path).outlier", problems: &problems) }
        if adj.keep == true && adj.drop == true { problems.append("\(path): keep and drop contradict each other") }

        if let v = entry["tier"] {
            switch (v as? String)?.lowercased() {
            case "fullbody", "full", "1": adj.tier = .fullBody
            case "edgeanchoredpartial", "partial", "2": adj.tier = .edgeAnchoredPartial
            case "standalonefloating", "floating", "standalone", "3": adj.tier = .standaloneFloating
            default: problems.append("\(path).tier: must be \"fullBody\", \"edgeAnchoredPartial\" or \"standaloneFloating\"")
            }
        }
        if let v = entry["pageSize"] {
            if let text = v as? String, let spec = PhysicalSizeSpec.parse(text) { adj.pageSize = spec }
            else { problems.append("\(path).pageSize: must be a size such as \"6x9in\" or \"a5\"") }
        }
        if let v = entry["runningHeader"] { adj.runningHeader = policy(v, as: RunningHeaderPolicy.self, path: "\(path).runningHeader", problems: &problems) }
        if let v = entry["verticalRegistration"] { adj.verticalRegistration = policy(v, as: VerticalRegistrationPolicy.self, path: "\(path).verticalRegistration", problems: &problems) }
        if let v = entry["borderFallback"] { adj.borderFallback = policy(v, as: BorderFallbackPolicy.self, path: "\(path).borderFallback", problems: &problems) }

        if let v = entry["offset"] {
            if let dict = v as? [String: Any] {
                checkKeys(dict, allowed: ["x", "y"], path: "\(path).offset", problems: &problems)
                if let x = dict["x"] { adj.offsetX = length(x, path: "\(path).offset.x", problems: &problems) }
                if let y = dict["y"] { adj.offsetY = length(y, path: "\(path).offset.y", problems: &problems) }
            } else {
                problems.append("\(path).offset: must be an object like {\"x\": \"1mm\", \"y\": \"-2mm\"}")
            }
        }

        if let v = entry["contentBox"] {
            if let dict = v as? [String: Any] {
                checkKeys(dict, allowed: contentBoxKeys, path: "\(path).contentBox", problems: &problems)
                if let rect = dict["rect"] {
                    if let list = rect as? [Any], list.count == 4 {
                        let parsed = list.enumerated().map { i, item in
                            length(item, path: "\(path).contentBox.rect[\(i)]", problems: &problems)
                        }
                        if let l = parsed[0], let t = parsed[1], let r = parsed[2], let b = parsed[3] {
                            if r.pixels(atDPI: 600) <= l.pixels(atDPI: 600) || b.pixels(atDPI: 600) <= t.pixels(atDPI: 600) {
                                problems.append("\(path).contentBox.rect: right must be greater than left and bottom greater than top ([left, top, right, bottom])")
                            } else {
                                adj.contentBoxRect = BoxLengths(left: l, top: t, right: r, bottom: b)
                            }
                        }
                    } else {
                        problems.append("\(path).contentBox.rect: must be four lengths [left, top, right, bottom], measured from the page's top-left corner")
                    }
                }
                if let nudge = dict["nudge"] {
                    if let edges = nudge as? [String: Any] {
                        checkKeys(edges, allowed: edgeKeys, path: "\(path).contentBox.nudge", problems: &problems)
                        var e = EdgeLengths()
                        if let x = edges["top"] { e.top = length(x, path: "\(path).contentBox.nudge.top", problems: &problems) }
                        if let x = edges["left"] { e.left = length(x, path: "\(path).contentBox.nudge.left", problems: &problems) }
                        if let x = edges["bottom"] { e.bottom = length(x, path: "\(path).contentBox.nudge.bottom", problems: &problems) }
                        if let x = edges["right"] { e.right = length(x, path: "\(path).contentBox.nudge.right", problems: &problems) }
                        adj.contentBoxNudge = e
                    } else {
                        problems.append("\(path).contentBox.nudge: must be an object with top/left/bottom/right lengths; positive moves an edge right or down")
                    }
                }
            } else {
                problems.append("\(path).contentBox: must be an object with \"rect\" and/or \"nudge\"")
            }
        }

        return problems.count == before ? adj : nil
    }
}

/// Lets the policy enums list their spellings in error messages.
protocol CaseIterableLike {
    static var allRawValues: [String] { get }
}

extension RunningHeaderPolicy: CaseIterableLike {
    static var allRawValues: [String] { allCases.map(\.rawValue) }
}

extension VerticalRegistrationPolicy: CaseIterableLike {
    static var allRawValues: [String] { allCases.map(\.rawValue) }
}

extension BorderFallbackPolicy: CaseIterableLike {
    static var allRawValues: [String] { ["automatic", "forced", "disabled"] }
}
