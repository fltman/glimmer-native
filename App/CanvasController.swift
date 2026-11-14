import GlimmerCore
import SwiftUI
import simd

/// Per-window view state for the canvas: zoom, pan, rotation.
/// Reachable from menu commands through `FocusedValues.canvasController`.
@MainActor
@Observable
final class CanvasController {
    private(set) var transform = ViewTransform() {
        didSet { requestRender() }
    }

    var documentSize: SIMD2<Double> = SIMD2(1920, 1080) {
        didSet {
            guard documentSize != oldValue else { return }
            hasFitted = false
            fitIfPossible()
        }
    }

    /// Drawable pixels per view point.
    var backingScale: Double = 2 {
        didSet { requestRender() }
    }

    private(set) var viewSize: SIMD2<Double> = .zero

    @ObservationIgnored var onNeedsRender: (() -> Void)?
    @ObservationIgnored private var hasFitted = false
    @ObservationIgnored private var gestureRawRotation: Double = 0

    /// Zoom relative to device pixels: 100 % shows one document pixel per screen pixel.
    var zoom: Double { transform.scale * backingScale }

    private var viewCenter: SIMD2<Double> { viewSize / 2 }

    func requestRender() { onNeedsRender?() }

    // MARK: View lifecycle

    func viewDidResize(to size: SIMD2<Double>) {
        let old = viewSize
        viewSize = size
        if hasFitted, old != .zero {
            transform.pan(by: (size - old) / 2)  // keep the centre where it was
        } else {
            fitIfPossible()
        }
    }

    private func fitIfPossible() {
        guard viewSize.x > 0, viewSize.y > 0 else { return }
        fitToWindow()
        hasFitted = true
    }

    // MARK: Interaction

    func pan(by delta: SIMD2<Double>) {
        transform.pan(by: delta)
    }

    func zoom(by factor: Double, around anchor: SIMD2<Double>) {
        transform.zoom(by: factor, around: anchor)
    }

    func beginRotationGesture() {
        gestureRawRotation = transform.rotation
    }

    /// `delta` in radians, clockwise positive. Snaps to right angles.
    func rotateGesture(by delta: Double, around anchor: SIMD2<Double>) {
        gestureRawRotation += delta
        transform.setRotation(ViewTransform.snappedRotation(gestureRawRotation), around: anchor)
    }

    /// View rotation in degrees, clockwise positive.
    var rotationDegrees: Double {
        get { transform.rotation * 180 / .pi }
        set { transform.setRotation(newValue * .pi / 180, around: viewCenter) }
    }

    func toggleFitAndActualSize(around anchor: SIMD2<Double>) {
        if abs(zoom - 1) < 0.001 {
            fitToWindow()
        } else {
            transform.setScale(1 / backingScale, around: anchor)
        }
    }

    // MARK: Commands

    func canPerform(_ id: CommandID) -> Bool {
        switch id {
        case .zoomIn: zoom < ViewTransform.maxScale * backingScale
        case .zoomOut: zoom > ViewTransform.minScale * backingScale
        case .resetViewRotation: transform.rotation != 0
        default: true
        }
    }

    func perform(_ id: CommandID) {
        switch id {
        case .zoomIn:
            transform.setScale(ZoomLadder.next(after: zoom) / backingScale, around: viewCenter)
        case .zoomOut:
            transform.setScale(ZoomLadder.previous(before: zoom) / backingScale, around: viewCenter)
        case .fitToWindow:
            fitToWindow()
        case .actualSize:
            transform.setScale(1 / backingScale, around: viewCenter)
        case .rotateViewLeft:
            transform.rotate(by: -.pi / 12, around: viewCenter)
        case .rotateViewRight:
            transform.rotate(by: .pi / 12, around: viewCenter)
        case .resetViewRotation:
            transform.setRotation(0, around: viewCenter)
        default:
            break
        }
    }

    private func fitToWindow() {
        transform = .fitting(documentSize: documentSize, in: viewSize, rotation: transform.rotation)
    }
}

extension CanvasController {
    /// Tiles of `bounds` that are on screen, nearest to the view centre first.
    func visibleTiles(in bounds: PixelRect) -> [TileCoord] {
        guard viewSize.x > 0, viewSize.y > 0 else { return [] }
        let visible = transform.visibleDocumentRect(viewSize: viewSize).intersection(bounds)
        let center = transform.documentPoint(fromView: viewSize / 2)
        let s = Double(TileGeometry.size)
        return visible.tileCoords.sorted { a, b in
            let da = SIMD2(Double(a.x) + 0.5, Double(a.y) + 0.5) * s - center
            let db = SIMD2(Double(b.x) + 0.5, Double(b.y) + 0.5) * s - center
            return simd_length_squared(da) < simd_length_squared(db)
        }
    }

    /// Document pixel under a view point.
    func documentPoint(_ viewPoint: SIMD2<Double>) -> SIMD2<Double> {
        transform.documentPoint(fromView: viewPoint)
    }
}
