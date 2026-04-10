# SelectableRegion `_flushAdditions` crash — investigation summary

## Status (2026-04-11, framework PR open)

**Reliably reproduced.** Three approaches (A, B, C) crash on Flutter 3.41.6
stable with dart2wasm on Chrome. Each hits a different code path inside
`MultiSelectableSelectionContainerDelegate._compareScreenOrder` or
`_SelectableTextContainerDelegate._compareScreenOrder`.

**Framework PR open:** [flutter/flutter#184900](https://github.com/flutter/flutter/pull/184900)
guards both `_compareScreenOrder` overrides (`selectable_region.dart` and
`text.dart`) with a try/catch for `StateError` / `AssertionError` thrown from
unlaid-out `RenderBox`es. The route-level `SelectionContainer.disabled`
approach (originally endorsed by @Renzo-Olivares on the go_router PR) was
invalidated by deep review — see "Why NOT route-level `SelectionContainer.disabled`"
below. Awaiting review from @Renzo-Olivares.

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

## Framework fix: guard in `_compareScreenOrder`

Shipped in [flutter/flutter#184900](https://github.com/flutter/flutter/pull/184900)
(open). The fix is a surgical try/catch in **both** `_compareScreenOrder`
overrides:

**1. `selectable_region.dart:2565`** — `MultiSelectableSelectionContainerDelegate._compareScreenOrder`:

```dart
static int _compareScreenOrder(Selectable a, Selectable b) {
  try {
    final Rect rectA = MatrixUtils.transformRect(a.getTransformTo(null), _getBoundingBox(a));
    final Rect rectB = MatrixUtils.transformRect(b.getTransformTo(null), _getBoundingBox(b));
    final int result = _compareVertically(rectA, rectB);
    if (result != 0) {
      return result;
    }
    return _compareHorizontally(rectA, rectB);
  } on StateError {
    // Release mode: RenderBox.size throws StateError when _size is null.
    return 0;
  } on AssertionError {
    // Debug mode: hasSize/debugNeedsLayout assert fires first.
    return 0;
  }
}
```

**2. `text.dart:1304`** — `_SelectableTextContainerDelegate._compareScreenOrder`
has the same try/catch shape, with `a.boundingBoxes.first` / `b.boundingBoxes.first`
as the sort key instead of `_getBoundingBox(a)` / `_getBoundingBox(b)`.

### Why this works

- Catches the crash at its exact throw site in both delegate paths
- `_flushAdditions` calls `compareOrder` (→ `_compareScreenOrder`) in exactly
  two places: line 2463 (sort) and line 2474 (merge). Both covered.
- Zero behavioral regressions (no dialog/bottom-sheet breakage)
- Works regardless of how selection is structured in the route subtree
- Covered by **two widget-level regression guards** plus **four mock-based
  red/green tests** (one `StateError` + one `AssertionError` case per
  guarded method) that fail on `master` without the guards and pass with them

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
- **Framework PR: [flutter/flutter#184900](https://github.com/flutter/flutter/pull/184900)** — try/catch guard in both `_compareScreenOrder` overrides (open, awaiting review from @Renzo-Olivares)
- `go_router` PR (app-level workaround): [flutter/packages#11062](https://github.com/flutter/packages/pull/11062) (open, reviewed by @Renzo-Olivares on 2026-03-05 — originally directed framework fix toward the `SelectionContainer.disabled` approach that was later invalidated)
- Upstream analysis comment: [#151536 comment 4225683042](https://github.com/flutter/flutter/issues/151536#issuecomment-4225683042) — repro + mechanism + initial fix direction (later revised)
- Upstream follow-up: [#151536 comment 4227118235](https://github.com/flutter/flutter/issues/151536#issuecomment-4227118235) — retracts the initial direction and points at the open framework PR
- Prior art: [PR #157996](https://github.com/flutter/flutter/pull/157996) (Gustl22, self-closed incomplete draft), [PR #158918](https://github.com/flutter/flutter/pull/158918) (Gustl22, diagnostic draft)
- Active maintainer: @Renzo-Olivares
- No in-flight competitor PR as of 2026-04-11

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

Deep review of the route-level `SelectionContainer.disabled` approach
found it fundamentally flawed: `SelectionArea` / `SelectableRegion`
install their own `SelectionContainer(registrar: this, ...)` inside the
route (`selectable_region.dart:1944`) that shadows any outer disabled
scope. The research converged on the `_compareScreenOrder` try/catch
guard as the viable upstreamable fix — see "Why NOT route-level
`SelectionContainer.disabled`" above.

### April 2026 — framework PR submitted

[flutter/flutter#184900](https://github.com/flutter/flutter/pull/184900)
opened on 2026-04-10 with the try/catch guard implementation. Both
`_compareScreenOrder` overrides are guarded (`selectable_region.dart:2565` in
`MultiSelectableSelectionContainerDelegate`, `text.dart:1304` in
`_SelectableTextContainerDelegate`). Six tests land with it: two widget-level
regression guards (one per file) plus four mock-based red/green tests (one
`StateError` + one `AssertionError` case per guarded method) that directly
exercise the catch branches via throwing `Selectable` mocks. `flutter analyze --flutter-repo`
clean, all affected suites green locally, both commits GPG-signed. Awaiting
review from @Renzo-Olivares. A follow-up comment on #151536
([comment 4227118235](https://github.com/flutter/flutter/issues/151536#issuecomment-4227118235))
retracts the original `_ModalScopeState.build()` proposal and points at the
actual PR.

## Detailed analysis

- [`investigation/2026-04-10_verification.md`](investigation/2026-04-10_verification.md) — stack traces for approaches A, B, C and the `opaque: false` isolation test
