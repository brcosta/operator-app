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
  @Environment(\.colorScheme) private var colorScheme

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
    context.coordinator.revision = document.revision
    context.coordinator.palette = palette
    context.coordinator.load(
      html: MarkdownRenderer.documentHTML(for: document.content, colorScheme: colorScheme),
      baseURL: document.directoryURL,
      backgroundColor: palette.backgroundColor,
      in: view)
  }
  final class Coordinator: NSObject, WKNavigationDelegate {
    var revision = -1
    var palette: MarkdownPalette?
    private var documentHTML = ""
    private var documentBaseURL: URL?
    private var backgroundColor = NSColor.clear
    private var retriedAfterProcessTermination = false

    func shouldReload(revision: Int, palette: MarkdownPalette) -> Bool {
      self.revision != revision || self.palette != palette
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

  static func documentHTML(for source: String, colorScheme: ColorScheme) -> String {
    let palette =
      colorScheme == .dark
      ? (background: "#161b22", foreground: "#e6edf3")
      : (background: "#f6f8fa", foreground: "#24292f")
    let securityHead = """
      <meta charset="utf-8">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; connect-src 'none'; object-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'; img-src \(scheme): data:; style-src 'unsafe-inline' \(scheme):; font-src \(scheme): data:; media-src \(scheme):">
      <style>:root { color-scheme: \(colorScheme == .dark ? "dark" : "light"); } html, body { min-height: 100%; } body { margin: 20px; background: \(palette.background); color: \(palette.foreground); font: -apple-system-body; }</style>
      """
    if let range = source.range(
      of: #"<head\b[^>]*>"#, options: [.regularExpression, .caseInsensitive])
    {
      var document = source
      document.insert(contentsOf: securityHead, at: range.upperBound)
      return document
    }
    if let range = source.range(
      of: #"<html\b[^>]*>"#, options: [.regularExpression, .caseInsensitive])
    {
      var document = source
      document.insert(contentsOf: "<head>\(securityHead)</head>", at: range.upperBound)
      return document
    }
    return "<!doctype html><html><head>\(securityHead)</head><body>\(source)</body></html>"
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
    } catch {
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
    context.coordinator.renderKey = renderKey
    context.coordinator.schemeHandler.update(
      html: SecureHTMLRenderer.documentHTML(for: content, colorScheme: colorScheme),
      directoryURL: URL(fileURLWithPath: path).deletingLastPathComponent())
    view.underPageBackgroundColor =
      colorScheme == .dark
      ? NSColor(srgbRed: 22 / 255, green: 27 / 255, blue: 34 / 255, alpha: 1)
      : NSColor(srgbRed: 246 / 255, green: 248 / 255, blue: 250 / 255, alpha: 1)
    view.load(URLRequest(url: URL(string: "\(SecureHTMLRenderer.scheme)://document/view.html")!))
  }

  final class Coordinator: NSObject, WKNavigationDelegate {
    fileprivate let schemeHandler = SecureHTMLSchemeHandler()
    var renderKey = ""

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
        decisionHandler(.cancel)
      }
    }
  }
}

struct ProjectFileNode: Identifiable, Hashable {
  let path: String
  let name: String
  let isDirectory: Bool
  let children: [ProjectFileNode]?

  var id: String { path }
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

    func children(of directory: URL, depth: Int) throws -> [ProjectFileNode] {
      guard depth <= maximumDepth, remaining > 0 else { return [] }
      let urls = try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [
          .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey,
        ],
        options: [.skipsHiddenFiles])
      return
        try urls
        .filter { !ignoredDirectoryNames.contains($0.lastPathComponent) }
        .sorted {
          let leftDirectory =
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
          let rightDirectory =
            (try? $1.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
          if leftDirectory != rightDirectory { return leftDirectory }
          return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            == .orderedAscending
        }
        .compactMap { url in
          guard remaining > 0 else { return nil }
          let values = try url.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
          ])
          guard values.isSymbolicLink != true else { return nil }
          let safePath = try WorkspacePathPolicy.canonicalContainedPath(
            url.path, within: root.path)
          remaining -= 1
          if values.isDirectory == true {
            return ProjectFileNode(
              path: safePath, name: url.lastPathComponent, isDirectory: true,
              children: try children(of: url, depth: depth + 1))
          }
          guard values.isRegularFile == true else { return nil }
          return ProjectFileNode(
            path: safePath, name: url.lastPathComponent, isDirectory: false, children: nil)
        }
    }

    return try children(of: root, depth: 0)
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
        path: node.path, name: node.name, isDirectory: true, children: matches)
    }
  }
}

