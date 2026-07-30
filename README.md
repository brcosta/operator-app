# Operator

[![CI](https://github.com/brcosta/operator-app/actions/workflows/ci.yml/badge.svg)](https://github.com/brcosta/operator-app/actions/workflows/ci.yml)

**Current version: 0.1.0**

Operator is a native macOS terminal workspace for running interactive CLI agent harnesses—such as Codex CLI, Claude Code, or any shell command—inside project-focused sessions.

It is local-only and human-controlled: it stores project, profile, layout, and session-status metadata, but never terminal scrollback or prompts.

## Versioning

Operator follows [Semantic Versioning](https://semver.org/). `0.1.0` is the
initial public baseline: pre-1.0 while APIs and workflows are still evolving.
`Config/Version.xcconfig` is the release-version source of truth for Xcode and
the packaging script. Each release should receive a matching `vX.Y.Z` Git tag
and an entry in the [changelog](CHANGELOG.md).

## Requirements

- macOS 14 or later
- Xcode 16+ or another Swift 6-compatible toolchain

## Run

```sh
swift run Operator
```

Use the project sidebar to add a working directory, then press Command-K to launch a command. Use the Split button after opening two sessions.

Projects can have an optional emoji and a subtle system accent color. Set them
when creating a project, or use **Customize Appearance…** from a project’s
context menu. The searchable emoji picker runs entirely inside Operator and
also accepts a pasted emoji, avoiding Character Viewer focus problems. Operator
uses the identity mark in the sidebar, the compact
project strip above the terminal grid, and the status bar; terminal colors and
Git diff semantics remain unchanged.

Each terminal is also identified as Codex, Claude Code, or a generic terminal
with a compact native symbol. Project activity reuses the project accent as a
small rail and label, while retaining the harness symbol so concurrent work is
easy to scan. Workspaces may have a friendly alias: use **Set Alias…** from a
workspace context menu to show a task-appropriate name in the sidebar, launch
picker, health view, and status bar without changing its filesystem path.

## Open generated Markdown

Every terminal launched by Operator receives an `operator` helper command. A harness can open a generated Markdown file in a rendered Operator tab with:

```sh
operator open docs/implementation-plan.md
```

The path may be relative to the terminal's current directory or absolute. Operator opens readable `.md`, `.markdown`, and `.mdx` files, refreshes the preview when the file changes, and keeps the source accessible from the same tab.

## Inspect local Git changes

Select a project and choose **Changes**, or have a harness open the repository containing its current directory:

```sh
operator diff
```

`operator diff path/to/project` opens a specific repository. The native Changes tab groups staged, unstaged, and untracked files, refreshes automatically, and provides unified or side-by-side text diffs. It runs only local read-only Git inspection commands; staging, discarding, committing, pushing, and network access are intentionally absent.

## Let a harness create a split

From an Operator-managed terminal, a harness can split its own pane without opening another app window:

```sh
operator split-right
operator split-down
```

`split-down` is an alias for `operator layout split-bottom`; the canonical form also supports `mission-control`:

```sh
operator layout split-bottom
operator layout mission-control
```

The new pane starts empty, so the operator can choose a harness or custom command there. The request is scoped to the terminal that issued it, even if another pane is currently focused in the UI.

## Supervise agent work

Each active terminal can have a persistent **Task Brief** with an objective, constraints, and acceptance criteria. The **Activity** panel records launches, task-brief updates, Git working-tree changes, and outcomes. Every Git-backed session also shows a compact changed-file button in its pane status bar; select it to inspect the live, read-only worktree radar without covering terminal output.

Terminal settings let you choose any installed monospaced font, adjust its size,
enable the selected font’s programming ligatures, and choose a bounded scrollback
limit. Changes apply to open panes immediately. New terminals and panes request
keyboard focus as soon as their native terminal view is mounted.

Failure alerts are runtime opt-in from the Activity panel and start disabled every
time Operator opens. Startup never initializes Notification Center. Operator asks
macOS for notification permission only when you explicitly turn alerts on for
that run, and sends alerts only when a session fails or exits with a non-zero code.
If macOS notification infrastructure is unavailable or rejects initialization,
Operator records the failure, disables notifications for that run, and continues
with terminal and workspace functionality intact.

Operator also has a native macOS control center in the menu bar. It summarizes
running harnesses, exposes unanswered questions, opens the matching terminal
pane, and can start a new session. The Dock badge shows pending questions (or
failures when there are no questions); reported harness progress is rendered as
a compact Dock progress ring.

Harnesses can publish structured activity and artifacts:

```sh
operator event progress "Indexing repository"
operator event child-started "review-agent"
operator artifact open reports/results.json json
operator question "Which migration should I use?"
```

Events are authenticated per terminal session. Questions route back to the correct project and pane; Operator can inject the operator's answer into that terminal.

## Restore project sessions

Session recipes and layouts are stored per project. Operator's session-scoped
lifecycle hooks automatically retain the active Claude session or Codex thread,
including changes made with the harness's own session switcher. Codex hook
configuration is limited to `hooks.*` launch overrides; Codex merges those hooks
with normal user and project configuration instead of replacing it. If hooks
are disabled or awaiting trust, the session tab context menu remains available
to associate a UUID or name accepted by `codex resume`. Generic commands remain
stopped and are never rerun automatically.

A saved tab whose sessions are all unavailable is removed instead of appearing
as a misleading named empty tab. Empty panes are retained only inside otherwise
restorable split layouts.

Each project retains an independent live grid when you switch projects. Projects
start expanded in the sidebar so their tabs are immediately visible; Operator
remembers any project you collapse. A sidebar tab jumps directly to that project
and tab. Expanded groups use relaxed rows and full-width separators, while paths,
harnesses, and pane counts remain in tooltips and accessibility descriptions.
Rename Tab updates the shared title everywhere and persists it across relaunches.
Pane split orientation is configurable, and panes can be zoomed without losing
the underlying layout.

Tab indicators observe the shared PTY output path for shells, Codex, and Claude
Code. A green waveform means the tab is producing output; a project-colored
ringed dot means output arrived while the tab was not visible. Selecting the tab
marks all of its split panes as read.

Interface motion uses short, reduced-motion-aware cross-fades and restrained
position changes. Sidebar project disclosure animates its tab rows, activity and
selection indicators cross-fade, and recovery or persistence messages appear as
floating material toasts without moving the terminal layout.

## Projects and workspaces

An Operator project is a task container: add service repositories and Git worktrees with **Add Workspace** from its context menu. The Command Palette lets each new harness choose one of those locations, while a project can still have many concurrent terminal tabs.

The **Changes** menu opens the selected location’s diff view. Git inspection is read-only, and test outcomes remain visible in Agent Activity.

## Native file watch and window polish

Git working-tree radar uses recursive macOS FSEvents with a short debounce, so
changes beneath nested source directories appear promptly without a tight polling
loop. A low-frequency fallback protects against filesystems that do not provide
reliable events. The workspace uses a balanced native split view, material status
bar, sidebar styling, compact unified toolbar, and macOS window tabbing support.

## Verify

```sh
swift format lint Package.swift
swift format lint -r Sources Tests UITests
swift test
./Scripts/package-app.sh /private/tmp/Operator.app
./Scripts/smoke-test-app.sh /private/tmp/Operator.app
./Scripts/multi-project-ui-stress-test.sh /private/tmp/Operator.app
```

The multi-project stress test launches the packaged SwiftUI app with isolated
state, creates five projects with three sessions and two tabs each, adds a
two-pane split to every project, switches among projects, reloads the saved
workspace, captures the mounted window, and writes a machine-readable report.
It never reads or changes the normal Operator workspace.

Formatting is enforced in CI. To apply the repository style locally:

```sh
swift format -i Package.swift
swift format -i -r Sources Tests UITests
```

## Continuous verification

GitHub Actions keeps the macOS build reproducible on a Swift 6-compatible
runner:

- **CI** builds in release mode, checks formatting, runs the Swift test suite,
  packages `Operator.app`, verifies its stamped version, then launches that
  exact bundle with isolated state and requires a machine-readable smoke report.
- **UI Tests** runs the Xcode test plan for pull requests and weekly; failed
  runs retain an `.xcresult` bundle for inspection.
- **Experimental Release** runs for `vX.Y.Z` tags, requires the tag to match
  `Config/Version.xcconfig`, then tests, packages an experimental DMG and
  SHA-256 checksum, and attaches both to a GitHub pre-release. The installer is
  explicitly unsigned and unnotarized; macOS Gatekeeper may require manual
  approval. It is not a production release.
- **Nightly Reliability** repeats the stateful Swift test suite three times
  and preserves its logs.
- **Secret Scan** checks commits for exposed credentials, while Dependabot
  opens weekly update pull requests for SwiftPM and GitHub Actions dependencies.

Pull requests should use the included template to record verification, release
metadata, and credential-safety checks.

### Xcode UI tests

Operator includes a native macOS `XCUITest` target in `Operator.xcodeproj`. The
suite launches the real app, creates projects through the interface, starts a
terminal session, opens sheets, and exercises configurable keyboard shortcuts.

Open `Operator.xcodeproj`, select the shared **Operator** scheme, and press
Command-U. From a terminal with full Xcode selected:

```sh
xcodebuild test \
  -project Operator.xcodeproj \
  -scheme Operator \
  -testPlan OperatorUITests \
  -destination 'platform=macOS'
```

Each UI test uses a unique temporary state file through `OPERATOR_STATE_PATH`.
The `--ui-testing` launch argument disables automatic harness restoration and
the IPC listener so existing Operator sessions cannot affect the suite.

## Package an app bundle

```sh
./Scripts/package-app.sh
# or choose a non-existing output path
./Scripts/package-app.sh /private/tmp/Operator.app
```

The script creates `dist/Operator.app` and deliberately refuses to overwrite an existing bundle. It is not signed or notarized.

To validate a package without touching daily-driver state:

```sh
./Scripts/smoke-test-app.sh dist/Operator.app
```

The smoke harness checks the executable, plist, icon, and release-binary
identity, then launches the packaged app in an isolated temporary environment.
The app verifies that its window and root view are usable, confirms the built-in
emoji catalog and normalization path, writes a JSON report, saves valid state,
and terminates cleanly.

## Data safety and diagnostics

Operator writes state atomically and keeps `state.last-good.json` beside the
primary state file. Invalid records in older state are skipped when possible;
if the primary file cannot be decoded, Operator preserves it and restores the
last known good state. Interrupted sessions are marked failed rather than left
permanently “running.”

Persisted interactive shells—including Fish, Zsh, and Bash—are relaunched in
their saved tabs when Operator opens. Automatic generic-command restoration is
deliberately limited to a validated shell executable with safe interactive or
login flags; compound commands, `-c` commands, and one-shot processes are never
rerun automatically. Recipes not referenced by the saved tab layout are not
resurrected.

Settings includes a persisted System, Light, or Dark appearance preference,
pane layout controls, state and backup paths, and access to the structured
runtime log. Appearance changes apply live to Operator chrome, while an
existing terminal keeps its session-owned palette so ANSI and application
colors are never overwritten. Logs are redacted JSON Lines with severity,
bounded memory retention, and rotation. Save and recovery failures are also
shown inside the workspace so release builds never fail silently.

Operator deliberately does not persist environment values that look like credentials, including
tokens, passwords, API keys, private/access keys, cookies, and credential-bearing URLs. Keep durable
secrets in Keychain or the harness's own credential store. See [SECURITY.md](SECURITY.md) for the
trust model, multi-machine guidance, and remaining risks.
