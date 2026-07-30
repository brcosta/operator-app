# Operator Daily-Driver Review

This historical review records the architecture and reliability assessment
that produced Operator's initial public baseline.

## Baseline

- The full Swift test suite passes.
- The project already has solid coverage for split layouts, project switching, Git worktrees,
  harness adapters, notifications, hooks, IPC framing, and basic persistence.
- Full XCUITest cannot run locally because only Apple Command Line Tools are installed. The
  repository's Xcode UI suite remains useful in CI.
- Local packaged-app validation will use a deterministic in-app smoke mode plus an isolated state
  file. `cliclick` is installed for optional Accessibility-driven interaction and screenshots.

## Findings and remediation

### P0 — State safety and restoration

1. `PersistedState` relies on synthesized decoding. A missing field introduced by any schema
   revision makes the entire state unreadable.
   - Add tolerant decoding with defaults and an explicit schema version.
   - Test old/minimal state, unknown/newer state, missing fields, and malformed optional records.
2. Corrupt state is copied aside but Operator then starts empty even if a usable prior save exists.
   Save failures are only an `assertionFailure`, which disappears in release builds.
   - Maintain a last-known-good backup, recover it automatically, and surface durable save errors.
   - Test primary corruption, backup recovery, backup corruption, unwritable destinations, and
     recovery messages.
3. Persisted references are not reconciled. Orphan projects/workspaces/sessions/tabs can survive
   import or hand-edited state.
   - Repair selections and references, deduplicate identities and canonical paths, clamp split
     ratios/window geometry, and retain valid records.
   - Test duplicate IDs, orphan recipes, stale tabs, invalid selection, and interrupted sessions.
4. `restoreProject` checks `restoreOnOpen` but ignores `SessionRecipe.isAutoRestorable`. Generic
   commands and Codex without a resume identifier fall back to launching the original command.
   - Restore only adapter-approved resumable recipes. Preserve unavailable panes as explicit empty
     panes rather than silently rerunning commands or losing geometry.
   - Test generic commands, Codex without an ID, missing workspaces, and mixed restorable layouts.

### P0 — Process, IPC, and agent lifecycle correctness

1. Any numeric process exit is classified as `.exited`; only a missing code is a failure.
   - Treat every non-zero exit as failed and keep the callback idempotent.
   - Test zero, non-zero, signal/unknown, and duplicate callbacks.
2. Session-scoped `operator open` omits its session ID, so the server rejects the session token.
   - Include and validate the issuing session for every terminal-originated action.
   - Test global and session tokens, cross-session claims, missing tokens, and invalid actions.
3. Unix socket reads/writes have no timeout, assume one `send` writes all bytes, and handle a client
   synchronously on the accept source.
   - Add bounded frames, send/receive timeouts, complete-write loops, per-client handling, secure
     socket permissions, and actionable errors.
   - Test fragmented frames, oversized frames, stalled peers, partial writes, and concurrent clients.
4. Agent questions, interactions, artifacts, and progress are unbounded in memory. Opening a
   question sheet removes the question before it is answered.
   - Add retention limits and event deduplication. Resolve only after a successful answer; viewing
     or canceling keeps the question pending.
   - Test duplicate events, invalid progress, large messages, cancel/reveal, answer, and retention.
5. Git subprocesses may block forever or deadlock when a child fills a pipe because
   output is read only after process exit.
   - Use a shared bounded subprocess runner with concurrent output draining, timeouts, output caps,
     prompt-disabled environments, and forced termination fallback.
   - Test large output, stderr, non-zero exit, timeout, and missing executable.

### P1 — Usability and professional UI

1. The empty workspace tells the user to choose a project but provides no direct first-run action.
   The toolbar presents many disabled, unexplained icons before they are relevant.
   - Add a modern onboarding command-center card with a primary **Add Project** action and concise
     capability cards. Keep first-run toolbar actions contextual.
2. New Project is a stock unlabeled form. It accepts nonexistent paths, silently accepts arbitrary
   text as an “emoji,” randomizes the accent, and gives no reason why Add is disabled.
   - Make folder selection primary, infer the name, add persistent labels/descriptions and a live
     preview, use accessible color chips, validate inline, and make completion explicit.
   - Unit-test the draft validator and keep stable Accessibility identifiers for UI automation.
