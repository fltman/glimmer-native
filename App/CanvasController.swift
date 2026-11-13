import GlimmerCore
import SwiftUI

/// Per-window view state for the canvas: zoom, pan, rotation.
/// Reachable from menu commands through `FocusedValues.canvasController`.
@MainActor
@Observable
final class CanvasController {
    private(set) var transform = ViewTransform() {
        didSet { requestRender() }
    }

    var documentSize: SIMD2<Double> = DocumentManifest.defaultNewDocument.size {
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

    private func requestRender() { onNeedsRender?() }

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

extension FocusedValues {
    @Entry var canvasController: CanvasController?
}
