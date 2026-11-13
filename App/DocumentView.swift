import GlimmerCore
import SwiftUI

struct DocumentView: View {
    @Bindable var document: GlimmerDocument
    @State private var canvas = CanvasController()

    var body: some View {
        CanvasView(controller: canvas)
            .ignoresSafeArea()
            .overlay(alignment: .bottomLeading) {
                StatusPill(width: document.manifest.width,
                           height: document.manifest.height,
                           zoom: canvas.zoom)
                    .padding(12)
            }
            .focusedSceneValue(\.canvasController, canvas)
            .onChange(of: document.manifest.size, initial: true) { _, size in
                canvas.documentSize = size
            }
    }
}

private struct StatusPill: View {
    let width: Int
    let height: Int
    let zoom: Double

    var body: some View {
        HStack(spacing: 8) {
            Text("\(width) × \(height) px")
            Text(zoom, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .allowsHitTesting(false)
    }
}
