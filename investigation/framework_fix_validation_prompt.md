# Deep Research Prompt: Validate Framework Fix Assumptions

Used to validate assumptions for the flutter/flutter#151536 framework PR before implementation.

---

Thoroughness: **very thorough**. READ-ONLY — no edits.

## Background

We are preparing a PR for the Flutter framework to fix [flutter/flutter#151536](https://github.com/flutter/flutter/issues/151536): `StateError: Bad state: RenderBox was not laid out` thrown from `SelectableRegion._flushAdditions` when `_RenderTheater` skips laying out a non-current route's `OverlayEntry` while its `SelectionContainerDelegate` still processes registered selectables.

The proposed fix: add a `_SelectionScopeForRoute` widget inside `_ModalScopeState.build()` in `packages/flutter/lib/src/widgets/routes.dart` that wraps the route content in `SelectionContainer.disabled` when `!widget.route.isCurrent`. This prevents selectables from registering with the delegate before the route goes offstage.

**Your job is to validate or invalidate every assumption below.** Be adversarial. If something doesn't hold, say so clearly.

The Flutter framework source is at `/Users/davidmigloz/repos/flutter-master` (verified at Flutter 3.43.0-1.0.pre-548).

---

## Assumption 1: `_routeSetState` triggers a rebuild BEFORE `_RenderTheater` skips layout

**Claim:** When a new route is pushed, the old route's `isCurrent` goes from `true` to `false`. `_routeSetState` calls `setState`, which marks the old `_ModalScopeState` dirty. The rebuild runs in the build phase, BEFORE the layout phase where `_RenderTheater` decides to skip the covered entry's layout. Therefore, `SelectionContainer.disabled` takes effect (descendants deregister) before any layout-skip can cause the crash.

**Verify:**
1. Read `_routeSetState` in `routes.dart` (~line 1165) and trace what calls it. Is it called synchronously during the push, or asynchronously?
2. Read `Navigator`'s route push logic. When does the old route's `_ModalScopeStatus.isCurrent` update? Is it in the same frame as the push, or deferred?
3. Read `_RenderTheater.performLayout()` or equivalent in `packages/flutter/lib/src/widgets/overlay.dart`. When does it decide to skip laying out obscured entries? Is that in the layout phase (after build)?
4. **Critical question:** Is there a window where `_flushAdditions` can fire via `scheduleMicrotask` BETWEEN the old route's build (where `SelectionContainer.disabled` would be applied) and the layout-skip decision? If yes, the fix has a race condition.

---

## Assumption 2: `SelectionContainer.disabled` causes descendants to deregister

**Claim:** When a `SelectionContainer.disabled` is inserted above selectables in the tree, the `SelectionRegistrarScope` provides a null registrar, causing descendants (like `_SelectionContainerState`) to deregister from their parent delegate via `registrar = null` in `didChangeDependencies`.

**Verify:**
1. Read `_SelectionContainerState.didChangeDependencies()` in `selection_container.dart`. Does it check `SelectionContainer.maybeOf(context)` and deregister from the old registrar if the new one is null?
2. Read `SelectionRegistrant` mixin (used by `_SelectionContainerState`). What happens when the `registrar` setter is called with null? Does it call `remove(this)` on the old registrar?
3. Does this deregistration happen during the build phase (synchronously) or is it deferred?
4. **Critical question:** After `SelectionContainer.disabled` takes effect, are ALL selectables in the subtree guaranteed to be deregistered before the next `_flushAdditions` fires?

---

## Assumption 3: The `GlobalKey + KeyedSubtree` pattern preserves state across the toggle

**Claim:** When `_SelectionScopeForRoute.build()` toggles between `KeyedSubtree(key: _childKey, child: X)` (when current) and `SelectionContainer.disabled(child: KeyedSubtree(key: _childKey, child: X))` (when not current), the `GlobalKey` causes Flutter to reparent the `KeyedSubtree` element instead of recreating it, preserving all descendant state.

**Verify:**
1. Does Flutter's element reconciliation actually reparent `GlobalKey` children when a new parent widget is inserted above them? Trace the code in `framework.dart` for `GlobalKey` reparenting.
2. Are there any constraints on `GlobalKey` reparenting (e.g., must be in the same `Owner`, can't cross certain boundaries)?
3. **Test this claim:** Find any existing test in the Flutter framework that verifies `GlobalKey` reparenting preserves state when a wrapper widget is added/removed. If none exists, note that.
4. Does `_ModalScopeState` already use a key (`widget.route._subtreeKey` at ~line 1229) on the inner `RepaintBoundary`? If so, does that key already handle state preservation, making the `GlobalKey` in `_SelectionScopeForRoute` redundant?

---

## Assumption 4: Inserting the widget between `_ModalScopeStatus` and `Offstage` is the right position

**Claim:** The `_SelectionScopeForRoute` should be inserted as a child of `_ModalScopeStatus` and parent of `Offstage` (around line 1191).

**Verify:**
1. Read the build method tree carefully. What is the exact nesting at this point? Is there anything between `_ModalScopeStatus` and `Offstage` that we'd be disrupting?
2. Does `Offstage` at line 1191 already affect selection? Read `Offstage.build()` or `_RenderOffstage` — does it do anything with `SelectionRegistrar`? (The old investigation at `flutter_selection_bug/INVESTIGATION.md` says "Offstage still lays out children" — verify this is still true.)
3. Would it be better to insert BELOW `Offstage` instead of above? The selection guard needs to take effect before `_RenderTheater` skips layout, but `Offstage` is about the route's own offstage flag (used during hero flights), not about `_RenderTheater`'s layout-skip. Think about which semantic is more correct.
4. Is `_ModalScopeStatus` (line 1185) the child of `AnimatedBuilder` (line 1176)? If so, our insertion point is inside a `const` subtree passed as `child:` to `AnimatedBuilder` — this is rebuilt only when `_routeSetState` is called, NOT on every animation tick. **Verify that `_routeSetState` IS called when `isCurrent` changes** so our widget actually gets the updated value.

---

## Assumption 5: `isCurrent` is the right signal (not `offstage` or something else)

**Claim:** `widget.route.isCurrent` is the correct signal for when to disable selection. `route.offstage` is NOT correct because it's primarily toggled during hero flights, not for route-stack coverage.

**Verify:**
1. Read `ModalRoute.offstage` — when is it set to `true`? Is it only during hero flights, or also when a route is covered by an opaque route above it?
2. Read `ModalRoute.isCurrent` — confirm it returns `false` when another route is pushed on top.
3. Are there cases where `isCurrent` is `false` but the route should STILL have selection active? (e.g., a transparent dialog/bottom sheet on top — the route below is visible and the user might want to select text through it.)
4. Are there cases where `isCurrent` is `true` but the route should NOT have selection active? (e.g., during a transition animation where the route is the top but not yet visible.)
5. **Critical: for the dead-zone bug (#182573),** stale selectables in non-current routes intercept drag events. Does disabling selection for ALL non-current routes potentially break the case where a non-opaque route (dialog) sits on top and the user wants to select text on the route below?

---

## Assumption 6: No existing framework mechanism already handles this

**Claim:** There is no existing code in the framework that disables selection for non-current routes.

**Verify:**
1. Search the entire `packages/flutter/lib/src/widgets/` directory for any existing `SelectionContainer.disabled` or `SelectionRegistrarScope` usage that is gated on route currentness or offstage-ness.
2. Check `Offstage` widget — does it already disable selection for offstage subtrees?
3. Check `Visibility` widget — does it disable selection?
4. Check `TickerMode` — the build method already has `TickerMode` gating (via animation status). Is there a `SelectionMode` or similar?
5. Has any commit since 2025-01-01 added selection-related guards to `routes.dart` or `overlay.dart`?

---

## Assumption 7: The test will actually fail on master and pass with the fix

**Claim:** A test using `Navigator(pages: [page_with_SelectionArea, top_page])` will expose the bug on current master.

**Verify:**
1. Run (mentally trace, since this is read-only) through what happens when `tester.pumpWidget(...)` builds a Navigator with 2 pages where the bottom has `SelectionArea`:
   - Does `_RenderTheater` actually skip layout of the bottom page's overlay entry in the test environment?
   - Does `_flushAdditions` get scheduled and fire during `tester.pump()`?
   - The existing test at line 165 of `selectable_region_test.dart` is very similar and PASSES — why? What's different about it that prevents the crash?
2. Read the existing test at line 165 carefully. It uses `SelectableRegion` directly (not `SelectionArea`). `SelectionArea` creates a `SelectableRegion` with a `MultiSelectableSelectionContainerDelegate` which has the `_flushAdditions` method. Does `SelectableRegion` used directly (without `SelectionArea`) use a different delegate that doesn't have `_flushAdditions`?
3. **Key question:** If the test passes on both master and fix (i.e., the bug can't be reproduced via `tester.pump()`), what alternative test shape can we use to verify the fix? The fallback is a structural test asserting `SelectionContainer.maybeOf(context) == null` inside the non-current route. Would this test FAIL on master (since there's currently no `SelectionContainer.disabled` in the framework for non-current routes)?

---

## Output format

For each assumption (1–7), report:
- **Verdict:** VALID / INVALID / PARTIALLY VALID
- **Evidence:** specific file paths, line numbers, and code snippets
- **Surprise findings:** anything that changes the fix plan
- **Risk level:** LOW / MEDIUM / HIGH — how likely is this assumption to cause the fix to fail

End with a **Summary** section: which assumptions hold, which need adjustment, and the single biggest risk to the fix plan. Keep total output under 3000 words.
