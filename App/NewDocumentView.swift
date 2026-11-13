import GlimmerCore
import SwiftUI

struct NewDocumentView: View {
    /// Closes the hosting window.
    var dismiss: () -> Void = {}

    @Environment(\.self) private var environment

    struct Preset: Hashable, Identifiable {
        let name: String
        let width: Int
        let height: Int
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: "HD 1920 × 1080", width: 1920, height: 1080),
        Preset(name: "4K 3840 × 2160", width: 3840, height: 2160),
        Preset(name: "Square 1024", width: 1024, height: 1024),
        Preset(name: "Square 2048", width: 2048, height: 2048),
        Preset(name: "Portrait 1080 × 1350", width: 1080, height: 1350),
        Preset(name: "Story 1080 × 1920", width: 1080, height: 1920),
        Preset(name: "A4 at 150 ppi", width: 1240, height: 1754),
    ]

    enum BackgroundChoice: String, CaseIterable, Identifiable {
        case white, black, transparent, custom
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @AppStorage("newDocument.width") private var width = 1920
    @AppStorage("newDocument.height") private var height = 1080
    @AppStorage("newDocument.background") private var background = BackgroundChoice.white
    @State private var customColor = Color(red: 0.95, green: 0.93, blue: 0.88)

    private var isValid: Bool {
        (1...DocumentManifest.maxDimension).contains(width) && (1...DocumentManifest.maxDimension).contains(height)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Preset", selection: Binding(
                    get: { Self.presets.first { $0.width == width && $0.height == height } },
                    set: { if let p = $0 { width = p.width; height = p.height } }
                )) {
                    Text("Custom").tag(Preset?.none)
                    ForEach(Self.presets) { Text($0.name).tag(Optional($0)) }
                }
                TextField("Width", value: $width, format: .number.grouping(.never))
                TextField("Height", value: $height, format: .number.grouping(.never))
                Picker("Background", selection: $background) {
                    ForEach(BackgroundChoice.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                }
                if background == .custom {
                    ColorPicker("Color", selection: $customColor, supportsOpacity: false)
                }
                if !isValid {
                    Text("Width and height must be between 1 and \(DocumentManifest.maxDimension) pixels.")
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 400)
    }

    private var backgroundValue: DocumentState.Background {
        switch background {
        case .white:
            return .white
        case .black:
            return .black
        case .transparent:
            return .transparent
        case .custom:
            let c = customColor.resolve(in: environment)
            return .color(SIMD4(c.linearRed, c.linearGreen, c.linearBlue, 1))
        }
    }

    private func create() {
        dismiss()
        DocumentOpener.shared.createDocument(.new(width: width, height: height, background: backgroundValue))
    }

    private func close() {
        dismiss()
    }
}
