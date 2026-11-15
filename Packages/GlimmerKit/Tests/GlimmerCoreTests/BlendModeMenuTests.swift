@testable import GlimmerCore
import Testing

@Suite struct BlendModeMenuTests {
    @Test func everyPixelModeIsInTheMenuOnce() {
        let listed = BlendMode.menuGroups.flatMap { $0 }
        #expect(Set(listed) == Set(BlendMode.pixelModes) && listed.count == BlendMode.pixelModes.count)
        #expect(Set(BlendMode.allCases.map(\.shaderIndex)).count == BlendMode.allCases.count - 1, "unique shader codes (pass-through shares normal's)")
    }

    @Test func webProjectsGetTheNearestWebMode() {
        // The web app has the W3C modes only.
        #expect(BlendMode.hardMix.webMode == .hardLight && BlendMode.vividLight.webMode == .hardLight)
        #expect(BlendMode.subtract.webMode == .difference && BlendMode.divide.webMode == .colorDodge)
        #expect(BlendMode.passThrough.webMode == .normal && BlendMode.multiply.webMode == .multiply)
    }
}
