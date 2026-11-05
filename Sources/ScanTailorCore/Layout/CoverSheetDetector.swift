import Foundation

/// How the first and last pages of a scan are treated (`--cover-handling`).
public enum CoverHandling: String, Sendable, Equatable, Codable, CaseIterable {
    /// Keep every page that has content.
    case keep
    /// Drop cover sheets that a digital library added (JSTOR, Project MUSE, Google Books, Internet Archive).
    case auto
    /// Drop library cover sheets and printed covers too (an odd-sized first or last scan).
    case strip
}

/// Recognizes the cover sheet a digital repository puts in front of a scanned book or article.
///
/// The decision is made on recognized text: a sheet counts only when it carries one of the fixed phrases such
/// sheets always print, never on a single word like "JSTOR" (a book can cite it). Project MUSE stamps its name on
/// every page of an article, and Google Books prints "Digitized by Google" on every page of a book, so neither
/// mark is enough either.
public enum CoverSheetDetector {
    /// The repository whose cover sheet `text` is, or `nil` when it is not one.
    /// - Parameter text: The recognized text of one page, in any case and spacing.
    public static func repository(in text: String) -> String? {
        let t = text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        func has(_ phrase: String) -> Bool { t.contains(phrase) }

        if has("your use of the jstor archive") || has("linked references are available on jstor")
            || has("you may need to log in to jstor")
            || (has("jstor") && has("stable url") && (has("accessed:") || has("author(s):") || has("published by:"))) {
            return "JSTOR"
        }
        if has("for additional information about this article")
            || (has("muse.jhu.edu/article") && has("project muse")) {
            return "Project MUSE"
        }
        // Not "Digitized by Google": that is the watermark at the foot of every page of the book.
        if has("digital copy of a book that was preserved for generations")
            || (has("google") && has("usage guidelines"))
            || has("google book search") {
            return "Google Books"
        }
        if has("digitized by the internet archive") {
            return "Internet Archive"
        }
        return nil
    }
}
