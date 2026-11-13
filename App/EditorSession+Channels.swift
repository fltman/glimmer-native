import AppKit
import GlimmerAI
import GlimmerCore
import GlimmerRender
import GlimmerTools
import simd

extension EditorSession {
    // MARK: Channels

    /// Loads a channel (0 = RGB luminosity, 1-3 = R, G, B) of the composite as a selection.
    func loadChannelAsSelection(_ channel: Int) {
        commitLiveEdit()
        guard let metal else { return }
        do {
            let image = try ImageExporter.flattenedSRGB(state, context: metal)
            let rgba = RGBAImage(image)
            var mask = [Float](repeating: 0, count: rgba.width * rgba.height)
            for i in 0..<mask.count {
                let r = rgba.pixels[i * 4], g = rgba.pixels[i * 4 + 1], b = rgba.pixels[i * 4 + 2], a = rgba.pixels[i * 4 + 3]
                let v: Float = switch channel {
                case 1: r
                case 2: g
                case 3: b
                default: 0.299 * r + 0.587 * g + 0.114 * b
                }
                mask[i] = v * a
            }
            let selection = Selection.from(mask: mask, rect: PixelRect(x: 0, y: 0, width: rgba.width, height: rgba.height))
            edit("Load Channel") { $0.selection = selection }
        } catch {
            report(error)
        }
    }
}
