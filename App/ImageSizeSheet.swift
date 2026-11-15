import GlimmerAI
import SwiftUI

/// Image › Image Size…: a new pixel size for the whole image.
struct ImageSizeSheet: View {
    let session: EditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var width = 0
    @State private var height = 0
    @State private var keepProportions = true
    @FocusState private var focus: Field?
    @State private var expected: (width: Int?, height: Int?) = (nil, nil)

    private enum Field { case width, height }
    private var oldWidth: Int { session.state.width }
    private var oldHeight: Int { session.state.height }
    private var isValid: Bool { (1...CanvasSteps.maxSide).contains(width) && (1...CanvasSteps.maxSide).contains(height) }
    private var percent: Int { Int((Double(width) / Double(max(oldWidth, 1)) * 100).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Image Size").font(.headline)
            Text("Now \(oldWidth) × \(oldHeight) pixels").foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Width")
                    TextField("Width", value: $width, format: .number.grouping(.never))
                        .frame(width: 90)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .width)
                        .accessibilityLabel("Width in pixels")
                    Text("pixels")
                }
                GridRow {
                    Text("Height")
                    TextField("Height", value: $height, format: .number.grouping(.never))
                        .frame(width: 90)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .height)
                        .accessibilityLabel("Height in pixels")
                    Text("pixels")
                }
            }
            Toggle("Keep proportions", isOn: $keepProportions)
            HStack(spacing: 8) {
                ForEach([25, 50, 200], id: \.self) { p in
                    Button("\(p) %") {
                        expected = (nil, nil)
                        let w = max(1, Int((Double(oldWidth) * Double(p) / 100).rounded()))
                        let h = max(1, Int((Double(oldHeight) * Double(p) / 100).rounded()))
                        if w != width { expected.width = w }
                        if h != height { expected.height = h }
                        width = max(1, Int((Double(oldWidth) * Double(p) / 100).rounded()))
                        height = max(1, Int((Double(oldHeight) * Double(p) / 100).rounded()))
                    }
                }
                Spacer()
                if isValid, keepProportions { Text("\(percent) %").foregroundStyle(.secondary).monospacedDigit() }
            }
            if !isValid {
                Text("Each side must be 1 to \(CanvasSteps.maxSide) pixels.").foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Resize") {
                    do { try session.resizeImage(width: width, height: height) } catch { session.report(error) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear {
            width = oldWidth
            height = oldHeight
            focus = .width
        }
        // A side the sheet set itself (`expected`) doesn't set the other one back.
        .onChange(of: width) { _, new in
            if expected.width == new { expected.width = nil; return }
            guard keepProportions, new > 0 else { return }
            let h = max(1, Int((Double(new) * Double(oldHeight) / Double(oldWidth)).rounded()))
            if h != height { expected.height = h; height = h }
        }
        .onChange(of: height) { _, new in
            if expected.height == new { expected.height = nil; return }
            guard keepProportions, new > 0 else { return }
            let w = max(1, Int((Double(new) * Double(oldWidth) / Double(oldHeight)).rounded()))
            if w != width { expected.width = w; width = w }
        }
        .onChange(of: keepProportions) { _, on in
            guard on, width > 0 else { return }
            let h = max(1, Int((Double(width) * Double(oldHeight) / Double(oldWidth)).rounded()))
            if h != height { expected.height = h; height = h }
        }
    }
}
