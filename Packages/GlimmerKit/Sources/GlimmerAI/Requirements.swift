import Foundation

/// Everything Glimmer uses that it didn't write: what it downloads itself, what the person may
/// install beside it, and what is bundled. One register (the series' rule, SIBLINGS.md "Det som
/// kan behöva installeras"): Settings › Models, `GET /api/v1/requirements`, the agent guide's
/// "What Glimmer may need installed" and the tables in THIRD_PARTY_NOTICES.md are all made from it.
///
/// Checksums are read from each source's own published list (the address and the date are in
/// `checksumsFrom`), never worked out by downloading the file.
public struct Requirement: Sendable, Equatable {
    public enum Kind: String, Sendable { case model, library, plugin, tool }

    public struct License: Sendable, Equatable {
        /// The SPDX identifier.
        public let spdx: String
        /// The license text at the source.
        public let url: String
    }

    /// One file of a download, with what its source publishes about it.
    public struct File: Sendable, Equatable {
        /// The path inside the repository at `commit`.
        public let path: String
        public let size: Int
        /// SHA-256 of the file, as the source lists it. Nil when the source publishes none.
        public let sha256: String?
        /// The git blob id (SHA-1 of "blob <size>\0" + the bytes) at `commit`, for a file the
        /// source keeps in git rather than in large-file storage, which lists no SHA-256.
        public let gitBlob: String?
    }

    public struct Source: Sendable, Equatable {
        public let publisher: String
        public let url: String
        public let version: String
        /// The git commit everything is fetched at, for a repository.
        public let commit: String?
        /// SHA-256 of the one file a person downloads (a by-user tool), or of what is bundled.
        public let sha256: String?
        /// Why `sha256` is null, when it is.
        public let sha256Note: String?
        /// Where the checksums above were read, and when.
        public let checksumsFrom: String
    }

    /// How a by-user program is checked after it is installed: its signature and its version.
    public struct Verify: Sendable, Equatable {
        public let command: String
        /// The Developer ID team that signs it. Nil until it has been read from a signature.
        public let teamID: String?
        public let note: String?
        public let minVersion: String
        /// Where `minVersion` comes from (the source's own documentation or changelog), and when it was read.
        public let minVersionFrom: String
    }

    public enum Install: Sendable, Equatable {
        /// Downloaded by Glimmer after the person clicks in its window; Glimmer checks every checksum.
        case inApp(where: String)
        /// Installed by the person outside Glimmer, with these exact steps.
        case byUser(steps: [String], verify: Verify)
        /// In the app already; listed for its license only.
        case bundled
    }

    public let id: String
    public let name: String
    public let kind: Kind
    /// The operations (`steps` ops) and features that need it.
    public let neededBy: [String]
    public let required: Bool
    public let license: License
    public let source: Source
    public let files: [File]
    /// The download size, or the size in the app.
    public let sizeBytes: Int?
    /// Where it ends up on the Mac.
    public let location: String
    /// How it is removed.
    public let removal: String
    public let install: Install
    /// What it does in Glimmer, for THIRD_PARTY_NOTICES.md and the guide.
    public let use: String

    public var isInstallable: Bool { install != .bundled }

    /// Glimmer has one mode: everything runs in the app on this Mac (no server mode as Flimmer has).
    public var modes: [String] { ["local"] }
    /// No entry is for Debug builds only.
    public var debugOnly: Bool { false }

    /// The command that shows the install went right, and what it should answer.
    public var check: (command: String, expect: String)? {
        switch install {
        case .inApp:
            ("curl -s http://127.0.0.1:9001/api/v1/requirements",
             "the item with \"id\": \"\(id)\" has \"installed\": true and \"verified\": true")
        case .byUser(_, let v):
            ("ollama --version", "a version of \(v.minVersion) or later (\"ollama version is 0.40.16\" for the release the steps name)")
        case .bundled:
            nil
        }
    }
}

