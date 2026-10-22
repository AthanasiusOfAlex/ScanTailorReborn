import Testing
@testable import ScanTailorContracts
import Foundation

@Suite("Geometry Primitives Tests")
struct GeometryTests {

    @Test("Point2D arithmetic and distance")
    func testPoint2D() {
        let p1 = Point2D(x: 3.0, y: 4.0)
        let p2 = Point2D(x: 0.0, y: 0.0)

        #expect(p1.distance(to: p2) == 5.0)
        #expect(p1.squaredDistance(to: p2) == 25.0)

        let sum = p1 + Point2D(x: 1.0, y: 2.0)
        #expect(sum == Point2D(x: 4.0, y: 6.0))

        let diff = p1 - Point2D(x: 1.0, y: 1.0)
        #expect(diff == Point2D(x: 2.0, y: 3.0))

        let scaled = p1 * 2.0
        #expect(scaled == Point2D(x: 6.0, y: 8.0))

        let rotated = Point2D(x: 1.0, y: 0.0).rotated(by: .pi / 2.0)
        #expect(abs(rotated.x) < 1e-10)
        #expect(abs(rotated.y - 1.0) < 1e-10)
    }

    @Test("Point2I and Size2I metrics")
    func testIntegerPointsAndSizes() {
        let pt = Point2I(x: 10, y: 20)
        let pt2 = Point2I(x: 5, y: 5)
        #expect(pt + pt2 == Point2I(x: 15, y: 25))
        #expect(pt - pt2 == Point2I(x: 5, y: 15))
        #expect(pt.asPoint2D == Point2D(x: 10.0, y: 20.0))

        let size = Size2I(width: 600, height: 800)
        #expect(size.pixelCount == 480_000)
        #expect(abs(size.aspectRatio - (600.0 / 800.0)) < 1e-6)
        #expect(!size.isEmpty)

        let emptySize = Size2I(width: 0, height: 100)
        #expect(emptySize.isEmpty)
        #expect(emptySize.pixelCount == 0)
    }

    @Test("Rect2D intersection and union")
    func testRect2D() {
        let r1 = Rect2D(x: 0, y: 0, width: 100, height: 100)
        let r2 = Rect2D(x: 50, y: 50, width: 100, height: 100)

        #expect(r1.contains(Point2D(x: 50, y: 50)))
        #expect(r1.intersects(r2))

        let inter = r1.intersection(r2)
        #expect(inter != nil)
        #expect(inter == Rect2D(x: 50, y: 50, width: 50, height: 50))

        let un = r1.union(r2)
        #expect(un == Rect2D(x: 0, y: 0, width: 150, height: 150))

        let r3 = Rect2D(x: 200, y: 200, width: 10, height: 10)
        #expect(r1.intersection(r3) == nil)
    }

    @Test("Rect2I containment and clamping")
    func testRect2I() {
        let bounds = Rect2I(x: 0, y: 0, width: 600, height: 800)
        let roi = Rect2I(x: 500, y: 700, width: 200, height: 200)

        let clamped = roi.clamped(to: bounds)
        #expect(clamped != nil)
        #expect(clamped == Rect2I(x: 500, y: 700, width: 100, height: 100))

        #expect(bounds.contains(x: 300, y: 400))
        #expect(!bounds.contains(x: 600, y: 800)) // Half-open upper bounds

        let outside = Rect2I(x: 700, y: 900, width: 50, height: 50)
        #expect(outside.clamped(to: bounds) == nil)
    }

    @Test("PolyLine2D length and resampling")
    func testPolyLine2D() {
        let pts = [
            Point2D(x: 0, y: 0),
            Point2D(x: 10, y: 0),
            Point2D(x: 10, y: 10)
        ]
        let poly = PolyLine2D(points: pts)

        #expect(poly.count == 3)
        #expect(poly.length == 20.0)

        let bbox = poly.boundingRect
        #expect(bbox != nil)
        #expect(bbox == Rect2D(x: 0, y: 0, width: 10, height: 10))

        let resampled = poly.resampled(step: 5.0)
        #expect(resampled.count == 5)
        #expect(resampled.points.first == Point2D(x: 0, y: 0))
        #expect(resampled.points.last == Point2D(x: 10, y: 10))
    }

    @Test("AffineTransform2D composition and inverse")
    func testAffineTransform2D() throws {
        let t1 = AffineTransform2D.translation(tx: 10, ty: 20)
        let s1 = AffineTransform2D.scale(sx: 2, sy: 3)
        let combined = t1.concatenating(s1)

        let p = Point2D(x: 5, y: 5)
        // t1(p) = (15, 25); then s1(15, 25) = (30, 75)
        let transformed = combined.transform(p)
        #expect(abs(transformed.x - 30.0) < 1e-9)
        #expect(abs(transformed.y - 75.0) < 1e-9)

        let inv = try combined.inverted()
        let roundtrip = inv.transform(transformed)
        #expect(abs(roundtrip.x - p.x) < 1e-9)
        #expect(abs(roundtrip.y - p.y) < 1e-9)

        // Rotation around center
        let rotCenter = Point2D(x: 50, y: 50)
        let rot = AffineTransform2D.rotation(radians: .pi / 2.0, center: rotCenter)
        let rotatedPt = rot.transform(Point2D(x: 60, y: 50))
        #expect(abs(rotatedPt.x - 50.0) < 1e-9)
        #expect(abs(rotatedPt.y - 60.0) < 1e-9)
    }

    @Test("DewarpGrid bilinear sampling")
    func testDewarpGrid() {
        let size = Size2I(width: 100, height: 100)
        let grid = DewarpGrid.identity(outputSize: size, columns: 3, rows: 3)

        // Midpoint should map to midpoint
        let mid = grid.sampleSource(outputX: 50, outputY: 50)
        #expect(abs(mid.x - 50.0) < 1e-4)
        #expect(abs(mid.y - 50.0) < 1e-4)

        // Corner (0,0)
        let origin = grid.sampleSource(outputX: 0, outputY: 0)
        #expect(abs(origin.x) < 1e-4)
        #expect(abs(origin.y) < 1e-4)

        // Corner (100, 100)
        let maxCorner = grid.sampleSource(outputX: 100, outputY: 100)
        #expect(abs(maxCorner.x - 100.0) < 1e-4)
        #expect(abs(maxCorner.y - 100.0) < 1e-4)
    }
}
