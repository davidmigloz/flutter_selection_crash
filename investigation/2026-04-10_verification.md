# Crash verification — stack traces for approaches A, B, C

**Verified:** 2026-04-10 on Flutter 3.41.6 stable, dart2wasm, Chrome.
**Related Flutter issue:** [flutter/flutter#151536](https://github.com/flutter/flutter/issues/151536)
**Framework PR:** [flutter/flutter#184900](https://github.com/flutter/flutter/pull/184900)

## Summary

All three approaches (A, B, C) in `lib/main.dart` reproduce the crash reliably on current stable Flutter (3.41.6 / dart2wasm). Each hits a different code path inside `_compareScreenOrder`, proving this is a family of bugs sharing one root cause: `_RenderTheater` intentionally skips laying out obscured `OverlayEntry` children while their `SelectionContainerDelegate` keeps processing registered selectables whose `RenderBox`es therefore have no size.

Wrapping the top overlay entry in a non-opaque `Page` (`opaque: false`) fixes Approach C on the companion branch `fix/non-opaque-selectable-page`. The bottom entry stays laid out, the sort has valid `RenderBox`es, no crash. This proves the mechanism — but `opaque: false` is not production-ready for full-screen routes (causes visual overlap, parent painted behind child).

## Baseline crash results

| Approach | Crashed? | Thrower | Delegate | Stack top |
|---|---|---|---|---|
| **A: Overlay entries** | crash | `RenderParagraph.size` via `paintBounds` | `MultiSelectableSelectionContainerDelegate` | `_SelectionContainerState.boundingBoxes` → `_getBoundingBox` → `_compareScreenOrder` |
| **B: Overlay + CustomScrollView + WidgetSpans** | crash | `RenderParagraph` `!debugNeedsLayout` via `getBoxesForSelection` | `_SelectableTextContainerDelegate` (text.dart) | `_SelectableFragment.boundingBoxes` → `_SelectableTextContainerDelegate._compareScreenOrder` → `Sort._insertionSort` |
| **C: Navigator deep-link (nested routes)** | crash | `RenderFractionalTranslation.size` via `applyPaintTransform` | `MultiSelectableSelectionContainerDelegate` | `RenderObject.getTransformTo` → `_SelectionContainerState.getTransformTo` → `_compareScreenOrder` |

### What each crash tells us

**Approach A — the exact production stack trace.**

```
RenderBox.size                                              (box.dart:2251)
RenderBox.paintBounds                                       (box.dart:3109)
_SelectionContainerState.boundingBoxes                      (selection_container.dart:218)
MultiSelectableSelectionContainerDelegate._getBoundingBox   (selectable_region.dart:2551)
MultiSelectableSelectionContainerDelegate._compareScreenOrder (selectable_region.dart:2566)
```

This is the canonical minimal repro for #151536 and the stack the framework PR guards.

**Approach B — the `text.dart` variant (different delegate).**

```
RenderParagraph.getBoxesForSelection                        (paragraph.dart:1070 — !debugNeedsLayout)
_SelectableFragment.boundingBoxes                           (inline in text.dart)
_SelectableTextContainerDelegate._compareScreenOrder        (text.dart:1304)
Sort._insertionSort                                         (sort.dart)
```

Critical finding: this is a **different delegate** (`_SelectableTextContainerDelegate`, not `MultiSelectableSelectionContainerDelegate`). It lives in `packages/flutter/lib/src/widgets/text.dart` and has its own `_compareScreenOrder` override at line 1304 alongside several other unguarded `boundingBoxes.first` callers (e.g., lines 1069, 1071, 1407). This crash is concrete proof that a naive fix of changing `_SelectionContainerState.boundingBoxes` to return an empty list would have merely *moved* the crash to `text.dart` instead of fixing it. A guard at the comparator sort site correctly handles this path because both overrides now short-circuit before the thrown error can escape `_flushAdditions`.

**Approach C — the `getTransformTo` variant (same delegate, sibling path).**

```
RenderBox.size                                              (box.dart:2251)
RenderFractionalTranslation.applyPaintTransform             (proxy_box.dart:3147)
RenderObject.getTransformTo                                 (object.dart:3579)
_SelectionContainerState.getTransformTo                     (selection_container.dart:208)
MultiSelectableSelectionContainerDelegate._compareScreenOrder (selectable_region.dart:2566)
```

Same delegate and method as Approach A, but the throw happens inside `getTransformTo` rather than `_getBoundingBox`. The comparator calls both sequentially:

```dart
final Rect rectA = MatrixUtils.transformRect(
  a.getTransformTo(null), _getBoundingBox(a));
```

Either can throw if the `RenderBox` is unlaid-out. A single try/catch wrapping the whole block covers both.

## `opaque: false` isolation test

On the companion branch `fix/non-opaque-selectable-page`, Approach C's top `MaterialPage` is replaced with a local `_NonOpaquePage` that creates a `PageRouteBuilder(opaque: false, ...)`:

| Approach | Crashed? |
|---|---|
| C (top `MaterialPage` replaced with `_NonOpaquePage`) | **no crash** |

The `opaque: false` mechanism prevents `_RenderTheater` from skipping the bottom entry's layout. When the bottom is laid out, `_compareScreenOrder` finds valid sizes and transforms for both selectables, the sort succeeds, and the crash does not fire. This confirms the root-cause diagnosis but is not the fix — the branch is a proof-of-concept only, because `opaque: false` paints both routes simultaneously.

---

**Update (2026-04-11):** The framework fix shipped as a try/catch guard in **both** `_compareScreenOrder` overrides (`selectable_region.dart:2565` and `text.dart:1304`). The guard catches `StateError` / `AssertionError` thrown from unlaid-out `RenderBox`es and returns `0`, so the sort completes with a stable (if arbitrary) order on the crashing frame. Shipped in [flutter/flutter#184900](https://github.com/flutter/flutter/pull/184900). See [../INVESTIGATION.md](../INVESTIGATION.md) for the full analysis.