3. Errors are mostly modal alerts or silently discarded `try?` operations.
   - Add a non-blocking persistence/recovery banner and surface import/export/diagnostic failures
     inline. Keep destructive metadata deletion explicitly confirmed.
4. Visual hierarchy is inconsistent across sheets and empty states.
   - Introduce reusable card, icon-tile, section-header, badge, and action styles using native
     materials and SF Symbols. Add subtle state transitions that respect Reduce Motion.

### P1 — Diagnostics and operations

1. Runtime logs exist only in memory, have no severity, no rotation, and disappear at app exit.
   Diagnostics may include unredacted dynamic strings.
   - Write structured redacted JSONL with levels, bounded in-memory retention, rotation, and a log
     location discoverable from Settings.
   - Test redaction, rotation, retention, serialization, and diagnostics contents.
2. Diagnostics expose counts but omit build/runtime/persistence/IPC health.
   - Include app/build/macOS versions, state health, log health, service availability, and recent
     structured errors without credentials.
3. Packaging validates version fields but not executable identity, resources, launch, isolated
   state, or smoke behavior.
   - Add a package verifier and packaged-app smoke script. Verify binary hashes, plist/resource
     presence, self-contained launch, isolated state, clean termination, and a machine-readable
     smoke report.

## Validation plan

1. Fast gates: `swift format lint`, metadata lint, focused unit tests.
2. Full gates: all Swift unit and integration tests, repeated state/IPC/process reliability tests.
3. Production gate: `swift build -c release`, package to a new non-overwriting bundle, verify plist,
   executable hash, icon, and dependency loading.
4. App gate: launch the packaged binary with `--ui-testing --app-smoke-test` and an isolated state
   path; require a valid JSON smoke report confirming window, root view, state isolation, and clean
   shutdown.
5. Multi-project gate: launch the packaged app with isolated state, create five projects with three
   sessions and two tabs each, split one tab per project, switch among projects, reload the state,
   and require all layout and persistence checks in the JSON report to pass.
6. Visual gate: capture the mounted SwiftUI window from the multi-project scenario and inspect the
   populated sidebar, tabs, and split panes. Accessibility automation remains available for
   targeted interaction checks where macOS permissions allow it.
7. CI-only gate: retain XCUITest through `Operator.xcodeproj`; document that full Xcode is required
   for the real external Accessibility runner.

## Implementation result

All P0 findings above are implemented in the working copy. The Swift suite grew
from 79 to 105 tests and now covers corrupt-primary recovery, lossy legacy
decoding, unwritable state, canonical-path deduplication, invalid project
drafts, safe resumability, missing panes, non-zero exits, oversized IPC,
redaction, noisy children, non-zero children, deadlines, and cross-process
state readability. UI-state coverage also verifies deterministic emoji search,
default-shell pane filling, emoji popover geometry, benign schema defaults,
interactive-shell restoration, orphan-recipe filtering, and removal of wholly
unrestorable tabs. A five-project regression additionally verifies independent
tabs and split-pane layouts across save and reload, including validated,
persistent tab-title renaming, while project-scoped sidebar navigation rejects
stale and mismatched tab targets. Sidebar project disclosure
preferences default open, persist, ignore unknown IDs, and are removed with
deleted projects. The full suite passes under parallel execution.

The P1 first-run and project-creation surfaces have been rebuilt with native
materials, SF Symbols, descriptions, inline validation, live preview, stable
Accessibility identifiers, and Reduce Motion support. Persistence and recovery
errors are visible in-context. Settings exposes state, backup, log, import,
export, and diagnostics operations with success or error feedback.

The remaining platform boundary is external XCUITest: this machine has Apple
Command Line Tools but not full Xcode. The repository retains its real Xcode UI
target and CI plan. Local automation instead validates the compiled app through
the deterministic in-process AppKit/SwiftUI smoke mode and package verifier,
including the app-owned emoji catalog and emoji normalization path.
