import Foundation

/// Runs independent jobs with at most a given number in flight, returning the results in input order.
enum BoundedParallel {
    /// Calls `body` for every index in `0..<count`, at most `jobs` at a time.
    ///
    /// On the first error the remaining jobs are cancelled and that error is thrown.
    /// - Parameters:
    ///   - progress: Called on the caller's task with the number of finished jobs, each time one finishes.
    /// - Returns: The results, indexed like the inputs.
    static func map<T: Sendable, E: Error>(
        count: Int,
        jobs: Int,
        progress: ((Int) -> Void)? = nil,
        _ body: @escaping @Sendable (Int) async throws(E) -> T
    ) async throws(E) -> [T] {
        guard count > 0 else { return [] }
        // Even one job at a time runs in a child task: memory the system frameworks release only when a task
        // finishes (Metal and CoreGraphics temporaries) is then freed after each job instead of piling up.
        let jobs = max(1, jobs)

        let outcome: Result<[T], E> = await withTaskGroup(of: (Int, Result<T, E>).self) { group in
            var results = [T?](repeating: nil, count: count)
            var next = 0
            func launch() {
                let index = next
                next += 1
                group.addTask {
                    do throws(E) {
                        return (index, .success(try await body(index)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for _ in 0..<min(jobs, count) { launch() }
            var finished = 0
            while let (index, result) = await group.next() {
                switch result {
                case .success(let value):
                    results[index] = value
                    finished += 1
                    progress?(finished)
                    if next < count { launch() }
                case .failure(let error):
                    group.cancelAll()
                    return .failure(error)
                }
            }
            return .success(results.map { $0! })
        }
        return try outcome.get()
    }
}
