import Foundation

/// How a run went: parallelism, what the cache reused, and where the time went (Substep 6.3.2).
///
/// Unlike the rest of the manifest this changes from run to run, so compare manifests without it.
public struct PipelineRunReport: Sendable, Equatable, Codable {
    /// Scans processed at the same time.
    public var jobs: Int
    /// What the cache reused (`nil` when the cache was off).
    public var cache: CacheReport?
    /// Elapsed time of each pass, and the work time of each stage summed over all scans and pages.
    public var timings: [StageTiming]

    public init(jobs: Int, cache: CacheReport?, timings: [StageTiming]) {
        self.jobs = jobs
        self.cache = cache
        self.timings = timings
    }

    /// Counts of reused and computed results.
    public struct CacheReport: Sendable, Equatable, Codable {
        /// Scans whose pass-1 results all came from the cache (no rasterizing, cleaning or dewarping).
        public var scansReused: Int
        public var scans: Int
        /// Pages whose recognized text came from the cache (pruning checks included).
        public var ocrReused: Int
        public var ocrPages: Int
        /// Cache directory.
        public var directory: String

        public init(scansReused: Int, scans: Int, ocrReused: Int, ocrPages: Int, directory: String) {
            self.scansReused = scansReused
            self.scans = scans
            self.ocrReused = ocrReused
            self.ocrPages = ocrPages
            self.directory = directory
        }
    }

    /// One line of the timing table.
    public struct StageTiming: Sendable, Equatable, Codable {
        /// For example `pass1` (elapsed) or `pass1.binarize` (work time).
        public var stage: String
        public var seconds: Double
        /// `true` for elapsed time of a whole pass, `false` for work time summed over parallel jobs.
        public var isElapsed: Bool

        public init(stage: String, seconds: Double, isElapsed: Bool) {
            self.stage = stage
            self.seconds = seconds
            self.isElapsed = isElapsed
        }
    }
}

/// Work time per named stage, accumulated in a value so parallel jobs can each keep their own and merge later.
struct StageClock: Sendable {
    private(set) var seconds: [String: Double] = [:]
    private(set) var order: [String] = []

    /// Runs `work` and adds its duration to `stage`.
    mutating func measure<T>(_ stage: String, _ work: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        defer { add(stage, ContinuousClock.now - start) }
        return try work()
    }

    mutating func add(_ stage: String, _ duration: Duration) {
        let c = duration.components
        add(stage, Double(c.seconds) + Double(c.attoseconds) * 1e-18)
    }

    mutating func add(_ stage: String, _ value: Double) {
        if seconds[stage] == nil { order.append(stage) }
        seconds[stage, default: 0] += value
    }

    mutating func merge(_ other: StageClock) {
        for stage in other.order { add(stage, other.seconds[stage] ?? 0) }
    }

    /// The stages in first-seen order.
    var timings: [PipelineRunReport.StageTiming] {
        order.map { .init(stage: $0, seconds: seconds[$0] ?? 0, isElapsed: false) }
    }
}
