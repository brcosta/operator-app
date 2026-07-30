import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI
import WebKit
import cmark_gfm
import cmark_gfm_extensions

enum MarkdownFile {
  static let supportedExtensions: Set<String> = ["md", "markdown", "mdx"]

  static func validate(_ rawPath: String, withinDirectory: String? = nil) throws -> String {
    let scopedPath =
      try withinDirectory.map {
        try WorkspacePathPolicy.canonicalContainedPath(rawPath, within: $0)
      } ?? rawPath
    let url = URL(fileURLWithPath: scopedPath).resolvingSymlinksInPath().standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
      throw MarkdownViewerError.unsupportedFile
    }
    guard FileManager.default.isReadableFile(atPath: url.path) else {
      throw CocoaError(.fileReadNoPermission)
    }
    return url.path
  }
}

enum MarkdownViewerError: LocalizedError {
  case unsupportedFile
  case invalidText

  var errorDescription: String? {
    switch self {
    case .unsupportedFile: "Operator can open Markdown files only (.md, .markdown, or .mdx)."
    case .invalidText: "The Markdown file is not valid UTF-8 text."
    }
  }
}

@MainActor
final class MarkdownDocument: ObservableObject, Identifiable {
  let path: String
  let id: String
  private let allowedDirectory: String?
  @Published private(set) var content = ""
  @Published private(set) var modifiedAt: Date?
  @Published private(set) var errorMessage: String?
  @Published private(set) var revision = 0
  private var timer: DispatchSourceTimer?

  init(path: String, allowedDirectory: String? = nil) {
    self.path = path
    self.allowedDirectory = allowedDirectory
    id = path
    reload()
    let monitoredPath = path
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(deadline: .now() + 1, repeating: .milliseconds(900))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      let modificationDate =
        (try? FileManager.default.attributesOfItem(atPath: monitoredPath)[.modificationDate])
        as? Date
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard modificationDate != self.modifiedAt else { return }
        self.reload()
      }
    }
    self.timer = timer
    timer.resume()
  }

  deinit { timer?.cancel() }

  var title: String { URL(fileURLWithPath: path).lastPathComponent }
  var directoryURL: URL { URL(fileURLWithPath: path).deletingLastPathComponent() }

  func reload() {
    do {
      let validPath = try MarkdownFile.validate(path, withinDirectory: allowedDirectory)
      guard let text = try String(contentsOfFile: validPath, encoding: .utf8) as String? else {
        throw MarkdownViewerError.invalidText
      }
      content = text
      modifiedAt =
        (try? FileManager.default.attributesOfItem(atPath: validPath)[.modificationDate]) as? Date
      errorMessage = nil
      revision += 1
    } catch {
      errorMessage = error.localizedDescription
      modifiedAt = nil
      revision += 1
    }
  }
}

enum MarkdownRenderer {
  static func documentHTML(for markdown: String) -> String {
    let content = gfmHTML(markdown)
    return """
      <!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
      <meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src file: data:; style-src 'unsafe-inline';\">
      <style>
      :root { color-scheme: light dark; } body { margin: 0; padding: 30px 42px; font: 15px -apple-system, BlinkMacSystemFont, \"SF Pro Text\", sans-serif; line-height: 1.55; background: #161b22; color: #e6edf3; } .markdown-body { max-width: 980px; margin: auto; } h1,h2 { border-bottom: 1px solid #30363d; padding-bottom: .35em; } a { color: #58a6ff; } code { background: #2a313c; border-radius: 5px; padding: .15em .35em; } pre { background: #0d1117; padding: 16px; overflow: auto; border-radius: 7px; } pre code { background: transparent; padding: 0; } blockquote { border-left: 4px solid #3b434b; margin: 0; padding: 0 1em; color: #a7b0ba; } table { border-collapse: collapse; display: block; overflow: auto; } th,td { border: 1px solid #30363d; padding: 6px 13px; } th { background: #21262d; } img { max-width: 100%; } hr { border: 0; border-top: 1px solid #30363d; } input[type=checkbox] { margin-right: .5em; }
      </style></head><body><article class=\"markdown-body\">\(content)</article></body></html>
      """
  }

  private static func gfmHTML(_ markdown: String) -> String {
    cmark_gfm_core_extensions_ensure_registered()
    guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else {
      return "<p>Unable to parse Markdown.</p>"
    }
    defer { cmark_parser_free(parser) }
    let allocator = cmark_get_default_mem_allocator()
    var extensions: UnsafeMutablePointer<cmark_llist>?
    for name in ["table", "strikethrough", "autolink", "tagfilter", "tasklist"] {
      name.withCString { pointer in
        if let syntax = cmark_find_syntax_extension(pointer) {
          _ = cmark_parser_attach_syntax_extension(parser, syntax)
          extensions = cmark_llist_append(allocator, extensions, syntax)
        }
      }
    }
    defer { cmark_llist_free(allocator, extensions) }
    markdown.withCString { cmark_parser_feed(parser, $0, strlen($0)) }
    guard let root = cmark_parser_finish(parser) else { return "<p>Unable to parse Markdown.</p>" }
    defer { cmark_node_free(root) }
    guard let html = cmark_render_html(root, CMARK_OPT_DEFAULT, extensions) else {
      return "<p>Unable to render Markdown.</p>"
    }
    defer { free(html) }
    return String(cString: html)
  }
}

enum MarkdownNavigationPolicy {
  static func allowsExternalOpen(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return ["https", "http", "mailto"].contains(scheme)
  }
}

struct MarkdownDocumentView: View {
  @ObservedObject var document: MarkdownDocument
  @State private var mode: Mode = .rendered

  private enum Mode: String, CaseIterable, Identifiable {
    case rendered = "Rendered"
    case source = "Source"
    var id: String { rawValue }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("Mode", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
          .pickerStyle(.segmented).frame(width: 180)
        Text(document.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Spacer()
        if let modifiedAt = document.modifiedAt {
          Text(modifiedAt, style: .time).font(.caption).foregroundStyle(.secondary)
        }
        Button {
          document.reload()
        } label: {
          Image(systemName: "arrow.clockwise")
        }.help("Reload Markdown")
      }
      .padding(10)
      Divider()
      if let error = document.errorMessage {
        ContentUnavailableView(
          "Cannot Open Markdown", systemImage: "doc.questionmark", description: Text(error))
      } else if mode == .rendered {
        MarkdownWebView(document: document)
      } else {
        ScrollView {
          Text(document.content).font(.system(.body, design: .monospaced)).frame(
            maxWidth: .infinity, alignment: .leading
          ).padding(20).textSelection(.enabled)
        }
      }
    }
  }
}

struct MarkdownWebView: NSViewRepresentable {
  @ObservedObject var document: MarkdownDocument

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    return view
  }
  func updateNSView(_ view: WKWebView, context: Context) {
    guard context.coordinator.revision != document.revision else { return }
    context.coordinator.revision = document.revision
    view.loadHTMLString(
      MarkdownRenderer.documentHTML(for: document.content), baseURL: document.directoryURL)
  }
  final class Coordinator: NSObject, WKNavigationDelegate {
    var revision = -1
    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
        if MarkdownNavigationPolicy.allowsExternalOpen(url) {
          NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
      } else if navigationAction.request.url?.scheme == "about" {
        decisionHandler(.allow)
      } else {
        decisionHandler(.cancel)
      }
    }
  }
}
