import GlimmerAI
import GlimmerCore
import SwiftUI

/// Image › Canvas Size…: more or less room around the image, without scaling it.
struct CanvasSizeSheet: View {
    let session: EditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var width = 0
    @State private var height = 0
    @State private var anchorX = 1
    @State private var anchorY = 1

    private var oldWidth: Int { session.state.width }
    private var oldHeight: Int { session.state.height }
    private var sidesValid: Bool { (1...CanvasSteps.maxSide).contains(width) && (1...CanvasSteps.maxSide).contains(height) }
    /// Why this Mac can't hold a canvas of that size, when it can't.
    private var tooLarge: String? { sidesValid ? DocumentLimits.refusal(width: width, height: height) : nil }
    private var isValid: Bool { sidesValid && tooLarge == nil }
    private static let anchorNames = [["Top Left", "Top Center", "Top Right"], ["Left", "Center", "Right"], ["Bottom Left", "Bottom Center", "Bottom Right"]]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Canvas Size").font(.headline)
            Text("Now \(oldWidth) × \(oldHeight) pixels").foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 24) {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Text("Width")
                        TextField("Width", value: $width, format: .number.grouping(.never))
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Width in pixels")
                        Text("pixels")
                    }
                    GridRow {
                        Text("Height")
                        TextField("Height", value: $height, format: .number.grouping(.never))
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Height in pixels")
                        Text("pixels")
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Anchor").foregroundStyle(.secondary)
                    Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                        ForEach(0..<3, id: \.self) { y in
                            GridRow {
                                ForEach(0..<3, id: \.self) { x in
                                    let on = anchorX == x && anchorY == y
                                    Button {
                                        anchorX = x
                                        anchorY = y
                                    } label: {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(on ? Color.accentColor : Color.secondary.opacity(0.25))
                                            .frame(width: 22, height: 22)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(Text(LocalizedStringKey(Self.anchorNames[y][x])))
                                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                                }
                            }
                        }
                    }
                }
            }
            Text("The image stays where the anchor is. New room is transparent; what a smaller canvas cuts off is kept outside it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !sidesValid {
                StatusLine(.error, "Each side must be 1 to \(CanvasSteps.maxSide) pixels.").font(.callout)
            } else if let tooLarge {
                StatusLine(.error, verbatim: tooLarge).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Resize") {
                    let box = CanvasSteps.canvasBox(old: (oldWidth, oldHeight), new: (width, height), anchor: (anchorX, anchorY))
                    if width != oldWidth || height != oldHeight {
                        do {
                            try session.cropCanvas(to: box, deletePixels: false, actionName: stepName("Canvas Size"))
                        } catch {
                            session.report(error)
                        }
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            width = oldWidth
            height = oldHeight
        }
    }
}
