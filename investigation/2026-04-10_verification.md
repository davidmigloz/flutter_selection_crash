# 2026-04-10 verification — G0 + G_A.1 results

**Repo:** flutter_selection_crash
**Base (main):** 8f4ab38 (includes approaches A–H)
**Isolation branch:** fix/non-opaque-selectable-page @ 61b1c6d003f5e0f792ea9e57a53128fe42fd4c36
**Verified by:** David on Flutter 3.41.6 stable, dart2wasm, Chrome
**Related production issue:** `StateError: RenderBox was not laid out` — 640+ events across 5+ users in a production Flutter web app
**Related Flutter issue:** [flutter/flutter#151536](https://github.com/flutter/flutter/issues/151536)

## Summary

**G0 pass ✅ — G_A.1 pass ✅.** All three approaches (A, B, C) reproduce the crash reliably on current stable Flutter (3.41.6 / dart2wasm). Each hits a different code path inside `MultiSelectableSelectionContainerDelegate._compareScreenOrder`, proving this is a family of bugs sharing one root cause: `_RenderTheater` intentionally skips laying out obscured `OverlayEntry`s while their `SelectionContainerDelegate` keeps processing registered selectables whose `RenderBox`es therefore have no size.

> **Note:** These approaches were originally numbered E, G, H during the investigation (which tested 8 approaches A–H). The 5 non-crashing approaches (old A, B, C, D, F) have been removed. The remaining three were renumbered A, B, C.

**Wrapping the top overlay entry in a non-opaque Page (`opaque: false`) fixes Approach C.** The bottom entry remains laid out, the sort has valid RenderBoxes, no crash. This proves the mechanism — but `opaque: false` is not production-ready for full-screen routes (causes visual overlap). The production workaround uses a route-aware `SelectionArea` toggle (`ModalRoute.isCurrent` + `SelectionContainer.disabled`) which deregisters selectables before the route goes offstage without changing route opacity.

## G0 results — baseline on `main`

| Approach | Crashed? | Thrower | Delegate | Stack top |
|---|---|---|---|---|
| **A: Overlay entries (Gustl22)** | ✅ **crash** | `RenderParagraph.size` via `paintBounds` | `MultiSelectableSelectionContainerDelegate` | `_SelectionContainerState.boundingBoxes` → `_getBoundingBox` → `_compareScreenOrder` |
| **B: Overlay + CustomScrollView + WidgetSpans** | ✅ **crash** | `RenderParagraph` `!debugNeedsLayout` via `getBoxesForSelection` | `_SelectableTextContainerDelegate` (text.dart) | `_SelectableFragment.boundingBoxes` → `_SelectableTextContainerDelegate._compareScreenOrder` → `Sort._insertionSort` |
| **C: Navigator deep-link (nested routes)** | ✅ **crash** | `RenderFractionalTranslation.size` via `applyPaintTransform` | `MultiSelectableSelectionContainerDelegate` | `RenderObject.getTransformTo` → `_SelectionContainerState.getTransformTo` → `_compareScreenOrder` |

### What each crash tells us

**Approach A — the exact production stack trace.**
```
RenderBox.size                                 (box.dart:2251)
RenderBox.paintBounds                          (box.dart:3109)
_SelectionContainerState.boundingBoxes         (selection_container.dart:218)
MultiSelectableSelectionContainerDelegate._getBoundingBox   (selectable_region.dart:2551)
MultiSelectableSelectionContainerDelegate._compareScreenOrder (selectable_region.dart:2566)
```
Matches the Sentry stack trace frame-for-frame. This is the canonical minimal repro for #151536 and the Phase 7 framework PR.

**Approach B — the `text.dart` variant (different delegate).**
```
RenderParagraph.getBoxesForSelection           (paragraph.dart:1070 -- !debugNeedsLayout)
_SelectableFragment.boundingBoxes              (inline in text.dart)
_SelectableTextContainerDelegate._compareScreenOrder (text.dart)
Sort._insertionSort                            (sort.dart)
```
**Critical finding:** this is a *different delegate* (`_SelectableTextContainerDelegate`, not `MultiSelectableSelectionContainerDelegate`). It lives in `packages/flutter/lib/src/widgets/text.dart` alongside the 4 unguarded `.first` callers at lines 1069, 1071, 1307–1308, 1407 that the adversarial review enumerated. This crash is concrete proof that the rejected **Option 2 fix** (change `SelectionContainerState.boundingBoxes` to return `[]`) would have merely *moved* the crash here instead of fixing it. Fix B (short-circuit `_flushAdditions`/`_compareScreenOrder` when the delegate's host has `!hasSize`) correctly handles this path because it bails out before *any* comparator runs — whether that comparator would have called `boundingBoxes` or `getBoxesForSelection`.

**Approach C — the `getTransformTo` variant (same delegate, sibling path).**
```
RenderBox.size                                 (box.dart:2251)
RenderFractionalTranslation.applyPaintTransform (proxy_box.dart:3147)
RenderObject.getTransformTo                    (object.dart:3579)
_SelectionContainerState.getTransformTo        (selection_container.dart:208)
MultiSelectableSelectionContainerDelegate._compareScreenOrder (selectable_region.dart:2566)
```
Same delegate and method as Approach A, but the throw happens inside `getTransformTo` rather than `_getBoundingBox`. The comparator calls both sequentially:
```dart
final Rect rectA = MatrixUtils.transformRect(
  a.getTransformTo(null), _getBoundingBox(a));
```
Either can throw if the RenderBox is unlaid-out. Any fix that handles one must also handle the other. **Fix B handles both** because it short-circuits before the comparator runs.

## G_A.1 result — isolation test on `fix/non-opaque-selectable-page`

| Approach | Crashed? |
|---|---|
| C (top `MaterialPage` replaced with `_NonOpaquePage`) | ❌ **no crash** |

**Verdict: G_A.1 PASS.** The `opaque: false` mechanism prevents `_RenderTheater` from skipping the bottom entry's layout pass. When the bottom is laid out, `_compareScreenOrder` finds valid sizes and transforms for both selectables, the sort succeeds, and the crash does not fire.

## Implications for the plan

### Production workaround
- **`opaque: false` proves the mechanism but is not production-ready** for full-screen routes (causes visual overlap — parent route painted behind child).
- **Production workaround shipped:** `_RouteAwareSelectionArea` — uses `ModalRoute.of(context)?.isCurrent` to toggle between `SelectionArea` (when current) and `SelectionContainer.disabled` (when covered). Routes stay opaque. `GlobalKey` + `KeyedSubtree` preserves child state. Same pattern as [flutter/packages#11062](https://github.com/flutter/packages/pull/11062).

### Upstream (Phase 5–7)
- **Approach A is the minimum viable framework repro.** Minimal: two `OverlayEntry` objects, a handful of `Text` widgets under a `SelectionArea`. Exact production stack trace. Single screenful.
- **Approach B is the text.dart variant.** Proves the `_SelectableTextContainerDelegate` is vulnerable too (rules out Option 2 fix).
- **Approach C is the proof-of-concept fix path.** Branch `fix/non-opaque-selectable-page` demonstrates that preventing `_RenderTheater` layout-skip eliminates the crash. Note: `opaque: false` is NOT the production workaround (visual overlap); the production fix uses `ModalRoute.isCurrent` + `SelectionContainer.disabled` (see above).
- **Fix approach: Fix B remains primary.** Short-circuit `_compareScreenOrder` (or its caller `_flushAdditions`) if the delegate's own host RenderBox has `!hasSize`. This covers all three crashing code paths (`_getBoundingBox`, `boundingBoxes`, `getTransformTo`) because the guard runs before any comparator touches a potentially-unlaid-out child.

## Companion artifacts in this directory

- `framework_line_numbers.md` (from W0.4) — verified line numbers on current Flutter master; zero drift from stable 3.41.6 means the fix plan targets do not need adjustment.
- `upstream_research.md` (from W0.3) — current state of #151536 and related issues/PRs; Renzo-Olivares is the active maintainer; no in-flight competitor PR; Gustl22 has moved on to other work.
