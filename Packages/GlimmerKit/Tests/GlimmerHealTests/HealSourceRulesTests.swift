import Foundation
import Testing

/// The rules at the top of Heal.swift, as far as source text can show them: the target's
/// code (comments aside) calls nothing random, makes no smaller or resampled copy of the
/// image, transforms no patch, and imports nothing beyond Foundation. docs/PATENTS.md says why.
@Suite struct HealSourceRulesTests {
    private static let banned: [(rule: String, words: [String])] = [
        ("1: nothing randomised", ["random", "arc4", "drand", "shuffle", "RandomNumberGenerator", "SecRandom", "UUID("]),
        ("2: no reduced-size copy, no pyramid",
         ["pyramid", "downsample", "downscale", "resample", "resize", "vImage", "interpolat", "mipmap", "lanczos", "bilinear", "bicubic",
          "CGContext", "CIImage", "CIFilter", "MTL", "stride(from"]),
        ("3: no transformed patches, no blending of patches",
         ["rotat", "mirror", "flip", "transpose", "AffineTransform", "simd_float2x2", "sin(", "cos(", "atan", "warp", "scaled"]),
        ("3b: no gradient-domain seam", ["poisson", "laplacian", "conjugate", "gaussSeidel", "jacobi"]),
        ("5: no differential-equation solve", ["biharmonic", "cahn", "hilliard", "navier"]),
    ]

    private static func sources() throws -> [(name: String, code: String)] {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/GlimmerHeal")
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { ($0.lastPathComponent, stripComments(try String(contentsOf: $0, encoding: .utf8))) }
    }

    /// The source without `//` comments and string literals.
    static func stripComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var out = "", inString = false
            var i = line.startIndex
            while i < line.endIndex {
                let c = line[i]
                if c == "\"" { inString.toggle() } else if !inString {
                    if c == "/", line.index(after: i) < line.endIndex, line[line.index(after: i)] == "/" { break }
                    out.append(c)
                }
                i = line.index(after: i)
            }
            return out
        }.joined(separator: "\n")
    }

    @Test func theTargetHasItsSourceFiles() throws {
        #expect(try Self.sources().map(\.name).sorted() == ["ExemplarFill.swift", "FastMarchingFill.swift", "Heal.swift"])
    }

    @Test func nothingBannedIsCalled() throws {
        for (name, code) in try Self.sources() {
            let lower = code.lowercased()
            for (rule, words) in Self.banned {
                for word in words where lower.contains(word.lowercased()) {
                    Issue.record("\(name) contains “\(word)”, against rule \(rule)")
                }
            }
        }
    }

    @Test func onlyFoundationIsImported() throws {
        for (name, code) in try Self.sources() {
            let imports = code.split(separator: "\n").filter { $0.hasPrefix("import ") }.map(String.init)
            #expect(imports == ["import Foundation"], "\(name)")
        }
    }

    @Test func aPatchIsOnlyEverCopiedPixelForPixel() throws {
        // The one place the texture fill writes pixels: a plain copy from the same offset in the source patch.
        let code = try #require(try Self.sources().first { $0.name == "ExemplarFill.swift" }).code
        #expect(code.contains("let s = source + dy * w + dx"))
        #expect(code.contains("out[q * 4 + k] = out[s * 4 + k]"))
        #expect(code.components(separatedBy: "out[q * 4 + k] =").count == 2)
    }

    @Test func theCheckItselfSeesThroughComments() {
        #expect(Self.stripComments("let a = 1 // random\nlet b = \"random\"") == "let a = 1 \nlet b = ")
    }
}
