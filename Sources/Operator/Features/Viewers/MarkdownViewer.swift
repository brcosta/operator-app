import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI
import WebKit
import cmark_gfm
import cmark_gfm_extensions

enum FilePreviewLimits {
  /// Keep previews bounded so parsing and syntax highlighting cannot monopolize the UI process.
  static let maximumTextBytes: UInt64 = 5 * 1024 * 1024
  // 256 KiB is large enough for normal source files while keeping attributed-text layout and
  // WebKit Markdown rendering comfortably below the point where AppKit can stall.
  static let maximumRenderableBytes: UInt64 = 256 * 1024

  static func boundedPreview(_ text: String) -> (content: String, isTruncated: Bool) {
    guard let data = text.data(using: .utf8), data.count > maximumRenderableBytes else {
      return (text, false)
    }
    let prefix = Data(data.prefix(Int(maximumRenderableBytes)))
    let content = String(data: prefix, encoding: .utf8) ?? String(text.prefix(256_000))
    return (content, true)
  }
}

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

/// Shared geometry keeps the collapsed navigator affordance in exactly the
/// position occupied by the expanded navigator's close control.
enum FileNavigatorChrome {
  static let headerInset: CGFloat = 11
  static let controlSize: CGFloat = 28
  static let headerContentHeight: CGFloat = 40
  static let floatingTopInset: CGFloat =
    headerInset + (headerContentHeight - controlSize) / 2
}

private struct FastTooltipModifier: ViewModifier {
  let message: String
  @State private var isHovered = false

  func body(content: Content) -> some View {
    content
      .onHover { isHovered = $0 }
      .overlay(alignment: .bottom) {
        if isHovered {
          Text(message)
            .font(.caption2)
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
            .overlay {
              RoundedRectangle(cornerRadius: 5).strokeBorder(.separator)
            }
            .fixedSize()
            .offset(y: 30)
            .allowsHitTesting(false)
            .zIndex(100)
        }
      }
  }
}

private extension View {
  func fastTooltip(_ message: String) -> some View {
    modifier(FastTooltipModifier(message: message))
  }
}

@MainActor
final class MarkdownDocument: ObservableObject, Identifiable {
  let path: String
  let id: String
  private let allowedDirectory: String?
  @Published private(set) var content = ""
  @Published private(set) var diffContent: String?
  @Published private(set) var modifiedAt: Date?
  @Published private(set) var errorMessage: String?
  @Published private(set) var revision = 0
  private var timer: DispatchSourceTimer?
  private var loadTask: Task<Void, Never>?
  private var diffTask: Task<Void, Never>?

  init(path: String, allowedDirectory: String? = nil, watchForChanges: Bool = true) {
    self.path = path
    self.allowedDirectory = allowedDirectory
    id = path
    reload()
    if watchForChanges { startWatching() }
  }

  func setWatching(_ enabled: Bool) {
    if enabled {
      guard timer == nil else { return }
      startWatching()
    } else {
      timer?.cancel()
      timer = nil
    }
  }

  private func startWatching() {
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

  deinit {
    timer?.cancel()
    loadTask?.cancel()
    diffTask?.cancel()
  }

  var title: String { URL(fileURLWithPath: path).lastPathComponent }
  var directoryURL: URL { URL(fileURLWithPath: path).deletingLastPathComponent() }

  func reload() {
    loadTask?.cancel()
    diffTask?.cancel()
    diffContent = nil
    let path = path
    let allowedDirectory = allowedDirectory
    loadTask = Task { @MainActor [weak self] in
      let result = await Task.detached(priority: .utility) {
        Result { () throws -> MarkdownLoadPayload in
          let validPath = try MarkdownFile.validate(path, withinDirectory: allowedDirectory)
          let attributes = try FileManager.default.attributesOfItem(atPath: validPath)
          let byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
          guard byteCount <= FilePreviewLimits.maximumRenderableBytes else {
            throw NSError(
              domain: "OperatorFileViewer", code: 2,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "This Markdown file is too large to preview safely (limit: 256 KB). Open it in an external editor instead."
              ])
          }
          let text = try String(contentsOfFile: validPath, encoding: .utf8)
          let modifiedAt =
            (try? FileManager.default.attributesOfItem(atPath: validPath)[.modificationDate])
            as? Date
          return MarkdownLoadPayload(
            content: text, safePath: validPath, modifiedAt: modifiedAt)
        }
      }.value
      guard !Task.isCancelled, let self else { return }
      switch result {
      case .success(let payload):
        self.content = payload.content
        self.modifiedAt = payload.modifiedAt
        self.errorMessage = nil
        self.revision += 1
        self.loadPendingDiff(for: payload.safePath)
      case .failure(let error):
        self.content = ""
        self.diffContent = nil
        self.errorMessage = error.localizedDescription
        self.modifiedAt = nil
      }
      if case .failure = result { self.revision += 1 }
    }
  }

  private func loadPendingDiff(for safePath: String) {
    diffTask?.cancel()
    diffTask = Task { @MainActor [weak self] in
      let diff = await Task.detached(priority: .utility) {
        (try? GitRepository.diff(for: safePath)).map {
          FilePreviewLimits.boundedPreview($0).content
        }
      }.value
      guard !Task.isCancelled, let self else { return }
      self.diffContent = diff
      self.revision += 1
    }
  }
}

private struct MarkdownLoadPayload: Sendable {
  let content: String
  let safePath: String
  let modifiedAt: Date?
}