public extension Requirement {
    static let modelsFolder = "~/Library/Containers/com.brattoo.glimmer/Data/Library/Application Support/Glimmer/Models"
    private static let huggingFaceChecksums = "the Hugging Face file list of the repository at that commit (https://huggingface.co/api/models/<repository>/tree/<commit>), read 2026-11-19"
    private static let manifestNote = "Manifest.json is kept in git, not in large-file storage, so Hugging Face lists no SHA-256 for it; Glimmer checks its git blob id at the pinned commit instead."

    static let depthAnything = Requirement(
        id: "depth-anything-v2-small", name: "Depth Anything V2 Small (Core ML)", kind: .model,
        neededBy: ["select_sky", "run_command select.sky", "Select Sky", "Lens Blur (AI panel)"], required: false,
        license: License(spdx: "Apache-2.0", url: "https://huggingface.co/apple/coreml-depth-anything-v2-small/blob/cfef6f6f2a70783dedc0bfae40cecbc2052285d3/README.md"),
        source: Source(publisher: "Apple", url: "https://huggingface.co/apple/coreml-depth-anything-v2-small",
                       version: "DepthAnythingV2SmallF16", commit: "cfef6f6f2a70783dedc0bfae40cecbc2052285d3",
                       sha256: nil, sha256Note: "Several files: each file's SHA-256 is under files. " + manifestNote,
                       checksumsFrom: huggingFaceChecksums),
        files: [
            File(path: "DepthAnythingV2SmallF16.mlpackage/Manifest.json", size: 617, sha256: nil, gitBlob: "b1ff9c6ab81057143ea82aab2796a7e54e3a8823"),
            File(path: "DepthAnythingV2SmallF16.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 399_433,
                 sha256: "44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042", gitBlob: nil),
            File(path: "DepthAnythingV2SmallF16.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 49_419_072,
                 sha256: "fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed", gitBlob: nil),
        ],
        sizeBytes: 49_819_122, location: modelsFolder + "/DepthAnythingV2SmallF16.mlmodelc",
        removal: "Glimmer › Settings › Models › Remove.", install: .inApp(where: "Settings › Models"),
        use: "Lens Blur depth map, Select Sky")

    static let segmentAnything = Requirement(
        id: "sam2.1-tiny", name: "SAM 2.1 Tiny (Core ML)", kind: .model,
        neededBy: ["select_sky", "run_command select.sky", "Magic Select", "Select Sky"], required: false,
        license: License(spdx: "Apache-2.0", url: "https://huggingface.co/apple/coreml-sam2.1-tiny/blob/39ae0a8a83e5e6cd196e804bf7cccc5f8171f306/README.md"),
        source: Source(publisher: "Apple", url: "https://huggingface.co/apple/coreml-sam2.1-tiny",
                       version: "SAM2_1Tiny FLOAT16", commit: "39ae0a8a83e5e6cd196e804bf7cccc5f8171f306",
                       sha256: nil, sha256Note: "Several files: each file's SHA-256 is under files. " + manifestNote,
                       checksumsFrom: huggingFaceChecksums),
        files: [
            File(path: "SAM2_1TinyImageEncoderFLOAT16.mlpackage/Manifest.json", size: 617, sha256: nil, gitBlob: "8f229fc88cb92867e3cbdbbc4341eed62d00f85d"),
            File(path: "SAM2_1TinyImageEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 154_372,
                 sha256: "6cbc50301ee3ff4a9366083f9647e1f06762759542d8dd0fac394ebc3682cce7", gitBlob: nil),
            File(path: "SAM2_1TinyImageEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 67_069_504,
                 sha256: "eab96eb8ff35720c79eedc0cac2a4ef32d685f9c994c39736027078528c48a97", gitBlob: nil),
            File(path: "SAM2_1TinyPromptEncoderFLOAT16.mlpackage/Manifest.json", size: 617, sha256: nil, gitBlob: "9d23f523f25e7808a78839e24224478e90a1e886"),
            File(path: "SAM2_1TinyPromptEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 20_618,
                 sha256: "3a83c167d8bd63e80f86349a78c2ab0527ce97eca1f848a4ce57fe5351241fa3", gitBlob: nil),
            File(path: "SAM2_1TinyPromptEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 2_101_056,
                 sha256: "af466cf28ef8838f409c2bfd8cc0049b9efbf9db335d60a57dbfc5160af883f2", gitBlob: nil),
            File(path: "SAM2_1TinyMaskDecoderFLOAT16.mlpackage/Manifest.json", size: 617, sha256: nil, gitBlob: "329fc398baacb99b8975bf899f74852a684c3cd6"),
            File(path: "SAM2_1TinyMaskDecoderFLOAT16.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 75_167,
                 sha256: "4601f302d4c6936e15de3a22089c2afe1fa009ef703f82147ff829b4be677577", gitBlob: nil),
            File(path: "SAM2_1TinyMaskDecoderFLOAT16.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 10_222_400,
                 sha256: "f5a8635981199fa1199007ed6798c61a326288548b74553b3c2ddb932fcdc8de", gitBlob: nil),
        ],
        sizeBytes: 79_644_968, location: modelsFolder + "/SAM2_1Tiny*.mlmodelc",
        removal: "Glimmer › Settings › Models › Remove.", install: .inApp(where: "Settings › Models"),
        use: "Magic Select, Select Sky")

