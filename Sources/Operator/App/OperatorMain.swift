import AppKit

@main
struct OperatorMain {
  private static var appDelegate: OperatorAppDelegate?

  @MainActor
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "open": exit(OperatorCommandClient.open(arguments: arguments))
    case "layout", "split-right", "split-bottom", "split-down":
      exit(OperatorCommandClient.layout(arguments: arguments))
    case "question": exit(OperatorCommandClient.question(arguments: arguments))
    case "event": exit(OperatorCommandClient.event(arguments: arguments))
    case "hook": exit(OperatorCommandClient.hook(arguments: arguments))
    case "artifact": exit(OperatorCommandClient.artifact(arguments: arguments))
    case "help", "--help", "-h": exit(OperatorCommandClient.help(arguments: arguments))
    case "--ui-testing":
      break  // XCTest supplies this flag when launching the macOS application target.
    case let command? where command.hasPrefix("-psn_"):
      break  // Finder launches macOS apps with a process-serial-number argument.
    case .some:
      fputs(
        "Usage: operator <open|layout|split-right|split-bottom|split-down|question|event|hook|artifact|help> …\n",
        stderr)
      exit(64)
    case nil:
      break
    }
    let app = NSApplication.shared
    let appDelegate = OperatorAppDelegate()
    self.appDelegate = appDelegate
    app.delegate = appDelegate
    app.setActivationPolicy(.regular)
    appDelegate.showWorkspace()
    app.run()
  }
}

extension Notification.Name {
  static let operatorNewSession = Notification.Name("operatorNewSession")
  static let operatorNewProject = Notification.Name("operatorNewProject")
  static let operatorSettings = Notification.Name("operatorSettings")
}
