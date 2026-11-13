import GlimmerCore
import SwiftUI

/// A thumbnail of the whole document with the visible area outlined. Drag to
/// pan; the slider zooms around the view centre.
struct NavigatorView: View {
    let session: EditorSession
    let canvas: CanvasController

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let size = fitted(in: geo.size)
                ZStack(alignment: .topLeading) {
                    if let image = session.navigatorImage {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.medium)
                            .frame(width: size.width, height: size.height)
                            .background(CheckerboardView())
                    } else {
                        Rectangle().fill(.quaternary).frame(width: size.width, height: size.height)
                    }
                    viewport(in: size)
                }
                .frame(width: size.width, height: size.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let origin = CGPoint(x: (geo.size.width - size.width) / 2, y: (geo.size.height - size.height) / 2)
                    centre(on: CGPoint(x: value.location.x - origin.x, y: value.location.y - origin.y), in: size)
                })
            }
            .frame(width: 220, height: 150)
            HStack(spacing: 6) {
                Button { canvas.zoom(by: 1 / 1.25, around: canvas.viewSize / 2) } label: { Image(systemName: "minus.magnifyingglass") }
                Slider(value: Binding(get: { log2(max(canvas.zoom, 0.01)) },
                                      set: { canvas.zoom(by: pow(2, $0) / max(canvas.zoom, 0.01), around: canvas.viewSize / 2) }),
                       in: -6...5)
                Button { canvas.zoom(by: 1.25, around: canvas.viewSize / 2) } label: { Image(systemName: "plus.magnifyingglass") }
                Text("\(Int((canvas.zoom * 100).rounded())) %")
                    .monospacedDigit()
                    .font(.caption)
                    .frame(width: 44, alignment: .trailing)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(10)
        .frame(width: 240)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigator")
    }

    private var docSize: CGSize { CGSize(width: max(canvas.documentSize.x, 1), height: max(canvas.documentSize.y, 1)) }

    private func fitted(in box: CGSize) -> CGSize {
        let s = min(box.width / docSize.width, box.height / docSize.height)
        return CGSize(width: docSize.width * s, height: docSize.height * s)
    }

    @ViewBuilder private func viewport(in size: CGSize) -> some View {
        let r = canvas.transform.visibleDocumentRect(viewSize: canvas.viewSize)
        let s = size.width / docSize.width
        let rect = CGRect(x: Double(r.x) * s, y: Double(r.y) * s, width: Double(r.width) * s, height: Double(r.height) * s)
            .intersection(CGRect(origin: .zero, size: size))
        if !rect.isNull {
            Rectangle()
                .strokeBorder(Color.red, lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    /// Pans so the document point under `p` (navigator coordinates) is in the view centre.
    private func centre(on p: CGPoint, in size: CGSize) {
        let s = docSize.width / size.width
        let target = SIMD2(Double(p.x) * s, Double(p.y) * s)
        let current = canvas.transform.viewPoint(fromDocument: target)
        canvas.pan(by: canvas.viewSize / 2 - current)
    }
}

/// Grey/white checkerboard behind transparent previews.
struct CheckerboardView: View {
    var body: some View {
        Canvas { ctx, size in
            let cell: CGFloat = 6
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var y: CGFloat = 0, row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : cell
                while x < size.width {
                    ctx.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(Color(white: 0.85)))
                    x += cell * 2
                }
                y += cell
                row += 1
            }
        }
    }
}