    static let ollama = Requirement(
        id: "ollama", name: "Ollama", kind: .tool,
        neededBy: ["The Assistant and text features, when Ollama is chosen in Settings › AI"], required: false,
        license: License(spdx: "MIT", url: "https://github.com/ollama/ollama/blob/v0.40.16/LICENSE"),
        source: Source(publisher: "Ollama", url: "https://github.com/ollama/ollama", version: "0.40.16", commit: nil,
                       sha256: "b48d74a2d8c6a0592c816a4f85643d8d8608ad592abafbe95c04128a73c398c6",
                       sha256Note: "The SHA-256 is of Ollama.dmg 0.40.16, the release the steps name; any version from minVersion on works.",
                       checksumsFrom: "the release's asset list, Ollama.dmg digest (https://api.github.com/repos/ollama/ollama/releases/tags/v0.40.16), read 2026-11-19"),
        files: [],
        sizeBytes: 229_996_388, location: "/Applications/Ollama.app, and the models it pulls in ~/.ollama/models",
        removal: "Quit Ollama, move /Applications/Ollama.app to the Trash, and delete ~/.ollama if its models should go too.",
        install: .byUser(steps: [
            "Download Ollama.dmg of version 0.40.16 from https://github.com/ollama/ollama/releases/tag/v0.40.16.",
            "Check it: `shasum -a 256 ~/Downloads/Ollama.dmg` must print b48d74a2d8c6a0592c816a4f85643d8d8608ad592abafbe95c04128a73c398c6.",
            "Open the disk image, drag Ollama to Applications and open it from there. Gatekeeper checks its signature: if macOS refuses to open it, stop; don't override the warning.",
            "Check the signature and the version: `codesign -dv /Applications/Ollama.app` names the TeamIdentifier, and `ollama --version` must be 0.6.4 or later.",
            "Pull a model that can call tools, one the person chooses (`ollama pull <model>`; Ollama's library marks such models \"tools\").",
            "In Glimmer › Settings › AI, choose Ollama as the text service and pick the model.",
        ], verify: Verify(command: "codesign -dv /Applications/Ollama.app; ollama --version", teamID: nil,
                          note: "not read: not installed on the test Mac; the Team ID is read from the signature after the user installs it",
                          minVersion: "0.6.4",
                          minVersionFrom: "Glimmer reads a model's tools and vision from `capabilities` in /api/show, which Ollama added in commit e172f095ba4af2c98d7744ce4ffcf4cd3a8e123c (\"api: return model capabilities from the show endpoint (#10066)\", docs/api.md, 2025-04-01); the first release with it is v0.6.4 (https://github.com/ollama/ollama/releases/tag/v0.6.4, 2025-04-02). Read 2026-11-19.")),
        use: "Text and the Assistant on a local model (optional)")

