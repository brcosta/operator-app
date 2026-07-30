# Operator Security Model

Operator is a local terminal and agent supervisor. It intentionally starts commands with the
current user's privileges, so a command launched in Operator has the same filesystem, network, and
credential access it would have in Terminal.app. Operator is not a privilege boundary and must not
be used to run untrusted commands.

## Trust boundaries

- Projects, commands, imported configuration, and generated artifacts are user-controlled input.
- Terminal output is untrusted display data and is never written to Operator's diagnostics.
- Harness-to-app requests use a user-only Unix socket and a random credential scoped to one live
  terminal session. A session cannot route events or UI actions as another session.
- Markdown and artifact requests are restricted to the originating terminal's canonical working
  directory. Symlink escapes are rejected and the restriction is checked again when content is
  reloaded.
- Rendered Markdown disables JavaScript and raw HTML, blocks network subresources with Content
  Security Policy, and opens only user-clicked HTTP, HTTPS, or mail links externally.
- Git inspection uses `/usr/bin/git`, passes arguments without a shell, disables repository
  `core.fsmonitor` commands and hooks, disables external diffs, caps output, and enforces a timeout.

## Local data

State, backup state, structured logs, generated hook configuration, and the local helper directory
use user-only POSIX permissions. State contains project paths, commands, task briefs, activity, and
session metadata, but not terminal scrollback or prompts.

Environment keys that look like tokens, passwords, API keys, private/access keys, cookies, or other
credentials are never written to state or configuration exports. Credential-bearing URLs are also
omitted. Put durable secrets in the macOS Keychain or the CLI's own credential store; inject them
at runtime rather than expecting Operator to restore them.

Diagnostics use layered redaction for assignments, bearer tokens, common provider token formats,
private-key blocks, credential-bearing URLs, and the user's home path. Diagnostics can still
contain project names and operational metadata, so review an exported report before sharing it.

## Distribution and other Macs

The packaging script creates an ad-hoc-signed app with Hardened Runtime and verifies the sealed
bundle before publishing it locally. CI pins third-party actions and the branch-only Markdown
dependency to immutable commits. Secret scanning covers the full Git history.

Ad-hoc signing does not establish publisher identity, and development builds are not notarized.
For another Mac, prefer building from a reviewed commit on that Mac. If transferring a build, use a
trusted channel and compare a separately communicated SHA-256 checksum. A production release should
use a protected Developer ID certificate, Hardened Runtime, notarization, and stapling.

## Deliberate residual risks

- App Sandbox is not enabled. A general terminal manager must execute user-selected shells and
  developer tools and access their selected repositories. Hardened Runtime protects the Operator
  process, but commands launched inside terminals remain intentionally unrestricted.
- A process running inside a managed terminal receives that terminal's short-lived IPC credential
  and can request actions for its own session.
- Notification previews can expose session titles or agent questions according to the user's macOS
  notification-preview settings. Notifications are opt-in.
- A compromised dependency, compiler, build runner, or Developer ID identity can compromise the
  resulting application. Immutable pins and review reduce this risk but cannot eliminate it.

## Before trusting a release

1. Review the commit and `Package.resolved`.
2. Run `swift test`, a release build, the package smoke test, and Gitleaks.
3. Verify the app with `codesign --verify --deep --strict Operator.app`.
4. Confirm `codesign -dv --verbose=4 Operator.app` reports the `runtime` flag.
5. For distributed releases, verify Developer ID signing and notarization with `spctl`.