enum MarkdownRenderer {
  static func documentHTML(for markdown: String, colorScheme: ColorScheme = .dark) -> String {
    let content = gfmHTML(markdown)
    let palette = MarkdownPalette(colorScheme: colorScheme)
    return """
      <!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
      <meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src file: data:; style-src 'unsafe-inline';\">
      <style>
      \(palette.css)
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

struct MarkdownPalette: Equatable {
  let colorScheme: ColorScheme
  let background: String
  let foreground: String
  let border: String
  let link: String
  let inlineCode: String
  let codeBlock: String
  let quote: String
  let quoteBorder: String
  let tableHeader: String

  init(colorScheme: ColorScheme) {
    self.colorScheme = colorScheme
    switch colorScheme {
    case .light:
      background = "#f6f8fa"
      foreground = "#24292f"
      border = "#d0d7de"
      link = "#0969da"
      inlineCode = "#eaeef2"
      codeBlock = "#eef1f4"
      quote = "#57606a"
      quoteBorder = "#d0d7de"
      tableHeader = "#eaedf0"
    default:
      background = "#161b22"
      foreground = "#e6edf3"
      border = "#30363d"
      link = "#58a6ff"
      inlineCode = "#2a313c"
      codeBlock = "#0d1117"
      quote = "#a7b0ba"
      quoteBorder = "#3b434b"
      tableHeader = "#21262d"
    }
  }

  var css: String {
    """
    :root { color-scheme: \(colorScheme == .light ? "light" : "dark"); }
    body { margin: 0; padding: 30px 42px; font: 15px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; line-height: 1.55; background: \(background); color: \(foreground); }
    .markdown-body { max-width: 980px; margin: auto; } h1,h2 { border-bottom: 1px solid \(border); padding-bottom: .35em; } a { color: \(link); } code { background: \(inlineCode); border-radius: 5px; padding: .15em .35em; } pre { background: \(codeBlock); padding: 16px; overflow: auto; border-radius: 7px; } pre code { background: transparent; padding: 0; } blockquote { border-left: 4px solid \(quoteBorder); margin: 0; padding: 0 1em; color: \(quote); } table { border-collapse: collapse; display: block; overflow: auto; } th,td { border: 1px solid \(border); padding: 6px 13px; } th { background: \(tableHeader); } img { max-width: 100%; } hr { border: 0; border-top: 1px solid \(border); } input[type=checkbox] { margin-right: .5em; }
    """
  }

  var backgroundColor: NSColor {
    switch colorScheme {
    case .light: NSColor(srgbRed: 246 / 255, green: 248 / 255, blue: 250 / 255, alpha: 1)
    default: NSColor(srgbRed: 22 / 255, green: 27 / 255, blue: 34 / 255, alpha: 1)
    }
  }
}

enum MarkdownNavigationPolicy {
  static func allowsExternalOpen(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return ["https", "http", "mailto"].contains(scheme)
  }

  static func allowsDocumentLoad(_ url: URL, baseURL: URL) -> Bool {
    if url.scheme?.lowercased() == "about" {
      return url.absoluteString == "about:blank"
    }
    guard url.isFileURL, baseURL.isFileURL else { return false }
    return url.standardizedFileURL.path == baseURL.standardizedFileURL.path
  }
}

struct MarkdownDocumentView: View {
  @ObservedObject var document: MarkdownDocument
  var close: (() -> Void)? = nil
  @State private var mode: Mode = .rendered
  @State private var didApplyInitialMode = false
  @Environment(\.colorScheme) private var colorScheme

  private enum Mode: String, CaseIterable, Identifiable {
    case diff = "Diff"
    case rendered = "Rendered"
    case source = "Source"
    var id: String { rawValue }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("Mode", selection: $mode) {
          if document.diffContent != nil { Text(Mode.diff.rawValue).tag(Mode.diff) }
          Text(Mode.rendered.rawValue).tag(Mode.rendered)
          Text(Mode.source.rawValue).tag(Mode.source)
        }
        .pickerStyle(.segmented)
        .frame(width: document.diffContent == nil ? 180 : 250)
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
        if let close {
          Button(action: close) {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .help("Close Markdown pane")
        }
      }
      .padding(10)
      .fixedSize(horizontal: false, vertical: true)
      .layoutPriority(1)
      Divider()
      if let error = document.errorMessage {
        ContentUnavailableView(
          "Cannot Open Markdown", systemImage: "doc.questionmark", description: Text(error))
      } else if mode == .diff, let diffContent = document.diffContent {
        markdownDiffEditor(diffContent)
      } else if mode == .rendered {
        MarkdownWebView(document: document, colorScheme: colorScheme)
      } else {
        ScrollView {
          Text(document.content).font(.system(.body, design: .monospaced)).frame(
            maxWidth: .infinity, alignment: .leading
          ).padding(20).textSelection(.enabled)
        }
      }
    }
    .onChange(of: document.diffContent != nil) { _, hasDiff in
      if hasDiff, !didApplyInitialMode {
        didApplyInitialMode = true
        mode = .diff
      } else if !hasDiff, mode == .diff {
        didApplyInitialMode = false
        mode = .rendered
      }
    }
  }

  private func markdownDiffEditor(_ diff: String) -> some View {
    GeometryReader { viewport in
      ScrollView([.horizontal, .vertical]) {
        HStack(alignment: .top, spacing: 0) {
          Text(SourceEditorPresentation.lineNumbers(for: diff))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.trailing)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 14)
            .frame(minHeight: viewport.size.height, alignment: .topTrailing)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            .accessibilityHidden(true)
          Rectangle()
            .fill(.separator)
            .frame(width: 1)
          Text(DiffSyntaxHighlighter.highlight(diff, colorScheme: colorScheme))
            .textSelection(.enabled)
            .padding(.leading, 14)
            .padding(.trailing, 80)
            .padding(.vertical, 14)
            .frame(minHeight: viewport.size.height, alignment: .topLeading)
        }
        .font(.system(.body, design: .monospaced))
        .fixedSize(horizontal: true, vertical: false)
        .frame(
          minWidth: viewport.size.width, minHeight: viewport.size.height,
          alignment: .topLeading)
      }
      .defaultScrollAnchor(.topLeading)
      .background(Color(nsColor: .textBackgroundColor))
    }
  }
}

struct MarkdownWebView: NSViewRepresentable {
  @ObservedObject var document: MarkdownDocument
  let colorScheme: ColorScheme

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    return view
  }
  func updateNSView(_ view: WKWebView, context: Context) {
    let palette = MarkdownPalette(colorScheme: colorScheme)
    guard context.coordinator.shouldReload(revision: document.revision, palette: palette) else {
      return
    }
    context.coordinator.beginRender(
      content: document.content, revision: document.revision, palette: palette,
      baseURL: document.directoryURL, in: view)
  }
  final class Coordinator: NSObject, WKNavigationDelegate {
    var revision = -1
    var palette: MarkdownPalette?
    private var documentHTML = ""
    private var documentBaseURL: URL?
    private var backgroundColor = NSColor.clear
    private var retriedAfterProcessTermination = false
    private var renderTask: Task<Void, Never>?

    deinit { renderTask?.cancel() }

    func shouldReload(revision: Int, palette: MarkdownPalette) -> Bool {
      self.revision != revision || self.palette != palette
    }

    func beginRender(
      content: String, revision: Int, palette: MarkdownPalette, baseURL: URL, in webView: WKWebView
    ) {
      renderTask?.cancel()
      self.revision = revision
      self.palette = palette
      let backgroundColor = palette.backgroundColor
      renderTask = Task { [weak self, weak webView] in
        let html = await Task.detached(priority: .utility) {
          MarkdownRenderer.documentHTML(for: content, colorScheme: palette.colorScheme)
        }.value
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard let self, let webView else { return }
          self.load(
            html: html, baseURL: baseURL, backgroundColor: backgroundColor, in: webView)
        }
      }
    }

    func load(html: String, baseURL: URL, backgroundColor: NSColor, in webView: WKWebView) {
      documentHTML = html
      documentBaseURL = baseURL
      self.backgroundColor = backgroundColor
      retriedAfterProcessTermination = false
      webView.underPageBackgroundColor = backgroundColor
      webView.loadHTMLString(html, baseURL: baseURL)
    }

    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
        if MarkdownNavigationPolicy.allowsExternalOpen(url) {
          NSWorkspace.shared.open(url)
          decisionHandler(.cancel)
        } else if let documentBaseURL,
          MarkdownNavigationPolicy.allowsDocumentLoad(url, baseURL: documentBaseURL)
        {
          decisionHandler(.allow)
        } else {
          decisionHandler(.cancel)
        }
      } else if navigationAction.targetFrame?.isMainFrame == true,
        let url = navigationAction.request.url,
        let documentBaseURL,
        MarkdownNavigationPolicy.allowsDocumentLoad(url, baseURL: documentBaseURL)
      {
        decisionHandler(.allow)
      } else {
        decisionHandler(.cancel)
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      retriedAfterProcessTermination = false
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      guard !retriedAfterProcessTermination, let documentBaseURL else { return }
      retriedAfterProcessTermination = true
      webView.underPageBackgroundColor = backgroundColor
      webView.loadHTMLString(documentHTML, baseURL: documentBaseURL)
    }
  }
}

enum HTMLFile {
  static let supportedExtensions: Set<String> = ["html", "htm"]

  static func isSupported(path: String) -> Bool {
    supportedExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
  }
}

enum SecureHTMLRenderer {
  static let scheme = "operator-html"

  /// Operator previews HTML as inert content. Pages that depend on JavaScript or a canvas would
  /// otherwise look like a broken, empty document when WebKit correctly refuses to execute them.
  /// Detect those pages and show an explanation in the document itself while retaining the safe
  /// no-script policy.
  static func containsInteractiveContent(_ source: String) -> Bool {
    source.range(
      of: #"<(script|canvas|iframe|object|embed|video|audio)\b"#,
      options: [.regularExpression, .caseInsensitive]) != nil
  }

  static func documentHTML(for source: String, colorScheme: ColorScheme) -> String {
    let palette =
      colorScheme == .dark
      ? (background: "#161b22", foreground: "#e6edf3")
      : (background: "#f6f8fa", foreground: "#24292f")
    let securityHead = """
      <meta charset="utf-8">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; connect-src 'none'; object-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'; img-src \(scheme): data:; style-src 'unsafe-inline' \(scheme):; font-src \(scheme): data:; media-src \(scheme):">
      <style>:root { color-scheme: \(colorScheme == .dark ? "dark" : "light"); } html, body { min-height: 100%; } body { margin: 20px; background: \(palette.background); color: \(palette.foreground); font: -apple-system-body; } .operator-preview-notice { box-sizing: border-box; max-width: 720px; margin: 0 auto 20px; padding: 12px 16px; border: 1px solid \(colorScheme == .dark ? "#30363d" : "#d0d7de"); border-radius: 10px; background: \(colorScheme == .dark ? "#21262d" : "#f6f8fa"); color: \(palette.foreground); font: -apple-system-body; } .operator-preview-notice strong { display: block; margin-bottom: 4px; } .operator-preview-notice span { opacity: .78; }</style>
      """
    let interactiveNotice = containsInteractiveContent(source)
      ? "<aside class=\"operator-preview-notice\" role=\"note\"><strong>Interactive content is disabled in secure preview</strong><span>Scripts and embedded applications are blocked to protect your workspace. Open the file externally to run it.</span></aside>"
      : ""
    if let range = source.range(
      of: #"<head\b[^>]*>"#, options: [.regularExpression, .caseInsensitive])
    {
      var document = source
      document.insert(contentsOf: securityHead, at: range.upperBound)
      if !interactiveNotice.isEmpty,
        let bodyRange = document.range(
          of: #"<body\b[^>]*>"#, options: [.regularExpression, .caseInsensitive])
      {
        document.insert(contentsOf: interactiveNotice, at: bodyRange.upperBound)
      }
      return document
    }
    if let range = source.range(
      of: #"<html\b[^>]*>"#, options: [.regularExpression, .caseInsensitive])
    {
      var document = source
      document.insert(contentsOf: "<head>\(securityHead)</head>", at: range.upperBound)
      if !interactiveNotice.isEmpty,
        let bodyRange = document.range(
          of: #"<body\b[^>]*>"#, options: [.regularExpression, .caseInsensitive])
      {
        document.insert(contentsOf: interactiveNotice, at: bodyRange.upperBound)
      }
      return document
    }
    return "<!doctype html><html><head>\(securityHead)</head><body>\(interactiveNotice)\(source)</body></html>"
  }
}

enum SecureHTMLNavigationPolicy {
  static func allowsExternalOpen(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return ["https", "http", "mailto"].contains(scheme)
  }

  static func allowsInternalDocumentLoad(_ url: URL) -> Bool {
    url.scheme?.lowercased() == SecureHTMLRenderer.scheme && url.host == "document"
      && url.path == "/view.html"
  }
}

private final class SecureHTMLSchemeHandler: NSObject, WKURLSchemeHandler {
  private let lock = NSLock()
  private var html = ""
  private var directoryURL: URL?

  func update(html: String, directoryURL: URL) {
    lock.lock()
    self.html = html
    self.directoryURL = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
    lock.unlock()
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    lock.lock()
    let html = html
    let directoryURL = directoryURL
    lock.unlock()
    guard let url = urlSchemeTask.request.url,
      url.scheme?.lowercased() == SecureHTMLRenderer.scheme,
      url.host == "document", let directoryURL
    else {
      Task { @MainActor in
        OperatorDebugLog.record("html.scheme.invalidRequest", "request=\(urlSchemeTask.request.url?.absoluteString ?? "nil")", level: .warning)
      }
      urlSchemeTask.didFailWithError(CocoaError(.fileNoSuchFile))
      return
    }

    do {
      let data: Data
      let mimeType: String
      if url.path == "/view.html" {
        data = Data(html.utf8)
        mimeType = "text/html"
      } else {
        let relativePath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relativePath.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        let rawAssetURL = directoryURL.appendingPathComponent(relativePath)
        let safePath = try WorkspacePathPolicy.canonicalContainedPath(
          rawAssetURL.path, within: directoryURL.path)
        let assetURL = URL(fileURLWithPath: safePath)
        let values = try assetURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 10 * 1024 * 1024 else {
          throw CocoaError(.fileReadTooLarge)
        }
        data = try Data(contentsOf: assetURL, options: .mappedIfSafe)
        mimeType = Self.mimeType(for: assetURL.pathExtension)
      }
      let response = URLResponse(
        url: url, mimeType: mimeType, expectedContentLength: data.count,
        textEncodingName: mimeType.hasPrefix("text/") ? "utf-8" : nil)
      urlSchemeTask.didReceive(response)
      urlSchemeTask.didReceive(data)
      urlSchemeTask.didFinish()
      Task { @MainActor in
        OperatorDebugLog.record("html.scheme.served", "path=\(url.path) bytes=\(data.count)")
      }
    } catch {
      Task { @MainActor in
        OperatorDebugLog.record("html.scheme.failed", error.localizedDescription, level: .warning)
      }
      urlSchemeTask.didFailWithError(error)
    }
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

  private static func mimeType(for extensionName: String) -> String {
    switch extensionName.lowercased() {
    case "css": "text/css"
    case "js": "text/javascript"
    case "svg": "image/svg+xml"
    case "png": "image/png"
    case "jpg", "jpeg": "image/jpeg"
    case "gif": "image/gif"
    case "webp": "image/webp"
    case "woff": "font/woff"
    case "woff2": "font/woff2"
    default: "application/octet-stream"
    }
  }
}

struct SecureHTMLWebView: NSViewRepresentable {
  let content: String
  let path: String
  let revision: Int
  let colorScheme: ColorScheme

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.setURLSchemeHandler(
      context.coordinator.schemeHandler, forURLScheme: SecureHTMLRenderer.scheme)
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    let renderKey = "\(revision)-\(colorScheme == .dark ? "dark" : "light")"
    guard context.coordinator.renderKey != renderKey else { return }
    context.coordinator.beginRender(
      content: content, path: path, colorScheme: colorScheme, renderKey: renderKey, in: view)
  }

  final class Coordinator: NSObject, WKNavigationDelegate {
    fileprivate let schemeHandler = SecureHTMLSchemeHandler()
    var renderKey = ""
    private var renderTask: Task<Void, Never>?

    deinit { renderTask?.cancel() }

    func beginRender(
      content: String, path: String, colorScheme: ColorScheme, renderKey: String, in webView: WKWebView
    ) {
      renderTask?.cancel()
      self.renderKey = renderKey
      let directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
      let backgroundColor = colorScheme == .dark
        ? NSColor(srgbRed: 22 / 255, green: 27 / 255, blue: 34 / 255, alpha: 1)
        : NSColor(srgbRed: 246 / 255, green: 248 / 255, blue: 250 / 255, alpha: 1)
      renderTask = Task { [weak self, weak webView] in
        let html = await Task.detached(priority: .utility) {
          SecureHTMLRenderer.documentHTML(for: content, colorScheme: colorScheme)
        }.value
        guard !Task.isCancelled else { return }
        await MainActor.run {
          OperatorDebugLog.record("html.render.ready", "path=\(path) bytes=\(html.utf8.count)")
        }
        await MainActor.run {
          guard let self, let webView else { return }
          self.schemeHandler.update(html: html, directoryURL: directoryURL)
          webView.underPageBackgroundColor = backgroundColor
          webView.load(URLRequest(url: URL(string: "\(SecureHTMLRenderer.scheme)://document/view.html")!))
        }
      }
    }

    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      guard let url = navigationAction.request.url else {
        decisionHandler(.cancel)
        return
      }
      if navigationAction.navigationType == .linkActivated,
        SecureHTMLNavigationPolicy.allowsExternalOpen(url)
      {
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
      } else if SecureHTMLNavigationPolicy.allowsInternalDocumentLoad(url) {
        decisionHandler(.allow)
      } else {
        Task { @MainActor in
          OperatorDebugLog.record("html.navigation.blocked", "url=\(url.absoluteString)", level: .warning)
        }
        decisionHandler(.cancel)
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      Task { @MainActor in
        OperatorDebugLog.record("html.navigation.finished", "url=\(webView.url?.absoluteString ?? "nil")")
      }
      webView.evaluateJavaScript("document.body ? document.body.innerText.slice(0, 200) : '<no body>'") {
        value, error in
        Task { @MainActor in
          if let error {
            OperatorDebugLog.record("html.navigation.domFailed", error.localizedDescription, level: .warning)
          } else {
            OperatorDebugLog.record("html.navigation.domReady", "text=\(String(describing: value))")
          }
        }
      }
    }

    func webView(
      _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
      Task { @MainActor in
        OperatorDebugLog.record("html.navigation.failed", error.localizedDescription, level: .warning)
      }
    }

    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      Task { @MainActor in
        OperatorDebugLog.record("html.navigation.provisionalFailed", error.localizedDescription, level: .warning)
      }
    }
  }
}

struct ProjectFileNode: Identifiable, Hashable {
  let path: String
  let name: String
  let isDirectory: Bool
  let children: [ProjectFileNode]?
  let childrenLoaded: Bool
  let depth: Int

  var id: String { path }

  init(
    path: String, name: String, isDirectory: Bool, children: [ProjectFileNode]? = nil,
    childrenLoaded: Bool? = nil, depth: Int = 0
  ) {
    self.path = path
    self.name = name
    self.isDirectory = isDirectory
    self.children = children
    self.childrenLoaded = childrenLoaded ?? !isDirectory
    self.depth = depth
  }
}

enum FileNavigatorAccessError: LocalizedError {
  case notDirectory(String)
  case permissionDenied(String)

  var errorDescription: String? {
    switch self {
    case .notDirectory(let path):
      "The selected location is not a folder: \(path)"
    case .permissionDenied(let path):
      "Operator cannot read \(path). Choose the folder again, or allow Operator in System Settings → Privacy & Security."
    }
  }
}

enum FileNavigatorDirectoryPolicy {
  static func readableDirectory(_ rawPath: String, fileManager: FileManager = .default) throws
    -> URL
  {
    let url = URL(fileURLWithPath: rawPath, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
    else {
      throw FileNavigatorAccessError.notDirectory(url.path)
    }
    guard fileManager.isReadableFile(atPath: url.path) else {
      throw FileNavigatorAccessError.permissionDenied(url.path)
    }
    return url
  }

  static func parent(of rawPath: String) -> URL? {
    guard let directory = try? readableDirectory(rawPath) else { return nil }
    let parent = directory.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
    return parent.path == directory.path ? nil : parent
  }
}

/// Security-scoped URLs are supplied by NSOpenPanel in sandboxed builds. The current hardened
/// distribution is not sandboxed, but keeping this scope balanced lets the navigator behave
/// correctly if that changes and never prolongs a grant after the pane is closed or moved.
private final class FileNavigatorSecurityScope {
  private let url: URL
  private let didStartAccessing: Bool

  init(url: URL) {
    self.url = url
    didStartAccessing = url.startAccessingSecurityScopedResource()
  }

  func stop() {
    if didStartAccessing { url.stopAccessingSecurityScopedResource() }
  }

  deinit { stop() }
}

enum ProjectFileTreeLoader {
  static let ignoredDirectoryNames: Set<String> = [
    ".git", ".build", "DerivedData", "node_modules", ".swiftpm",
  ]
  static let maximumNodeCount = 8_000
  static let maximumDepth = 24

  static func load(root rawRoot: String, fileManager: FileManager = .default) throws
    -> [ProjectFileNode]
  {
    let root = try FileNavigatorDirectoryPolicy.readableDirectory(rawRoot, fileManager: fileManager)
    var remaining = maximumNodeCount
    return try enumerate(
      directory: root, rootPath: root.path, depth: 0, recursively: true, remaining: &remaining,
      fileManager: fileManager)
  }

  /// Loads only one directory level. Descendants are intentionally left unloaded until the
  /// user expands that folder, which keeps large repositories responsive at first render.
  static func loadLevel(
    root rawRoot: String, depth: Int = 0, fileManager: FileManager = .default
  ) throws -> [ProjectFileNode] {
    let root = try FileNavigatorDirectoryPolicy.readableDirectory(rawRoot, fileManager: fileManager)
    var remaining = maximumNodeCount
    return try enumerate(
      directory: root, rootPath: root.path, depth: depth, recursively: false, remaining: &remaining,
      fileManager: fileManager)
  }

  private struct DirectoryEntry {
    let url: URL
    let isDirectory: Bool
    let isRegularFile: Bool
    let isSymbolicLink: Bool
  }

  private static func enumerate(
    directory: URL, rootPath: String, depth: Int, recursively: Bool, remaining: inout Int,
    fileManager: FileManager
  ) throws -> [ProjectFileNode] {
    guard depth <= maximumDepth, remaining > 0 else { return [] }
    let entries = try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles])
      .compactMap { url -> DirectoryEntry? in
        guard !ignoredDirectoryNames.contains(url.lastPathComponent) else { return nil }
        let values = try? url.resourceValues(forKeys: [
          .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard let values else { return nil }
        return DirectoryEntry(
          url: url, isDirectory: values.isDirectory == true,
          isRegularFile: values.isRegularFile == true, isSymbolicLink: values.isSymbolicLink == true)
      }
      .sorted {
        if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
        return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent)
          == .orderedAscending
      }

    return try entries.compactMap { entry in
      guard remaining > 0, !entry.isSymbolicLink else { return nil }
      let safePath = try WorkspacePathPolicy.canonicalContainedPath(
        entry.url.path, within: rootPath)
      remaining -= 1
      guard entry.isDirectory || entry.isRegularFile else { return nil }
      if entry.isDirectory {
        if recursively {
          let children = try enumerate(
            directory: entry.url, rootPath: rootPath, depth: depth + 1, recursively: true,
            remaining: &remaining, fileManager: fileManager)
          return ProjectFileNode(
            path: safePath, name: entry.url.lastPathComponent, isDirectory: true,
            children: children, childrenLoaded: true, depth: depth + 1)
        }
        return ProjectFileNode(
          path: safePath, name: entry.url.lastPathComponent, isDirectory: true,
          children: nil, childrenLoaded: false, depth: depth + 1)
      }
      return ProjectFileNode(
        path: safePath, name: entry.url.lastPathComponent, isDirectory: false,
        children: nil, childrenLoaded: true, depth: depth + 1)
    }
  }

  static func filtering(_ nodes: [ProjectFileNode], query: String) -> [ProjectFileNode] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return nodes }
    return nodes.compactMap { node in
      if node.name.localizedCaseInsensitiveContains(needle) { return node }
      guard node.isDirectory, let children = node.children else { return nil }
      let matches = filtering(children, query: needle)
      guard !matches.isEmpty else { return nil }
      return ProjectFileNode(
        path: node.path, name: node.name, isDirectory: true, children: matches,
        childrenLoaded: true, depth: node.depth)
    }
  }
}

/// Indexed Git decorations avoid scanning every changed path for every visible tree row.
struct ProjectFileGitIndex {
  private let files: [String: GitChangedFile]
  private let changedDirectories: Set<String>

  init(changes: [GitChangedFile]) {
    var files: [String: GitChangedFile] = [:]
    var directories = Set<String>()
    for change in changes {
      files[change.path] = change
      var directory = (change.path as NSString).deletingLastPathComponent
      while !directory.isEmpty && directory != "." && directory != "/" {
        directories.insert(directory)
        let parent = (directory as NSString).deletingLastPathComponent
        guard parent != directory else { break }
        directory = parent
      }
      directories.insert("")
    }
    self.files = files
    changedDirectories = directories
  }

  func decoration(for node: ProjectFileNode, root: String) -> (label: String, color: Color)? {
    let rootPath = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
    let nodePath = URL(fileURLWithPath: node.path).standardizedFileURL.path
    let relative = nodePath == rootPath
      ? ""
      : String(nodePath.dropFirst(rootPath.hasSuffix("/") ? rootPath.count : rootPath.count + 1))
    if let change = files[relative] {
      if change.section == .untracked { return ("U", .green) }
      switch change.status {
      case "A": return ("A", .green)
      case "D": return ("D", .red)
      case "R": return ("R", .purple)
      default: return ("M", .orange)
      }
    }
    return node.isDirectory && changedDirectories.contains(relative) ? ("•", .orange) : nil
  }
}

struct ProjectFileNavigator: View {
  let root: String
  let openFile: (String) -> Void
  let close: () -> Void
  let fileWatchingEnabled: Bool
  @State private var currentRoot: String
  @State private var nodes: [ProjectFileNode] = []
  @State private var searchResults: [ProjectFileNode]?
  @State private var changes: [GitChangedFile] = []
  @State private var gitIndex = ProjectFileGitIndex(changes: [])
  @State private var query = ""
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var revision = 0
  @State private var refreshRevision = 0
  @State private var repositoryRoot: String?
  @State private var gitObservation: GitWorkspaceObservation?
  @State private var changesExpanded = true
  @State private var securityScope: FileNavigatorSecurityScope?

  init(
    root: String, openFile: @escaping (String) -> Void, close: @escaping () -> Void,
    fileWatchingEnabled: Bool = true
  ) {
    self.root = root
    self.openFile = openFile
    self.close = close
    self.fileWatchingEnabled = fileWatchingEnabled
    _currentRoot = State(initialValue: root)
  }

  private var parentDirectory: URL? { FileNavigatorDirectoryPolicy.parent(of: currentRoot) }

  private var visibleNodes: [ProjectFileNode] {
    query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nodes : (searchResults ?? [])
  }

  private var uniqueChanges: [GitChangedFile] {
    var paths = Set<String>()
    return changes.filter { paths.insert($0.path).inserted }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "folder")
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 1) {
          Text(URL(fileURLWithPath: currentRoot).lastPathComponent)
            .font(.body.weight(.semibold))
            .lineLimit(1)
          if !changes.isEmpty {
            Text("\(Set(changes.map(\.path)).count) changed")
              .font(.callout)
              .foregroundStyle(.orange)
          }
        }
        .frame(minHeight: FileNavigatorChrome.headerContentHeight, alignment: .leading)
        Spacer()
        Button {
          if let parentDirectory { navigate(to: parentDirectory) }
        } label: {
          Image(systemName: "arrow.up")
        }
        .buttonStyle(.borderless)
        .disabled(parentDirectory == nil)
        .help("Go to parent folder")
        .fastTooltip("Go to parent folder")
        .accessibilityIdentifier("operator.fileNavigator.up")
        Button {
          chooseFolder()
        } label: {
          Image(systemName: "folder.badge.plus")
        }
        .buttonStyle(.borderless)
        .help("Choose a folder to browse")
        .fastTooltip("Choose a folder to browse")
        .accessibilityIdentifier("operator.fileNavigator.chooseFolder")
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: currentRoot)])
        } label: {
          Image(systemName: "arrow.forward.square")
        }
        .buttonStyle(.borderless)
        .help("Reveal project in Finder")
        .fastTooltip("Reveal project in Finder")
        Button {
          revision &+= 1
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Refresh files")
        .fastTooltip("Refresh files")
        Button(action: close) {
          Image(systemName: "sidebar.trailing")
            .frame(
              width: FileNavigatorChrome.controlSize,
              height: FileNavigatorChrome.controlSize
            )
        }
        .buttonStyle(.borderless)
        .help("Hide file navigator")
        .fastTooltip("Hide file navigator")
        .accessibilityIdentifier("operator.fileNavigator.close")
      }
      .padding(FileNavigatorChrome.headerInset)

      TextField("Filter files", text: $query)
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 10)
        .padding(.bottom, 9)
        .accessibilityIdentifier("operator.fileNavigator.filter")

      Divider()

      if isLoading {
        VStack(spacing: 10) {
          ProgressView()
          Text("Loading files…").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let errorMessage {
        ContentUnavailableView(
          "Files unavailable", systemImage: "folder.badge.questionmark",
          description: Text(errorMessage))
      } else if visibleNodes.isEmpty {
        ContentUnavailableView(
          query.isEmpty ? "No files" : "No matches",
          systemImage: query.isEmpty ? "folder" : "line.3.horizontal.decrease.circle")
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 1) {
            if !uniqueChanges.isEmpty, query.isEmpty {
              DisclosureGroup(isExpanded: $changesExpanded) {
                ForEach(uniqueChanges) { change in
                  let absolutePath = URL(
                    fileURLWithPath: repositoryRoot ?? currentRoot, isDirectory: true
                  ).appendingPathComponent(change.path).path
                  Button {
                    if FileManager.default.isReadableFile(atPath: absolutePath) {
                      openFile(absolutePath)
                    }
                  } label: {
                    HStack(spacing: 6) {
                      Text(gitLabel(change))
                        .font(.callout.bold())
                        .foregroundStyle(gitColor(change))
                        .frame(width: 14)
                      Text(change.path)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                      Spacer()
                    }
                    .padding(.vertical, 3)
                  }
                  .buttonStyle(.plain)
                  .disabled(!FileManager.default.fileExists(atPath: absolutePath))
                  .contextMenu {
                    Button("Reveal in Finder") {
                      let revealURL =
                        FileManager.default.fileExists(atPath: absolutePath)
                        ? URL(fileURLWithPath: absolutePath)
                        : URL(fileURLWithPath: absolutePath).deletingLastPathComponent()
                      NSWorkspace.shared.activateFileViewerSelecting([revealURL])
                    }
                  }
                }
              } label: {
                Label("Changes", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                  .font(.callout.weight(.semibold))
                  .foregroundStyle(.secondary)
              }
              Divider().padding(.vertical, 5)
            }
            ForEach(visibleNodes) { node in
              ProjectFileTreeNodeView(
                node: node, root: repositoryRoot ?? currentRoot, gitIndex: gitIndex,
                refreshRevision: refreshRevision, openFile: openFile, depth: 0,
                loadChildren: loadChildren)
            }
          }
          .padding(.horizontal, 7)
          .padding(.vertical, 6)
        }
      }
    }
    .background(.bar)
    .task(id: "\(currentRoot)#\(revision)#\(fileWatchingEnabled)") {
      await reload()
    }
    .task(id: "\(currentRoot)#search#\(query)") {
      guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        searchResults = nil
        return
      }
      do {
        try await Task.sleep(for: .milliseconds(150))
      } catch {
        return
      }
      let root = currentRoot
      let query = query
      let result = await Task.detached(priority: .utility) {
        guard let allNodes = try? ProjectFileTreeLoader.load(root: root)
        else { return [ProjectFileNode]() }
        return ProjectFileTreeLoader.filtering(allNodes, query: query)
      }.value
      guard !Task.isCancelled else { return }
      searchResults = result
    }
    .onChange(of: root) { _, newRoot in
      navigate(to: URL(fileURLWithPath: newRoot, isDirectory: true))
    }
    .onDisappear {
      gitObservation = nil
      securityScope?.stop()
      securityScope = nil
    }
  }

  private func gitLabel(_ change: GitChangedFile) -> String {
    if change.section == .untracked { return "U" }
    switch change.status {
    case "A": return "A"
    case "D": return "D"
    case "R": return "R"
    default: return "M"
    }
  }

  private func gitColor(_ change: GitChangedFile) -> Color {
    switch gitLabel(change) {
    case "A", "U": .green
    case "D": .red
    case "R": .purple
    default: .orange
    }
  }

  private func reload() async {
    isLoading = true
    errorMessage = nil
    let root = currentRoot
    OperatorDebugLog.record("fileNavigator.load.begin", "root=\(root)")
    let result = await Task.detached(priority: .utility) {
      Result { try ProjectFileTreeLoader.loadLevel(root: root) }
    }.value
    guard !Task.isCancelled, root == currentRoot else { return }
    switch result {
    case .success(let loaded):
      nodes = loaded
      searchResults = nil
      isLoading = false
      OperatorDebugLog.record(
        "fileNavigator.load.filesReady", "root=\(root) entries=\(loaded.count)")
    case .failure(let error):
      nodes = []
      searchResults = nil
      errorMessage = error.localizedDescription
      isLoading = false
      OperatorDebugLog.record(
        "fileNavigator.load.failed", error.localizedDescription, level: .warning,
        metadata: ["root": root])
      return
    }

    // Give SwiftUI a frame to present the directory before optional Git decoration begins.
    // Repository inspection is supplementary and must never keep the navigator in its loading
    // state during app restoration.
    do {
      try await Task.sleep(for: .milliseconds(120))
    } catch {
      return
    }
    guard !Task.isCancelled, root == currentRoot else { return }
    let git = await Task.detached(priority: .utility) {
      guard GitRepository.isRepository(containing: root),
        let repositoryRoot = try? GitRepository.repositoryRoot(containing: root)
      else { return (root: Optional<String>.none, changes: [GitChangedFile]()) }
      return (
        root: Optional(repositoryRoot),
        changes: (try? GitRepository.status(in: repositoryRoot)) ?? []
      )
    }.value
    guard !Task.isCancelled, root == currentRoot else { return }
    repositoryRoot = git.root
    changes = git.changes
    gitIndex = ProjectFileGitIndex(changes: git.changes)
    OperatorDebugLog.record(
      "fileNavigator.load.gitReady",
      "root=\(root) repository=\(git.root != nil) changes=\(git.changes.count)")
    gitObservation =
      fileWatchingEnabled
      ? git.root.map { repositoryRoot in
        GitWorkspaceMonitor.shared.observe(rootPath: repositoryRoot) { snapshot in
          Task { @MainActor in
            let previousPaths = Set(changes.map(\.path))
            let updatedPaths = Set(snapshot.changes.map(\.path))
            changes = snapshot.changes
            gitIndex = ProjectFileGitIndex(changes: snapshot.changes)
            refreshRevision &+= 1
            if previousPaths != updatedPaths {
              scheduleCurrentLevelRefresh(root: root)
            }
          }
        }
      } : nil
  }

  private func navigate(to rawURL: URL) {
    do {
      let directory = try FileNavigatorDirectoryPolicy.readableDirectory(rawURL.path)
      guard directory.path != currentRoot else { return }
      securityScope?.stop()
      securityScope = FileNavigatorSecurityScope(url: directory)
      currentRoot = directory.path
      query = ""
      nodes = []
      searchResults = nil
      changes = []
      gitIndex = ProjectFileGitIndex(changes: [])
      repositoryRoot = nil
      gitObservation = nil
      revision &+= 1
    } catch {
      errorMessage = error.localizedDescription
      isLoading = false
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.prompt = "Browse"
    panel.message = "Choose a folder for Operator’s file navigator."
    panel.directoryURL = URL(fileURLWithPath: currentRoot, isDirectory: true)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    navigate(to: url)
  }

  private func scheduleCurrentLevelRefresh(root: String) {
    let expectedRevision = refreshRevision
    Task.detached(priority: .utility) {
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled else { return }
      let refreshed = try? ProjectFileTreeLoader.loadLevel(root: root)
      await MainActor.run {
        guard expectedRevision == refreshRevision, let refreshed else { return }
        nodes = refreshed
      }
    }
  }

  private func loadChildren(_ path: String, depth: Int) async -> [ProjectFileNode] {
    (try? await Task.detached(priority: .utility) {
      try ProjectFileTreeLoader.loadLevel(root: path, depth: depth)
    }.value) ?? []
  }
}

private struct ProjectFileTreeNodeView: View {
  let node: ProjectFileNode
  let root: String
  let gitIndex: ProjectFileGitIndex
  let refreshRevision: Int
  let openFile: (String) -> Void
  let depth: Int
  let loadChildren: (String, Int) async -> [ProjectFileNode]
  @State private var isExpanded = false
  @State private var loadedChildren: [ProjectFileNode]?
  @State private var isLoadingChildren = false

  private var children: [ProjectFileNode] {
    loadedChildren ?? node.children ?? []
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      if node.isDirectory {
        Button {
          let shouldLoad = !isExpanded && !node.childrenLoaded && loadedChildren == nil
          withAnimation(.easeInOut(duration: 0.16)) {
            isExpanded.toggle()
          }
          if shouldLoad {
            loadDirectoryChildren()
          }
        } label: {
          nodeRow
        }
        .buttonStyle(.plain)
        .contextMenu { revealButton }
        if isExpanded, isLoadingChildren {
          ProgressView()
            .controlSize(.small)
            .padding(.leading, CGFloat(depth + 1) * 18 + 22)
            .padding(.vertical, 4)
        }
        if isExpanded, !children.isEmpty {
          ForEach(children) { child in
            ProjectFileTreeNodeView(
              node: child, root: root, gitIndex: gitIndex, refreshRevision: refreshRevision,
              openFile: openFile, depth: depth + 1, loadChildren: loadChildren)
          }
        }
      } else {
        Button {
          openFile(node.path)
        } label: {
          nodeRow
        }
        .buttonStyle(.plain)
        .contextMenu { revealButton }
      }
    }
    .onChange(of: refreshRevision) { _, _ in
      guard isExpanded, !node.childrenLoaded else { return }
      loadDirectoryChildren()
    }
  }

  private func loadDirectoryChildren() {
    guard !isLoadingChildren else { return }
    isLoadingChildren = true
    let path = node.path
    let depth = node.depth + 1
    Task {
      let result = await loadChildren(path, depth)
      guard !Task.isCancelled else { return }
      loadedChildren = result
      isLoadingChildren = false
    }
  }

  private var nodeRow: some View {
    HStack(spacing: 0) {
      ForEach(0..<depth, id: \.self) { _ in
        // Preserve the readable hierarchy without drawing persistent guide rails.
        // The extra width matches the former guide column so child rows do not jump.
        Color.clear.frame(width: 18, height: 28)
      }
      Group {
        if node.isDirectory {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .foregroundStyle(.secondary)
        } else {
          Color.clear
        }
      }
      .frame(width: 16, height: 16)
      HStack(spacing: 7) {
        Image(systemName: node.isDirectory ? "folder" : fileSymbol)
          .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
          .frame(width: 18)
        Text(node.name)
          .font(.callout)
          .lineLimit(1)
        Spacer(minLength: 4)
        if let decoration = gitIndex.decoration(for: node, root: root) {
          Text(decoration.label)
            .font(.callout.bold())
            .foregroundStyle(decoration.color)
        }
      }
      .padding(.leading, 3)
    }
    .padding(.vertical, 4)
    .padding(.trailing, 5)
    .contentShape(Rectangle())
  }

  @ViewBuilder private var revealButton: some View {
    Button("Reveal in Finder") {
      NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
    }
  }

  private var fileSymbol: String {
    switch URL(fileURLWithPath: node.path).pathExtension.lowercased() {
    case "swift": "swift"
    case "md", "markdown", "mdx": "doc.richtext"
    case "json", "yaml", "yml", "toml": "curlybraces"
    case "png", "jpg", "jpeg", "gif", "heic": "photo"
    default: "doc.text"
    }
  }

}

struct ProjectFileViewer: View {
  let path: String
  let workspaceDirectory: String
  let isFocused: Bool
  let showsFocusIndicator: Bool
  let select: () -> Void
  let close: () -> Void
  let onDeleted: () -> Void
  let fileWatchingEnabled: Bool
  @Environment(\.colorScheme) private var colorScheme
  @State private var content = ""
  @State private var diffContent: String?
  @State private var previewWasTruncated = false
  @State private var errorMessage: String?
  @State private var githubURL: URL?
  @State private var revision = 0
  @State private var deletionReported = false
  @State private var presentationMode: PresentationMode = .raw

  init(
    path: String, workspaceDirectory: String, isFocused: Bool, showsFocusIndicator: Bool,
    select: @escaping () -> Void, close: @escaping () -> Void, onDeleted: @escaping () -> Void,
    fileWatchingEnabled: Bool
  ) {
    self.path = path
    self.workspaceDirectory = workspaceDirectory
    self.isFocused = isFocused
    self.showsFocusIndicator = showsFocusIndicator
    self.select = select
    self.close = close
    self.onDeleted = onDeleted
    self.fileWatchingEnabled = fileWatchingEnabled
    // Code and text files open on the pending diff when one exists. HTML opens in its
    // rendered presentation; switching to Diff is always an explicit user action so a
    // change set can never replace the rendered HTML unexpectedly.
    _presentationMode = State(
      initialValue: HTMLFile.isSupported(path: path) ? .rendered : .diff)
  }

  private enum PresentationMode: String, CaseIterable, Identifiable {
    case diff = "Diff"
    case raw = "Raw"
    case rendered = "Rendered"
    case source = "Source"

    var id: String { rawValue }
  }

  private var isHTML: Bool { HTMLFile.isSupported(path: path) }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "doc.text")
          .foregroundStyle(.tint)
        Text(URL(fileURLWithPath: path).lastPathComponent)
          .font(.callout.weight(.semibold))
          .lineLimit(1)
        Text(path)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        if previewWasTruncated {
          Label("Preview truncated", systemImage: "scissors")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fastTooltip("Only the first 1 MB is shown")
        }
        Spacer()
        let presentationModes = availablePresentationModes
        if presentationModes.count > 1 {
          Picker("File presentation", selection: $presentationMode) {
            ForEach(presentationModes) { mode in
              Text(mode.rawValue).tag(mode)
            }
          }
          .pickerStyle(.segmented)
          .frame(width: isHTML ? 236 : 132)
          .labelsHidden()
          .accessibilityIdentifier("operator.fileViewer.presentation")
        }
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } label: {
          Image(systemName: "arrow.forward.square")
        }
        .help("Reveal in Finder")
        .fastTooltip("Reveal in Finder")
        Button {
          revision &+= 1
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("Reload file")
        .fastTooltip("Reload file")
        Button(action: close) {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Close file pane")
        .fastTooltip("Close file pane")
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(.bar)
      .fixedSize(horizontal: false, vertical: true)
      .layoutPriority(1)
      Divider()

      if let errorMessage {
        unsupportedFileView(errorMessage)
      } else if presentationMode == .diff, let diffContent {
        diffEditor(diffContent)
      } else if isHTML, presentationMode == .rendered {
        SecureHTMLWebView(
          content: content, path: path, revision: revision, colorScheme: colorScheme
        )
        .id("html-preview:\(path):\(revision)")
        .overlay(alignment: .topTrailing) { externalActions }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      } else {
        sourceEditor
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: select)
    .paneFocusIndicator(isFocused && showsFocusIndicator, color: .accentColor)
    .task(id: "\(path)#\(revision)") { await load() }
    .task(id: "\(path)#\(fileWatchingEnabled)") {
      if fileWatchingEnabled { await monitorFileChanges() }
    }
  }

  private var availablePresentationModes: [PresentationMode] {
    if isHTML {
      return diffContent == nil ? [.rendered, .source] : [.diff, .rendered, .source]
    }
    return diffContent == nil ? [] : [.diff, .raw]
  }

  private func unsupportedFileView(_ message: String) -> some View {
    VStack(spacing: 18) {
      Image(systemName: "doc.questionmark")
        .font(.system(size: 34, weight: .medium))
        .foregroundStyle(.secondary)
      VStack(spacing: 7) {
        Text("Cannot preview file")
          .font(.title2.weight(.semibold))
        Text(message)
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 480)
      }
      HStack(spacing: 10) {
        Button {
          revealInFinder()
        } label: {
          Label("Reveal in Finder", systemImage: "folder")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("operator.fileViewer.revealInFinder")

        Button {
          NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } label: {
          Label("Open with Default App", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("operator.fileViewer.openExternally")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func revealInFinder() {
    let url = FileManager.default.fileExists(atPath: path)
      ? URL(fileURLWithPath: path)
      : URL(fileURLWithPath: path).deletingLastPathComponent()
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  private var sourceEditor: some View {
    GeometryReader { viewport in
      ScrollView([.horizontal, .vertical]) {
        HStack(alignment: .top, spacing: 0) {
          Text(SourceEditorPresentation.lineNumbers(for: content))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.trailing)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 14)
            .frame(minHeight: viewport.size.height, alignment: .topTrailing)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            .accessibilityHidden(true)
          Rectangle()
            .fill(.separator)
            .frame(width: 1)
          Text(highlightedSource)
            .textSelection(.enabled)
            .padding(.leading, 14)
            .padding(.trailing, 80)
            .padding(.vertical, 14)
            .frame(minHeight: viewport.size.height, alignment: .topLeading)
        }
        .font(.system(.body, design: .monospaced))
        .fixedSize(horizontal: true, vertical: false)
        .frame(
          minWidth: viewport.size.width, minHeight: viewport.size.height,
          alignment: .topLeading)
      }
      .defaultScrollAnchor(.topLeading)
      .background(Color(nsColor: .textBackgroundColor))
      .overlay(alignment: .topTrailing) { externalActions }
    }
  }

  private var highlightedSource: AttributedString {
    // Regex-based highlighting is intentionally skipped for larger previews. Rendering a plain
    // monospaced string keeps generated logs and minified source responsive.
    guard content.utf8.count <= FilePreviewLimits.maximumRenderableBytes else {
      return AttributedString(content)
    }
    return CodeSyntaxHighlighter.highlight(content, path: path, colorScheme: colorScheme)
  }

  private func diffEditor(_ diff: String) -> some View {
    GeometryReader { viewport in
      ScrollView([.horizontal, .vertical]) {
        HStack(alignment: .top, spacing: 0) {
          Text(SourceEditorPresentation.lineNumbers(for: diff))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.trailing)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 14)
            .frame(minHeight: viewport.size.height, alignment: .topTrailing)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            .accessibilityHidden(true)
          Rectangle()
            .fill(.separator)
            .frame(width: 1)
          Text(DiffSyntaxHighlighter.highlight(diff, colorScheme: colorScheme))
            .textSelection(.enabled)
            .padding(.leading, 14)
            .padding(.trailing, 80)
            .padding(.vertical, 14)
            .frame(minHeight: viewport.size.height, alignment: .topLeading)
        }
        .font(.system(.body, design: .monospaced))
        .fixedSize(horizontal: true, vertical: false)
        .frame(
          minWidth: viewport.size.width, minHeight: viewport.size.height,
          alignment: .topLeading)
      }
      .defaultScrollAnchor(.topLeading)
      .background(Color(nsColor: .textBackgroundColor))
      .overlay(alignment: .topTrailing) { externalActions }
    }
  }

  @ViewBuilder
  private var externalActions: some View {
    HStack(spacing: 8) {
      Button {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
      } label: {
        Image(systemName: "arrow.up.right.square")
          .frame(width: 18, height: 18)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .help("Open this file with the default app")
      .accessibilityLabel("Open with Default App")
      .accessibilityIdentifier("operator.fileViewer.openExternally")
      .fastTooltip("Open with Default App")

      Button {
        SourceFileExternalLauncher.openInVisualStudioCode(path)
      } label: {
        Image(systemName: "chevron.left.forwardslash.chevron.right")
          .frame(width: 18, height: 18)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(!SourceFileExternalLauncher.isVisualStudioCodeAvailable)
      .help(
        SourceFileExternalLauncher.isVisualStudioCodeAvailable
          ? "Open this local file in Visual Studio Code"
          : "Visual Studio Code is not installed"
      )
      .accessibilityLabel("Open in Visual Studio Code")
      .accessibilityIdentifier("operator.fileViewer.openInVSCode")
      .fastTooltip("Open in Visual Studio Code")

      if let githubURL {
        Button {
          NSWorkspace.shared.open(githubURL)
        } label: {
          Image(systemName: "arrow.up.right.square")
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .help(githubURL.absoluteString)
        .accessibilityLabel("Open on GitHub")
        .accessibilityIdentifier("operator.fileViewer.openOnGitHub")
        .fastTooltip("Open on GitHub")
      }
    }
    .padding(14)
  }

  private func monitorFileChanges() async {
    var previous = OpenFileSnapshot.capture(path)
    var previousGitFingerprint = await gitChangeFingerprint()
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: .milliseconds(900))
      } catch {
        return
      }
      let current = OpenFileSnapshot.capture(path)
      let currentGitFingerprint = await gitChangeFingerprint()
      guard current != previous || currentGitFingerprint != previousGitFingerprint else { continue }
      previous = current
      previousGitFingerprint = currentGitFingerprint
      if current.exists {
        deletionReported = false
        revision &+= 1
      } else if !deletionReported {
        deletionReported = true
        revision &+= 1
        onDeleted()
      }
    }
  }

  private func gitChangeFingerprint() async -> String? {
    let path = path
    return await Task.detached(priority: .utility) {
      guard let root = try? GitRepository.repositoryRoot(containing: path),
        let changes = try? GitRepository.status(in: root)
      else { return nil }
      let rootURL = URL(fileURLWithPath: root, isDirectory: true)
      let relativePath = String(
        path.dropFirst(rootURL.path.hasSuffix("/") ? root.count : root.count + 1))
      let matching = changes.filter { $0.path == relativePath }
      guard !matching.isEmpty else { return nil }
      return matching.map { $0.id + ":" + $0.status }.joined(separator: "|")
    }.value
  }

  private func load() async {
    let path = path
    let workspaceDirectory = workspaceDirectory
    let fileResult = await Task.detached(priority: .utility) {
      Result { () throws -> ProjectFileContentPayload in
        let safePath = try WorkspacePathPolicy.canonicalContainedPath(
          path, within: workspaceDirectory)
        let url = URL(fileURLWithPath: safePath)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard (values.fileSize ?? 0) <= FilePreviewLimits.maximumTextBytes else {
          throw NSError(
            domain: "OperatorFileViewer", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "File exceeds the 5 MB preview limit."])
        }
        guard let value = try String(contentsOf: url, encoding: .utf8) as String? else {
          throw MarkdownViewerError.invalidText
        }
        let preview = FilePreviewLimits.boundedPreview(value)
        return ProjectFileContentPayload(
          safePath: safePath,
          content: preview.content,
          previewWasTruncated: preview.isTruncated,
          fileSize: UInt64(values.fileSize ?? 0))
      }
    }.value
    switch fileResult {
    case .success(let payload):
      content = payload.content
      previewWasTruncated = payload.previewWasTruncated
      diffContent = nil
      githubURL = nil
      presentationMode = isHTML ? .rendered : .raw
      errorMessage = nil

      // Git is deliberately best-effort and independent from opening the file. A slow repo,
      // disconnected worktree, or large pending patch must not hold the file viewer hostage.
      let safePath = payload.safePath
      let fileSize = payload.fileSize
      let metadata = await Task.detached(priority: .utility) {
        guard fileSize <= FilePreviewLimits.maximumRenderableBytes else {
          return ProjectFileMetadataPayload(diffContent: nil, githubURL: nil)
        }
        let diff = (try? GitRepository.diff(for: safePath)).map {
          FilePreviewLimits.boundedPreview($0).content
        }
        return ProjectFileMetadataPayload(
          diffContent: diff, githubURL: GitRepository.githubFileURL(for: safePath))
      }.value
      guard !Task.isCancelled else { return }
      diffContent = metadata.diffContent
      githubURL = metadata.githubURL
      if !isHTML, metadata.diffContent != nil {
        presentationMode = .diff
      }
    case .failure(let error):
      content = ""
      previewWasTruncated = false
      diffContent = nil
      githubURL = nil
      errorMessage = error.localizedDescription
    }
  }
}

private struct ProjectFileContentPayload: Sendable {
  let safePath: String
  let content: String
  let previewWasTruncated: Bool
  let fileSize: UInt64
}

private struct ProjectFileMetadataPayload: Sendable {
  let diffContent: String?
  let githubURL: URL?
}

struct OpenFileSnapshot: Equatable, Sendable {
  let exists: Bool
  let modificationDate: Date?
  let fileSize: UInt64?

  static func capture(_ path: String, fileManager: FileManager = .default) -> Self {
    guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
      return Self(exists: false, modificationDate: nil, fileSize: nil)
    }
    return Self(
      exists: true,
      modificationDate: attributes[.modificationDate] as? Date,
      fileSize: (attributes[.size] as? NSNumber)?.uint64Value)
  }
}

enum SourceEditorPresentation {
  static func lineNumbers(for source: String) -> String {
    let count = max(1, source.split(separator: "\n", omittingEmptySubsequences: false).count)
    return (1...count).map(String.init).joined(separator: "\n")
  }
}

@MainActor
enum SourceFileExternalLauncher {
  static let visualStudioCodeBundleIdentifier = "com.microsoft.VSCode"

  static var isVisualStudioCodeAvailable: Bool {
    visualStudioCodeApplicationURL != nil
  }

  static func openInVisualStudioCode(_ path: String) {
    guard let applicationURL = visualStudioCodeApplicationURL else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.open(
      [URL(fileURLWithPath: path).standardizedFileURL], withApplicationAt: applicationURL,
      configuration: configuration)
  }

  private static var visualStudioCodeApplicationURL: URL? {
    NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: visualStudioCodeBundleIdentifier)
  }
}

enum CodeSyntaxHighlighter {
  static func highlight(_ source: String, path: String, colorScheme: ColorScheme)
    -> AttributedString
  {
    let attributed = NSMutableAttributedString(string: source)
    let fullRange = NSRange(location: 0, length: attributed.length)
    let palette =
      colorScheme == .dark
      ? (
        keyword: NSColor.systemPurple, string: NSColor.systemGreen,
        comment: NSColor.systemGray, number: NSColor.systemOrange
      )
      : (
        keyword: NSColor.systemIndigo, string: NSColor.systemRed,
        comment: NSColor.systemGray, number: NSColor.systemOrange
      )

    func apply(_ pattern: String, color: NSColor, options: NSRegularExpression.Options = []) {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
      regex.enumerateMatches(in: source, range: fullRange) { match, _, _ in
        guard let range = match?.range else { return }
        attributed.addAttribute(.foregroundColor, value: color, range: range)
      }
    }

    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    let hashComments = ["py", "rb", "sh", "zsh", "fish", "yaml", "yml", "toml"].contains(ext)
    let clojure = ["clj", "cljs", "cljc", "edn"].contains(ext)
    apply(
      #"\b(?:actor|and|as|async|await|break|case|catch|class|cond|const|continue|default|def|defer|defn|do|doseq|else|enum|export|extension|false|final|filter|fn|for|func|function|guard|if|import|in|interface|let|loop|map|nil|ns|null|or|private|protocol|public|recur|reduce|require|return|some|static|struct|switch|throw|throws|true|try|typealias|var|when|while)\b"#,
      color: palette.keyword)
    apply(#"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#, color: palette.number)
    apply(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, color: palette.string)
    if clojure {
      apply(#"(?<![\w-]):[A-Za-z][\w*+!_?<>\-./]*"#, color: palette.keyword)
    }
    apply(
      clojure
        ? #"(?m);.*$"#
        : (hashComments ? #"(?m)#.*$"# : #"(?m)//.*$|/\*[\s\S]*?\*/"#),
      color: palette.comment)
    return AttributedString(attributed)
  }
}

enum DiffSyntaxHighlighter {
  static func highlight(_ source: String, colorScheme: ColorScheme) -> AttributedString {
    let result = NSMutableAttributedString()
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let colors: (text: NSColor, addition: NSColor, deletion: NSColor, hunk: NSColor, metadata: NSColor) =
      colorScheme == .dark
      ? (
        text: .textColor, addition: .systemGreen, deletion: .systemRed,
        hunk: .systemPurple, metadata: .systemBlue
      )
      : (
        text: .textColor, addition: .systemGreen, deletion: .systemRed,
        hunk: .systemIndigo, metadata: .systemBlue
      )

    for line in lines {
      let isAddition = line.hasPrefix("+") && !line.hasPrefix("+++")
      let isDeletion = line.hasPrefix("-") && !line.hasPrefix("---")
      let isHunk = line.hasPrefix("@@")
      let isMetadata = line.hasPrefix("diff ") || line.hasPrefix("index ")
        || line.hasPrefix("---") || line.hasPrefix("+++")
      let color =
        isAddition ? colors.addition
        : isDeletion ? colors.deletion
        : isHunk ? colors.hunk
        : isMetadata ? colors.metadata
        : colors.text
      var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
      if isAddition {
        attributes[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.12)
      } else if isDeletion {
        attributes[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.12)
      } else if isHunk {
        attributes[.backgroundColor] = NSColor.systemPurple.withAlphaComponent(0.10)
      }
      result.append(NSAttributedString(string: line + "\n", attributes: attributes))
    }
    return AttributedString(result)
  }
}