    static let sparkle = Requirement(
        id: "sparkle", name: "Sparkle", kind: .library, neededBy: ["Glimmer › Check for Updates…"], required: true,
        license: License(spdx: "MIT", url: "https://github.com/sparkle-project/Sparkle/blob/2.10.1/LICENSE"),
        source: Source(publisher: "Sparkle Project", url: "https://github.com/sparkle-project/Sparkle", version: "2.10.1",
                       commit: "ab7d71291238df6e0492143b120c9b696a35f603",
                       sha256: "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a", sha256Note: nil,
                       checksumsFrom: "the release's asset list, Sparkle-for-Swift-Package-Manager.zip digest (https://api.github.com/repos/sparkle-project/Sparkle/releases/tags/2.10.1), read 2026-11-19; the commit is the one Package.resolved pins"),
        files: [], sizeBytes: nil, location: "Glimmer.app/Contents/Frameworks/Sparkle.framework",
        removal: "Part of the app.", install: .bundled, use: "Software updates")

    static let realESRGAN = Requirement(
        id: "realesrgan-general-x4v3", name: "Real-ESRGAN realesr-general-x4v3 (Core ML)", kind: .model,
        neededBy: ["upscale", "Upscale (Real-ESRGAN on this Mac)"], required: false,
        license: License(spdx: "BSD-3-Clause", url: "https://github.com/xinntao/Real-ESRGAN/blob/v0.2.5.0/LICENSE"),
        source: Source(publisher: "Xintao Wang (xinntao)", url: "https://github.com/xinntao/Real-ESRGAN/releases/tag/v0.2.5.0",
                       version: "v0.2.5.0, realesr-general-x4v3.pth (4,885,111 bytes)", commit: nil,
                       sha256: "7a6088b2ee537938f380b9049fae2b85dad57b251d047ab8f5afd256417838ec",
                       sha256Note: "The SHA-256 is of weights/weight.bin in Glimmer's own conversion (GlimmerAI/Resources/RealESRGAN.mlmodelc), which is in the repository. The original release publishes no digest for the .pth file. Converted for Glimmer on 2026-11-13 by scripts/convert-models/realesrgan.py with coremltools 9.0 and torch 2.15.0 (the model's own metadata says so).",
                       checksumsFrom: "Glimmer's repository (our own file)"),
        files: [], sizeBytes: 2_437_344, location: "Glimmer.app (GlimmerKit_GlimmerAI.bundle/RealESRGAN.mlmodelc)",
        removal: "Part of the app.", install: .bundled, use: "On-device upscaling")

    /// The whole register: installable entries first.
    static let all: [Requirement] = [depthAnything, segmentAnything, ollama, sparkle, realESRGAN]

    /// What may need installing: the in-app downloads and the by-user tools.
    static var installable: [Requirement] { all.filter(\.isInstallable) }

    static func named(_ id: String) -> Requirement? { all.first { $0.id == id } }

    /// The `steps` operations that can answer `model_missing`, and the entries each needs.
    static let modelsForOps: [String: [String]] = ["select_sky": [depthAnything.id, segmentAnything.id]]

    /// The same for `run_command` ids.
    static let modelsForCommands: [String: [String]] = ["select.sky": [depthAnything.id, segmentAnything.id]]

    /// What one step needs downloaded: by its op, or by its command for `run_command`.
    static func models(forOp op: String, command: String?) -> [String]? {
        modelsForOps[op] ?? (op == "run_command" ? command.flatMap { modelsForCommands[$0] } : nil)
    }
}

// MARK: JSON, guide and notices

private func orNull(_ value: Any?) -> Any { value ?? NSNull() }

