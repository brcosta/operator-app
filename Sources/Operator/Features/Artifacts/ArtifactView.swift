import AppKit
import SwiftUI

struct ArtifactView: View {
  let artifact: ArtifactDescriptor
  @State private var content = ""
  @State private var image: NSImage?
  @State private var error: String?

  var body: some View {
    Group {
      if let image {
        ScrollView([.horizontal, .vertical]) {
          Image(nsImage: image).resizable().scaledToFit().padding()
        }
      } else if let error {
        ContentUnavailableView(
          "Could not open artifact", systemImage: "exclamationmark.triangle",
          description: Text(error))
      } else {
        ScrollView {
          Text(renderedText).textSelection(.enabled).font(
            artifact.kind == .json || artifact.kind == .text || artifact.kind == .patch
              ? .system(.body, design: .monospaced) : .body
          )
          .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
      }
    }
    .task(id: artifact.path) { load() }
  }

  private var renderedText: String {
    guard artifact.kind == .json, let data = content.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data),
      let pretty = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    else { return content }
    return String(decoding: pretty, as: UTF8.self)
  }

  private func load() {
    do {
      let safePath = try WorkspacePathPolicy.canonicalContainedPath(
        artifact.path, within: artifact.workspaceDirectory)
      let url = URL(fileURLWithPath: safePath)
      let values = try url.resourceValues(forKeys: [.fileSizeKey])
      guard (values.fileSize ?? 0) <= 5 * 1024 * 1024 else {
        throw NSError(
          domain: "OperatorArtifact", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Artifact exceeds the 5 MB preview limit."])
      }
      if artifact.kind == .image {
        guard let value = NSImage(contentsOf: url) else {
          throw NSError(
            domain: "OperatorArtifact", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Unsupported image data."])
        }
        image = value
      } else {
        content = try String(contentsOf: url, encoding: .utf8)
      }
    } catch { self.error = error.localizedDescription }
  }
}
