# Changelog

All notable changes to Operator are documented here. Releases follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-08-01

- Add a focused Harness Launch settings page for optional arguments applied to new
  Claude Code and Codex sessions.
- Remove Mission Control and Stop toolbar actions, including the retired harness
  layout command and shortcut.
- Refine file navigator control alignment and presentation.
- Harden standalone SwiftPM and packaged-app startup paths.

- Fix packaged app bundles to include SwiftPM harness-brand resources, preventing
  startup crashes in downloaded DMGs.

## [0.1.0] - 2026-07-19

Initial public baseline: multi-project CLI harness sessions, managed resume,
terminal split grids, activity and task supervision, local Git inspection,
Markdown and diff viewers, native notifications, and configurable shortcuts.

[Unreleased]: https://github.com/brcosta/operator-app/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/brcosta/operator-app/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/brcosta/operator-app/releases/tag/v0.1.0