public extension Requirement {
    /// One item of `GET /api/v1/requirements`. `installed` comes from the app (ModelStore).
    /// `verified`: for a model Glimmer downloads, whether a receipt vouches for its files (null when not installed).
    func json(installed: Bool?, installedVersion: String?, verified: Any = NSNull()) -> [String: Any] {
        var source: [String: Any] = ["publisher": self.source.publisher, "url": self.source.url,
                                     "sha256": orNull(self.source.sha256), "checksumsFrom": self.source.checksumsFrom]
        // An entry checked with `verify` has minVersion and never version (SIBLINGS.md).
        if case .byUser(_, let v) = install { source["minVersion"] = v.minVersion } else { source["version"] = self.source.version }
        if let commit = self.source.commit { source["commit"] = commit }
        if let note = self.source.sha256Note { source["sha256Note"] = note }
        var item: [String: Any] = [
            "id": id, "name": name, "kind": kind.rawValue, "neededBy": neededBy, "required": required,
            "installed": orNull(installed), "installedVersion": orNull(installedVersion), "verified": verified,
            "sizeBytes": orNull(sizeBytes), "license": ["spdx": license.spdx, "url": license.url],
            "source": source, "where": location, "remove": removal, "use": use,
            "modes": modes, "debugOnly": debugOnly,
        ]
        if !files.isEmpty {
            item["files"] = files.map { f -> [String: Any] in
                var d: [String: Any] = ["path": f.path, "size": f.size, "sha256": orNull(f.sha256)]
                if let blob = f.gitBlob { d["gitBlob"] = blob }
                return d
            }
        }
        let check: Any = self.check.map { ["command": $0.command, "expect": $0.expect] } ?? NSNull()
        switch install {
        case .inApp(let place):
            item["install"] = ["how": "in_app", "where": place, "check": check]
        case .byUser(let steps, let v):
            item["install"] = ["how": "by_user", "steps": steps, "check": check]
            item["verify"] = ["command": v.command, "teamID": orNull(v.teamID), "note": orNull(v.note),
                              "minVersion": v.minVersion, "minVersionFrom": v.minVersionFrom]
        case .bundled:
            item["install"] = ["how": "bundled"]
        }
        return item
    }

