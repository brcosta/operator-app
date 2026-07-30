# Operator Architecture

Operator is a local-only macOS application for supervising interactive CLI harnesses. Runtime terminal processes are separate from persisted session recipes: closing the app never stores terminal scrollback, while resumable harness identifiers and project layouts can be restored.

## Components

The repository is a single SwiftPM macOS package. `Sources/Operator` is grouped
by app lifecycle, domain, services, and user-facing features; the single target
keeps early-stage iteration simple while the folders make ownership explicit.

- `WorkspaceController` coordinates the visible project runtime, retains
  independent live session sets for background projects, and validates
  project-scoped tab navigation before changing the active project.
- Harness adapters own command detection, fresh launch preparation, capabilities, and resume command generation for Claude Code, Codex, and generic shells.
- `OperatorNotificationBridge` is a narrow Objective-C fault boundary around
  `UNUserNotificationCenter`. It converts framework `NSException` failures into
  ordinary errors so optional notification infrastructure cannot terminate the
  Swift app during delivery. Notification Center is never initialized during
  startup: alerts begin disabled on every launch and the bridge is reached only
  after an explicit runtime opt-in.
- `StateStore` persists projects, registered workspaces, profiles, session
  recipes, layouts, checks, activity, notifications, appearance, and shortcuts. Explicit,
  tolerant decoding supports older or partially damaged records; reconciliation
  repairs references, deduplicates canonical paths, and converts interrupted
  running sessions into visible failures. Sidebar collapse preferences persist
  as collapsed project IDs, making missing legacy preferences and newly created
  projects default to expanded.
- Projects carry a compact identity (`emoji` plus a named system accent) that is persisted and exported with project configuration. SwiftUI resolves the named accent at display time so it remains appropriate for light and dark appearances.
- Workspaces retain their stable filesystem name and path while storing an optional display alias. `Workspace.displayName` is the single UI-facing label, preventing the alias from changing command execution or Git inspection behavior.
- Harness identity is derived from `HarnessKind`; activity rows combine that symbol with the project accent, keeping project and harness context visually distinct.
- `OperatorIntegration` provides the user-only Unix socket used by the injected `operator` helper.
  Every request requires a short-lived credential scoped to the originating live session; there is
  no process-wide master credential. The socket uses a random filename inside a short, private
  per-user runtime directory rather than Application Support, avoiding macOS Unix-socket path
  limits even when the user's home or support path is unusually long.
- Git inspection, Markdown, diffs, and artifacts are local services. Git inspection never mutates repositories.
- `BoundedProcessRunner` drains child output concurrently, caps retained output,
  disables interactive prompts for inspections, enforces deadlines, and
  terminates stalled children. Git inspection uses it.
- `OperatorDebugLog` retains a bounded structured trace in memory and writes
  redacted, rotating JSONL diagnostics with protected filesystem permissions.
- Generated Markdown and artifacts are canonicalized beneath the originating session's working
  directory. Markdown renders without raw HTML or JavaScript, uses a network-denying content
  policy, and restricts external link schemes.
- `OperatorSystemSurfaces` projects supervised state into the Dock and menu bar. It derives a testable aggregate from all live project sessions, rather than persisting separate presentation state.
- `GitWorkspaceMonitor` uses recursive FSEvents with event coalescing and a 30-second fallback poll. One watcher is shared per repository root regardless of how many terminal panes observe it.

## Build and quality boundaries

Operator is a Swift 6 package with a macOS 14 runtime deployment target. The
project therefore uses Swift 6-compatible Xcode/macOS runners for automation;
the runner version is an implementation detail of CI, not a change to the
application's supported macOS version.

The repository separates fast package verification from process-level UI
verification:

- The required CI pipeline validates project metadata, release-builds the
  SwiftPM package, enforces `swift format` across the package, app, and test
  sources, runs the test suite, packages the app, reads the bundle version back
  from `Info.plist`, and launches the exact packaged executable in isolated
  smoke mode.
- The Xcode UI pipeline exercises the `OperatorUITests` target on pull requests
  and weekly. It saves an `.xcresult` artifact even when a test fails so the
  AppKit/Accessibility failure can be investigated outside the runner.
- The nightly reliability pipeline repeats the stateful Swift tests three times.
  It is intentionally separate from pull-request CI so timing-sensitive
  FSEvents, Git, IPC, and terminal-session behavior gets extra coverage without
  slowing ordinary feedback.
- Experimental Release is tag-triggered. It requires `vX.Y.Z` to match
  `Config/Version.xcconfig`, tests and packages the application, then publishes
  an experimental DMG and SHA-256 checksum as a GitHub pre-release. The asset
  is deliberately unsigned and unnotarized; signing, notarization, and a
  production release remain later distribution concerns.
- Secret scanning and Dependabot cover repository history and dependency drift;
  neither receives access to Operator runtime state or user projects.

## Harness event flow

1. Every terminal receives its own session ID and random session-scoped token.
2. The harness invokes `operator event`, `operator question`, or `operator artifact open`.
3. The Unix socket validates that the token belongs to the claimed session.
4. Operator routes the event to that project’s interaction state.
5. Question answers are written as normal input to the originating PTY.

## Restoration

- Claude Code and Codex hooks relay only the harness-native session identifier
  through the authenticated local socket. Session switches update both the
  recipe and recent-session record without persisting prompts, tool inputs, or
  transcript paths.
- Codex hook configuration is injected as session-scoped `hooks.*` overrides.
  Codex merges hook layers, so normal user/project configuration and existing
  hooks remain active. Manual resume association remains a fallback when hooks
  are disabled or awaiting trust.
- A stale Claude or Codex resume opens a fresh hooked harness in the same PTY;
  if the harness cannot start, the pane falls back to an interactive shell.
- Generic commands remain manual and are never automatically rerun.
- Each project owns its saved layout and active terminal set. Switching projects does not terminate other projects.

State is encoded atomically with a last-known-good neighbor. Decoding supplies
defaults for fields added in newer schema revisions and skips malformed array
records where possible. A corrupt primary is preserved for inspection and
recovered from the backup; a newer unsupported schema fails closed rather than
being overwritten. The reconciler then repairs orphan references, duplicate
identities and paths, invalid selections, ratios, geometry, and interrupted
session status.

Environment values whose names or URL forms indicate credentials are kept out of persisted state,
backups, and configuration exports. Integration identity variables cannot be overridden by a
launch profile.

## UI test boundary

`Operator.xcodeproj` owns the macOS application and its `OperatorUITests`
XCUITest target. UI tests drive the real AppKit/SwiftUI process through
Accessibility APIs. They launch with `--ui-testing` and a unique
`OPERATOR_STATE_PATH`, keeping production state, IPC, and automatic harness
restoration outside the test boundary. The CI UI workflow uses the same test
plan and retains its Xcode result bundle for diagnosis.

The package smoke boundary does not require Xcode. `--app-smoke-test` creates
the real AppKit window and SwiftUI root view using an isolated
`OPERATOR_STATE_PATH`, validates minimum window geometry and persistence
isolation, writes a JSON report, and exits. `Scripts/smoke-test-app.sh` also
checks bundle resources, the sealed code signature, and the Hardened Runtime
flag before launching the packaged executable.
