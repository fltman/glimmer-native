import GlimmerCore
import SwiftUI
import UniformTypeIdentifiers

/// A `.glimmer` package. Phase 0 only carries the manifest; layers arrive in phase 1.
///
/// Every edit must register an undo action. SwiftUI uses the undo stack to
/// detect unsaved changes, so autosave depends on it.
@Observable
final class GlimmerDocument: Document {
    static let readableContentTypes: [UTType] = [.glimmerDocument]

    var manifest: DocumentManifest

    init() {
        manifest = .defaultNewDocument
    }

    func reader(configuration: sending ReadConfiguration) -> sending FileWrapperDocumentReader<DocumentManifest> {
        FileWrapperDocumentReader(configuration) { wrapper in
            try GlimmerPackage.manifest(from: wrapper)
        }
    }

    @MainActor
    func apply(snapshot: sending DocumentManifest, previous: sending DocumentManifest?) async throws {
        manifest = snapshot
    }

    func writer(configuration: sending WriteConfiguration) -> sending FileWrapperDocumentWriter<DocumentManifest> {
        FileWrapperDocumentWriter(configuration) { snapshot, _ in
            try GlimmerPackage.fileWrapper(for: snapshot)
        }
    }

    @MainActor
    func snapshot(contentType: UTType) async throws -> sending DocumentManifest {
        manifest
    }
}