struct ProjectFileNavigator: View {
  let root: String
  let openFile: (String) -> Void
  let close: () -> Void
  let fileWatchingEnabled: Bool
  @State private var currentRoot: String
  @State private var nodes: [ProjectFileNode] = []
  @State private var changes: [GitChangedFile] = []
  @State private var query = ""
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var revision = 0
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
    ProjectFileTreeLoader.filtering(nodes, query: query)
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
        Spacer()
        Button {
          if let parentDirectory { navigate(to: parentDirectory) }
        } label: {
          Image(systemName: "arrow.up")
        }
        .buttonStyle(.borderless)
        .disabled(parentDirectory == nil)
        .help("Go to parent folder")
        .accessibilityIdentifier("operator.fileNavigator.up")
        Button {
          chooseFolder()
        } label: {
          Image(systemName: "folder.badge.plus")
        }
        .buttonStyle(.borderless)
        .help("Choose a folder to browse")
        .accessibilityIdentifier("operator.fileNavigator.chooseFolder")
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: currentRoot)])
        } label: {
          Image(systemName: "arrow.forward.square")
        }
        .buttonStyle(.borderless)
        .help("Reveal project in Finder")
        Button {
          revision &+= 1
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Refresh files")
        Button(action: close) {
          Image(systemName: "sidebar.trailing")
        }
        .buttonStyle(.borderless)
        .help("Hide file navigator")
      }
      .padding(11)

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
                node: node, root: repositoryRoot ?? currentRoot, changes: changes,
                openFile: openFile, depth: 0)
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
    let result = await Task.detached(priority: .utility) {
      Result { try ProjectFileTreeLoader.load(root: root) }
    }.value
    switch result {
    case .success(let loaded):
      nodes = loaded
    case .failure(let error):
      nodes = []
      errorMessage = error.localizedDescription
    }
    let git = await Task.detached(priority: .utility) {
      guard GitRepository.isRepository(containing: root),
        let repositoryRoot = try? GitRepository.repositoryRoot(containing: root)
      else { return (root: Optional<String>.none, changes: [GitChangedFile]()) }
      return (
        root: Optional(repositoryRoot),
        changes: (try? GitRepository.status(in: repositoryRoot)) ?? []
      )
    }.value
    repositoryRoot = git.root
    changes = git.changes
    gitObservation =
      fileWatchingEnabled
      ? git.root.map { repositoryRoot in
        GitWorkspaceMonitor.shared.observe(rootPath: repositoryRoot) { snapshot in
          Task.detached(priority: .utility) {
            let refreshedNodes = try? ProjectFileTreeLoader.load(root: root)
            await MainActor.run {
              changes = snapshot.changes
              if let refreshedNodes {
                nodes = refreshedNodes
              }
            }
          }
        }
      } : nil
    isLoading = false
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
      changes = []
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
}

private struct ProjectFileTreeNodeView: View {
  let node: ProjectFileNode
  let root: String
  let changes: [GitChangedFile]
  let openFile: (String) -> Void
  let depth: Int
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      if node.isDirectory {
        Button {
          withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
        } label: {
          nodeRow
        }
        .buttonStyle(.plain)
        .contextMenu { revealButton }
        if isExpanded, let children = node.children {
          ForEach(children) { child in
            ProjectFileTreeNodeView(
              node: child, root: root, changes: changes, openFile: openFile,
              depth: depth + 1)
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
        if let decoration = gitDecoration {
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

  private var gitDecoration: (label: String, color: Color)? {
    let relative = URL(fileURLWithPath: node.path).path.replacingOccurrences(
      of: URL(fileURLWithPath: root).path + "/", with: "")
    let relevant = changes.filter {
      node.isDirectory ? $0.path.hasPrefix(relative + "/") : $0.path == relative
    }
    guard let change = relevant.first else { return nil }
    if node.isDirectory { return ("•", .orange) }
    if change.section == .untracked { return ("U", .green) }
    switch change.status {
    case "A": return ("A", .green)
    case "D": return ("D", .red)
    case "R": return ("R", .purple)
    default: return ("M", .orange)
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
  @State private var errorMessage: String?
  @State private var githubURL: URL?
  @State private var revision = 0
  @State private var deletionReported = false
  @State private var htmlMode: HTMLMode = .rendered

  private enum HTMLMode: String, CaseIterable, Identifiable {
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
        Spacer()
        if isHTML {
          Picker("HTML mode", selection: $htmlMode) {
            ForEach(HTMLMode.allCases) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.segmented)
          .frame(width: 180)
          .accessibilityIdentifier("operator.htmlViewer.mode")
        }
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } label: {
          Image(systemName: "arrow.forward.square")
        }
        .help("Reveal in Finder")
        Button {
          revision &+= 1
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("Reload file")
        Button(action: close) {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Close file pane")
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(.bar)
      .fixedSize(horizontal: false, vertical: true)
      .layoutPriority(1)
      Divider()

      if let errorMessage {
        ContentUnavailableView(
          "Cannot preview file", systemImage: "doc.questionmark",
          description: Text(errorMessage))
      } else if isHTML, htmlMode == .rendered {
        SecureHTMLWebView(
          content: content, path: path, revision: revision, colorScheme: colorScheme
        )
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
          Text(CodeSyntaxHighlighter.highlight(content, path: path, colorScheme: colorScheme))
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
      }
    }
    .padding(14)
  }

  private func monitorFileChanges() async {
    var previous = OpenFileSnapshot.capture(path)
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: .milliseconds(900))
      } catch {
        return
      }
      let current = OpenFileSnapshot.capture(path)
      guard current != previous else { continue }
      previous = current
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

  private func load() async {
    let path = path
    let workspaceDirectory = workspaceDirectory
    let result = await Task.detached(priority: .utility) {
      Result { () throws -> ProjectFilePreviewPayload in
        let safePath = try WorkspacePathPolicy.canonicalContainedPath(
          path, within: workspaceDirectory)
        let url = URL(fileURLWithPath: safePath)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard (values.fileSize ?? 0) <= 5 * 1024 * 1024 else {
          throw NSError(
            domain: "OperatorFileViewer", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "File exceeds the 5 MB preview limit."])
        }
        guard let value = try String(contentsOf: url, encoding: .utf8) as String? else {
          throw MarkdownViewerError.invalidText
        }
        return ProjectFilePreviewPayload(
          content: value, githubURL: GitRepository.githubFileURL(for: safePath))
      }
    }.value
    switch result {
    case .success(let payload):
      content = payload.content
      githubURL = payload.githubURL
      errorMessage = nil
    case .failure(let error):
      content = ""
      githubURL = nil
      errorMessage = error.localizedDescription
    }
  }
}

private struct ProjectFilePreviewPayload: Sendable {
  let content: String
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
