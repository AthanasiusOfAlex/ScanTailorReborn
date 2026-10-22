import Testing
@testable import ScanTailorContracts
import Foundation

@Suite("GrayscaleBuffer Tests")
struct GrayscaleBufferTests {

    @Test("GrayscaleBuffer allocation and pixel indexing")
    func testBufferAllocation() {
        var buffer = GrayscaleBuffer(width: 10, height: 10, dpi: 600, initialValue: 255)
        #expect(buffer.width == 10)
        #expect(buffer.height == 10)
        #expect(buffer.dpi == 600)
        #expect(buffer.rowBytes == 10)
        #expect(buffer.pixels.count == 100)

        #expect(buffer[0, 0] == 255)
        buffer[5, 5] = 42
        #expect(buffer[5, 5] == 42)
        #expect(buffer.pixel(atX: 5, y: 5) == 42)
        #expect(buffer.pixel(atX: 100, y: 100) == nil)
    }

    @Test("GrayscaleBuffer cropping and clamping")
    func testCropping() {
        var buffer = GrayscaleBuffer(width: 20, height: 20, dpi: 300, initialValue: 100)
        // Draw a distinct pattern
        for y in 5..<15 {
            for x in 5..<15 {
                buffer[x, y] = 200
            }
        }

        let cropRect = Rect2I(x: 5, y: 5, width: 10, height: 10)
        let cropped = buffer.cropped(to: cropRect)

        #expect(cropped.width == 10)
        #expect(cropped.height == 10)
        #expect(cropped.dpi == 300)
        for y in 0..<10 {
            for x in 0..<10 {
                #expect(cropped[x, y] == 200)
            }
        }

        // Out-of-bounds crop clamping
        let oobRect = Rect2I(x: 15, y: 15, width: 20, height: 20)
        let clampedCrop = buffer.cropped(to: oobRect)
        #expect(clampedCrop.width == 5)
        #expect(clampedCrop.height == 5)
    }

    @Test("GrayscaleBuffer blitting")
    func testBlitting() {
        var destination = GrayscaleBuffer(width: 20, height: 20, dpi: 600, initialValue: 255)
        let source = GrayscaleBuffer(width: 6, height: 6, dpi: 600, initialValue: 0) // Black stamp

        destination.blit(from: source, at: Point2I(x: 7, y: 7))

        #expect(destination[7, 7] == 0)
        #expect(destination[12, 12] == 0)
        #expect(destination[0, 0] == 255)
        #expect(destination[6, 6] == 255)
        #expect(destination[13, 13] == 255)
    }
}
