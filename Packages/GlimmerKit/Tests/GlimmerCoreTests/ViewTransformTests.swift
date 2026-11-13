import Testing
import simd
@testable import GlimmerCore

private func close(_ a: SIMD2<Double>, _ b: SIMD2<Double>, tolerance: Double = 1e-9) -> Bool {
    simd_length(a - b) <= tolerance
}

private let samplePoints: [SIMD2<Double>] = [
    .zero, SIMD2(100, 50), SIMD2(-30, 2000), SIMD2(1919.5, 1079.5),
]

@Suite struct ViewTransformTests {
    @Test(arguments: [0.0, 0.3, -2.1, .pi])
    func viewDocumentRoundTrip(rotation: Double) {
        let t = ViewTransform(scale: 0.37, rotation: rotation, translation: SIMD2(12, -40))
        for p in samplePoints {
            #expect(close(t.documentPoint(fromView: t.viewPoint(fromDocument: p)), p, tolerance: 1e-7))
        }
    }

    @Test func matrixMatchesDocumentPoint() {
        let t = ViewTransform(scale: 2.5, rotation: 0.7, translation: SIMD2(300, 120))
        for p in samplePoints {
            let h = t.viewToDocumentMatrix * SIMD3(p, 1)
            #expect(close(SIMD2(h.x, h.y), t.documentPoint(fromView: p), tolerance: 1e-9))
        }
    }

    @Test func zoomKeepsAnchorFixed() {
        var t = ViewTransform(scale: 1, rotation: 0.4, translation: SIMD2(50, 60))
        let anchor = SIMD2(400.0, 300.0)
        let before = t.documentPoint(fromView: anchor)
        t.zoom(by: 3, around: anchor)
        #expect(close(t.documentPoint(fromView: anchor), before))
        #expect(abs(t.scale - 3) < 1e-12)
    }

    @Test func rotateKeepsAnchorFixed() {
        var t = ViewTransform(scale: 0.5, translation: SIMD2(10, 10))
        let anchor = SIMD2(200.0, 150.0)
        let before = t.documentPoint(fromView: anchor)
        t.rotate(by: .pi / 12, around: anchor)
        #expect(close(t.documentPoint(fromView: anchor), before))
    }

    @Test func scaleIsClamped() {
        var t = ViewTransform()
        t.zoom(by: 1e6, around: .zero)
        #expect(t.scale == ViewTransform.maxScale)
        t.zoom(by: 1e-9, around: .zero)
        #expect(t.scale == ViewTransform.minScale)
        #expect(ViewTransform(scale: .nan).scale == 1)
    }

    @Test(arguments: [0.0, .pi / 4, .pi / 2])
    func fittingCentersAndContains(rotation: Double) {
        let doc = SIMD2(1920.0, 1080.0)
        let view = SIMD2(800.0, 600.0)
        let t = ViewTransform.fitting(documentSize: doc, in: view, rotation: rotation)
        #expect(close(t.viewPoint(fromDocument: doc / 2), view / 2, tolerance: 1e-9))
        for corner in [SIMD2(0.0, 0.0), SIMD2(doc.x, 0), SIMD2(0, doc.y), doc] {
            let v = t.viewPoint(fromDocument: corner)
            #expect(v.x >= -1e-9 && v.x <= view.x + 1e-9)
            #expect(v.y >= -1e-9 && v.y <= view.y + 1e-9)
        }
    }

    @Test func rotationIsNormalized() {
        let t = ViewTransform(rotation: 3 * .pi)
        #expect(abs(t.rotation - .pi) < 1e-12)
        #expect(abs(ViewTransform(rotation: -3 * .pi / 2).rotation - .pi / 2) < 1e-12)
    }

    @Test func snapping() {
        let deg = Double.pi / 180
        #expect(ViewTransform.snappedRotation(2 * deg) == 0)
        #expect(ViewTransform.snappedRotation(88 * deg) == .pi / 2)
        #expect(ViewTransform.snappedRotation(10 * deg) == 10 * deg)
    }
}

@Suite struct ZoomLadderTests {
    @Test func stepsUpAndDown() {
        #expect(ZoomLadder.next(after: 1) == 1.5)
        #expect(ZoomLadder.next(after: 0.9) == 1)
        #expect(ZoomLadder.previous(before: 1) == 0.6667)
        #expect(ZoomLadder.previous(before: 1.2) == 1)
    }

    @Test func clampsAtEnds() {
        #expect(ZoomLadder.next(after: 64) == 64)
        #expect(ZoomLadder.previous(before: 0.02) == 0.02)
    }
}
