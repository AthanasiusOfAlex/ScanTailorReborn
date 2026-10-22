import Foundation

/// An ordered sequence of 2D points representing a polygonal line or curved baseline.
public struct PolyLine2D: Sendable, Equatable, Codable {
    public var points: [Point2D]

    /// Creates a polyline with points.
    public init(points: [Point2D] = []) {
        self.points = points
    }

    /// Number of vertices.
    public var count: Int { points.count }

    /// Whether the polyline has zero vertices.
    public var isEmpty: Bool { points.isEmpty }

    public subscript(index: Int) -> Point2D {
        get { points[index] }
        set { points[index] = newValue }
    }

    /// Appends a point to the polyline.
    public mutating func append(_ point: Point2D) {
        points.append(point)
    }

    /// Total path length along the line segments.
    public var length: Double {
        guard points.count >= 2 else { return 0 }
        var sum = 0.0
        for i in 1..<points.count {
            sum += points[i - 1].distance(to: points[i])
        }
        return sum
    }

    /// The axis-aligned bounding box enclosing all points, or `nil` if empty.
    public var boundingRect: Rect2D? {
        guard let first = points.first else { return nil }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y

        for pt in points.dropFirst() {
            minX = min(minX, pt.x)
            maxX = max(maxX, pt.x)
            minY = min(minY, pt.y)
            maxY = max(maxY, pt.y)
        }
        return Rect2D(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    /// Resamples the polyline with equidistant segment spacing along the curve.
    /// - Parameter step: Desired distance between output points. Must be > 0.
    /// - Returns: A new polyline with resampled points.
    public func resampled(step: Double) -> PolyLine2D {
        guard step > 0, points.count >= 2 else { return self }
        let total = length
        guard total > step else { return self }

        var result: [Point2D] = []
        result.reserveCapacity(Int(total / step) + 2)
        result.append(points[0])

        var targetDist = step
        var currentSegmentIdx = 0
        var segStartDist = 0.0
        var segLen = points[0].distance(to: points[1])

        while targetDist <= total && currentSegmentIdx < points.count - 1 {
            while (segStartDist + segLen) < targetDist && currentSegmentIdx < points.count - 2 {
                segStartDist += segLen
                currentSegmentIdx += 1
                segLen = points[currentSegmentIdx].distance(to: points[currentSegmentIdx + 1])
            }

            let distInSeg = targetDist - segStartDist
            let t = segLen > 0 ? (distInSeg / segLen) : 0
            let p0 = points[currentSegmentIdx]
            let p1 = points[currentSegmentIdx + 1]
            let interpolated = Point2D(
                x: p0.x + t * (p1.x - p0.x),
                y: p0.y + t * (p1.y - p0.y)
            )
            result.append(interpolated)
            targetDist += step
        }

        if let last = points.last, result.last != last {
            result.append(last)
        }
        return PolyLine2D(points: result)
    }
}
