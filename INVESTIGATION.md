# SelectableRegion `_flushAdditions` crash — investigation summary

## Status (2026-04-10, updated with framework fix research)

**Reliably reproduced.** Three approaches (A, B, C) crash on Flutter 3.41.6
stable with dart2wasm on Chrome. Each hits a different code path inside
`MultiSelectableSelectionContainerDelegate._compareScreenOrder`.

**Framework fix direction confirmed:** a surgical try/catch guard in
`_compareScreenOrder` is the viable upstreamable fix. The route-level
`SelectionContainer.disabled` approach (originally endorsed by
@Renzo-Olivares) was invalidated by deep review — see "Why not
route-level `SelectionContainer.disabled`" below.

## Root cause

`_RenderTheater` (the render object behind `Overlay`) intentionally skips
laying out non-topmost `OverlayEntry` children as a performance optimization.
However, the skipped entries' `SelectionContainerDelegate` keeps processing
registered selectables whose `RenderBox`es now have no size. When
`_flushAdditions` runs the merge-sort via `_compareScreenOrder`, it accesses
`paintBounds`, `getTransformTo`, or `getBoxesForSelection` on those
unlaid-out RenderBoxes and throws `StateError: Bad state: RenderBox was not
laid out`.

### Crash paths confirmed

1. `_getBoundingBox` → `SelectionContainerState.boundingBoxes` → `paintBounds` → `size` (Approach A)
2. `_SelectableTextContainerDelegate._compareScreenOrder` → `_SelectableFragment.boundingBoxes` → `getBoxesForSelection` (Approach B)
3. `_compareScreenOrder` → `getTransformTo` → `RenderFractionalTranslation.applyPaintTransform` → `size` (Approach C)

### Crash timing

The crash mechanism validated by three independent research reports
(see `investigation/report{1,2,3}.md`):

1. When a new route is pushed, `_routeSetState` calls `setState` synchronously,
   marking `_ModalScopeState` dirty.
2. Build phase processes dirty elements — selectables register with their
   delegate's `add()`, which calls `_scheduleSelectableUpdate()`.
3. `_scheduleSelectableUpdate` uses `addPostFrameCallback` (or `scheduleMicrotask`
   when called during `postFrameCallbacks` phase).
4. Layout phase: `_RenderTheater.performLayout()` skips layout for the first
   `skipCount` children (obscured by opaque entries).
5. Post-frame callback fires: `_flushAdditions()` runs the sort/merge via
   `_compareScreenOrder`, accessing geometry on selectables whose `RenderBox`es
   were never laid out → crash.

The build phase precedes layout, and post-frame callbacks fire after both.
The deregistration via `SelectionContainer.disabled` (if it were effective)
would complete during build, before the crash in post-frame. This timing is
safe — but the route-level wrapper approach itself is flawed (see below).

## Why NOT route-level `SelectionContainer.disabled`

