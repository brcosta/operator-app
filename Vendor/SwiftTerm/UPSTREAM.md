# Vendored SwiftTerm

Operator vendors SwiftTerm 1.15.0 at upstream revision
`dd2fb8ac5b861e7bf617c872895e338f38165648`.

The local copy exists because SwiftTerm does not expose the renderer, viewport offset, or
selection hit-testing hooks needed for native sub-line scrolling. Operator's changes are kept
inside the AppKit terminal view and are covered by Operator's terminal scrolling tests.

When updating SwiftTerm:

1. Replace `Sources/SwiftTerm` with the new pinned upstream sources.
2. Reapply the commits that mention `Operator smooth scrolling`.
3. Run `swift test` from Operator's repository root.
4. Exercise trackpad, mouse-wheel, selection, links, alternate-screen TUIs, and Reduce Motion.

SwiftTerm remains available under the MIT license in `LICENSE`.