    /// The agent guide's section, from the register.
    static func guideSection() -> String {
        var s = """
        ## What Glimmer may need installed

        Everything else Glimmer needs is in the app. These are the only things that may have to be added, and none of them is needed for most work. `GET /api/v1/requirements` gives the same list as JSON, with `installed` for each, and for a model `verified`: true when Glimmer checked its files against the checksums below, false when Glimmer 0.3.0 installed it without checking (it keeps working until the person chooses **Download Again** in Settings › Models), null when it isn't installed.

        What you may do about them:

        - Explain what is missing, and show its source and license from this list.
        - Open the right Settings pane for the person with `POST /api/v1/settings/open` and `{"pane": "models"}` (or `"ai"`). It only opens the pane; it changes nothing.
        - The API never starts a download. A model is downloaded only when the person clicks **Download** in Glimmer's own window; Glimmer then checks the SHA-256 of every file (and the git blob id of `Manifest.json`) against the list below, and refuses a model whose checksum doesn't match.
        - A tool marked "installed by the person" is installed outside Glimmer. Show the person the steps, and run them only after they say yes. Use the versions given; never pipe a download into a shell, never turn Gatekeeper off and never remove the quarantine flag.
        - Paid services are not installed: the person adds a key in Glimmer › Settings › AI (`providerKeys` in `GET /api/v1/status` says which keys are there).

        A step that needs a model that isn't downloaded is refused before any step of the request runs: `422` with `{"error": {"code": "model_missing", "requirement": "<id>", "requirements": ["<id>", …], "step": <index>}}`. Today that is `select_sky` (and `run_command` with `select.sky`), which needs `depth-anything-v2-small` and `sam2.1-tiny`. A model that is installed but can't be loaded (its files damaged) answers `503` with `{"error": {"code": "model_unavailable", "requirement": "<id>", …}}`: the person removes it and downloads it again in Settings › Models.

        """
        for r in installable {
            s += "\n### \(r.name) (`\(r.id)`)\n\n"
            s += "- Kind: \(r.kind.rawValue), \(r.required ? "required" : "optional"). Needed by: \(r.neededBy.joined(separator: ", ")).\n"
            if case .byUser(_, let v) = r.install {
                s += "- Publisher: \(r.source.publisher). Source: \(r.source.url), minimum version \(v.minVersion) (the steps below install \(r.source.version))"
            } else {
                s += "- Publisher: \(r.source.publisher). Source: \(r.source.url), version \(r.source.version)"
            }
            if let commit = r.source.commit { s += ", commit `\(commit)`" }
            s += ".\n"
            s += "- License: \(r.license.spdx) (\(r.license.url)).\n"
            if let size = r.sizeBytes { s += "- Size: \(size.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))) bytes.\n" }
            if let sha = r.source.sha256 { s += "- SHA-256: `\(sha)`.\n" }
            if !r.files.isEmpty {
                s += "- Files, checked by Glimmer after the download:\n"
                for f in r.files {
                    s += "  - `\(f.path)`, \(f.size) bytes, " + (f.sha256.map { "SHA-256 `\($0)`" } ?? "git blob `\(f.gitBlob ?? "")`") + "\n"
                }
            }
            if let note = r.source.sha256Note, r.files.isEmpty { s += "- \(note)\n" }
            s += "- Checksums read from \(r.source.checksumsFrom).\n"
            s += "- Where it goes: \(r.location). Remove: \(r.removal)\n"
            if let check = r.check { s += "- Check that it went right: `\(check.command)` → \(check.expect).\n" }
            switch r.install {
            case .inApp(let place):
                s += "- Installed in Glimmer: \(place) › Download, or the question Glimmer asks the first time a feature needs it.\n"
            case .byUser(let steps, let v):
                s += "- Installed by the person, outside Glimmer:\n"
                for (i, step) in steps.enumerated() { s += "  \(i + 1). \(step)\n" }
                s += "- Check: `\(v.command)`. Team ID: \(v.teamID.map { "`\($0)`" } ?? "null (\(v.note ?? ""))"). Minimum version \(v.minVersion): \(v.minVersionFrom)\n"
            case .bundled:
                break
            }
        }
        return s
    }

    /// The two tables of THIRD_PARTY_NOTICES.md, between its markers (a test keeps the file in step).
    static func noticesTables() -> String {
        var s = "## Bundled in the app\n\n| Component | Version | License | Use |\n|---|---|---|---|\n"
        for r in all where r.install == .bundled {
            s += "| [\(r.name)](\(r.source.url)) | \(r.source.version) | [\(r.license.spdx)](\(r.license.url)) | \(r.use) |\n"
        }
        s += "\n## Downloaded by Glimmer when you click Download (not bundled)\n\n"
        s += "Glimmer downloads these at the pinned commit and checks every file's checksum before it uses them.\n\n"
        s += "| Model | Source | License | Use |\n|---|---|---|---|\n"
        for r in all { if case .inApp = r.install {
            s += "| \(r.name) | [\(r.source.url.replacingOccurrences(of: "https://huggingface.co/", with: ""))](\(r.source.url)) at `\(r.source.commit ?? "")` | [\(r.license.spdx)](\(r.license.url)) | \(r.use) |\n"
        } }
        s += "\n## Installed by you, if you want it\n\n| Tool | Version | License | Use |\n|---|---|---|---|\n"
        for r in all { if case .byUser(_, let v) = r.install {
            s += "| [\(r.name)](\(r.source.url)) | \(v.minVersion) or later (\(r.source.version) checked) | [\(r.license.spdx)](\(r.license.url)) | \(r.use) |\n"
        } }
        return s
    }
}