@Renzo-Olivares [directed](https://github.com/flutter/packages/pull/11062#pullrequestreview-3893563878)
us to move the fix to the framework by wrapping non-current route content in
`SelectionContainer.disabled` at `_ModalScopeState.build()`.

**This approach was invalidated** by four independent reviews. The fatal flaw:

`SelectionContainer.disabled` only nulls the nearest ancestor
`SelectionRegistrarScope`. But `SelectionArea` / `SelectableRegion` create
their own `SelectionContainer(registrar: this, ...)` inside the route
(`selectable_region.dart:1944`), which installs a **fresh registrar** that
**shadows the disabled outer scope**. The route-level wrapper cannot suppress
selection inside nested `SelectionArea` instances — which is exactly what
apps use.

```
Route content tree with the proposed wrapper:

_SelectionScopeForRoute (disabled scope — registrar: null)
  └─ Offstage
       └─ ... route content ...
            └─ SelectionArea
                 └─ SelectableRegion (builds its own SelectionContainer)
                      └─ SelectionContainer(registrar: this)  ← SHADOWS the disabled scope
                           └─ SelectionRegistrarScope(registrar: delegate)  ← non-null!
                                └─ Text widgets  ← STILL register as selectables
```

This means:
- The route-level wrapper does nothing to nested `SelectionArea` trees
- The structural test (`SelectionContainer.maybeOf(context)` inside `SelectionArea`)
  resolves the inner registrar, not the outer disabled scope
- The approach cannot work without redesigning how `SelectableRegion` obtains
  its registrar (a larger design change)

### Why the app-level workaround works differently

Our production workaround (`_RouteAwareSelectionArea`) operates at a
different level: it **toggles the `SelectionArea` itself on/off**, replacing
it entirely with `SelectionContainer.disabled` when the route is not current.
This removes `SelectableRegion` from the tree, so no registrar is created.
The framework can't do this because it doesn't know which routes have
`SelectionArea`.

### Additional issues with `!isCurrent` signal

Even if the wrapper could reach nested `SelectionArea`, using
`!route.isCurrent` as the signal is too aggressive — it disables selection
for routes below **non-opaque overlays** (dialogs, bottom sheets, popup
menus) where the route is visible and the user expects selection to work.
The crash only occurs behind **opaque** routes where `_RenderTheater`
actually skips layout. All three reports flagged this as HIGH risk.

## Proposed framework fix: guard in `_compareScreenOrder`

The viable upstreamable fix is a surgical try/catch in
`MultiSelectableSelectionContainerDelegate._compareScreenOrder`
(`selectable_region.dart:~2565`):

```dart
static int _compareScreenOrder(Selectable a, Selectable b) {
  try {
    final Rect rectA = MatrixUtils.transformRect(
        a.getTransformTo(null), _getBoundingBox(a));
    final Rect rectB = MatrixUtils.transformRect(
        b.getTransformTo(null), _getBoundingBox(b));
    final int result = rectA.top.compareTo(rectB.top);
    if (result != 0) return result;
    return rectA.left.compareTo(rectB.left);
  } on StateError {
    // Release mode: RenderBox.size throws StateError when _size is null.
    return 0;
  } on AssertionError {
    // Debug mode: hasSize/debugNeedsLayout assert fires first.
    return 0;
  }
}
```

### Why this works

- Catches the crash at its exact throw site
- `_flushAdditions` calls `compareOrder` (→ `_compareScreenOrder`) in exactly
  two places: line 2463 (sort) and line 2474 (merge). Both covered.
- Zero behavioral regressions (no dialog/bottom-sheet breakage)
- Works regardless of how selection is structured in the route subtree

### Known limitations

- **Dead zones:** Stale selectables remain registered and can intercept drag
  events. The catch prevents the crash but not the dead-zone behavioral bug
  (#182573). That requires either a framework-level `SelectionMode` mechanism
  (long-term) or app-level workarounds (our go_router PR #11062 /
  route-aware `SelectionArea` toggle).
- **Other unguarded geometry reads:** `selectable_region.dart` has other
  `boundingBoxes`/`getTransformTo` reads outside `_compareScreenOrder` (e.g.,
  `_handleSelectWordSelectionEvent` at ~line 2969). These are less frequently
  hit and can be addressed in follow-up PRs.

## Workarounds (validated)

### Proof of concept: `opaque: false`

Branch `fix/non-opaque-selectable-page` wraps the topmost `Page` in a
non-opaque route. Proves the mechanism but causes visual overlap (parent
painted behind child). **Not production-ready.**

### Production: route-aware `SelectionArea` toggle

Used in production apps. Toggles `SelectionArea` ↔ `SelectionContainer.disabled`
based on `ModalRoute.of(context)?.isCurrent`. Removes `SelectableRegion`
entirely when the route is not current, so no registrar or selectables exist.
Uses `GlobalKey` + `KeyedSubtree` to preserve child state.

This is the same pattern as [flutter/packages#11062](https://github.com/flutter/packages/pull/11062)
(our go_router PR). Works at the app level because the app controls where
`SelectionArea` is placed. Cannot be applied at the framework level because
the framework doesn't know which routes have `SelectionArea`.

## Upstream

- Canonical issue: [flutter/flutter#151536](https://github.com/flutter/flutter/issues/151536) (open, P2, 14+)
- Our go_router PR: [flutter/packages#11062](https://github.com/flutter/packages/pull/11062) (open, reviewed by @Renzo-Olivares 2026-03-05 — directed framework fix)
- Upstream comment: [#151536 comment](https://github.com/flutter/flutter/issues/151536#issuecomment-4225683042) (repro + analysis + fix direction)
- Prior art: [PR #157996](https://github.com/flutter/flutter/pull/157996) (Gustl22), [PR #158918](https://github.com/flutter/flutter/pull/158918) (Gustl22)
- Active maintainer: @Renzo-Olivares
- No in-flight competitor PR as of 2026-04-10

See [`investigation/upstream_research.md`](investigation/upstream_research.md)
for the full upstream dossier.

## Historical context

### March 2026 — initial investigation

Triggered by 1 production Sentry event. Attempted timing-based reproduction
approaches — none crashed. Hypothesis: specific microtask scheduling race
under dart2wasm. Partially correct but missed the primary mechanism:
`_RenderTheater` layout-skipping.

### April 2026 — reliable reproduction

Approaches targeting `_RenderTheater` directly crash reliably (current A, B,
C in `lib/main.dart`). Non-crashing approaches removed.

### April 2026 — framework fix research

Four independent research reports (`investigation/report{1,2,3}.md` +
adversarial review) validated the crash mechanism and invalidated the
route-level `SelectionContainer.disabled` approach. Converged on the
`_compareScreenOrder` try/catch guard as the viable upstreamable fix.

## Detailed analysis

- [`investigation/2026-04-10_verification.md`](investigation/2026-04-10_verification.md) — crash verdicts, stack traces, `opaque: false` validation
- [`investigation/upstream_research.md`](investigation/upstream_research.md) — issue/PR state, competitor sweep, Renzo's review directive
- [`investigation/framework_line_numbers.md`](investigation/framework_line_numbers.md) — verified line numbers on Flutter master (zero drift from 3.41.6)
- [`investigation/framework_fix_validation_prompt.md`](investigation/framework_fix_validation_prompt.md) — the deep research prompt used to validate assumptions
- [`investigation/report1.md`](investigation/report1.md) — research report 1
- [`investigation/report2.md`](investigation/report2.md) — research report 2
- [`investigation/report3.md`](investigation/report3.md) — research report 3
