# Validation of Framework Fix Assumptions for flutter/flutter#151536

## Assumption about `_routeSetState` rebuilding before `_RenderTheater` skips layout

**Verdict:** **PARTIALLY VALID**

**Evidence (what is true):**  
`_ModalScopeState._routeSetState` is a thin wrapper that calls `setState(fn)` synchronously on the `_ModalScopeState` instance, then runs the callback (so it *does* mark the element dirty immediately). In `packages/flutter/lib/src/widgets/routes.dart`, `_routeSetState` is:  
```dart
void _routeSetState(VoidCallback fn) => setState(fn);
```  
citeturn2view3

Also, `ModalRoute.setState` delegates to `_scopeKey.currentState!._routeSetState(fn)` when the scope exists (otherwise it still runs `fn()` but cannot rebuild the scope). citeturn31search0

When route relationships change, `NavigatorState._flushHistoryUpdates()` calls `_flushRouteAnnouncement()`, which calls `route.didChangeNext(...)` / `route.didChangePrevious(...)` entries as needed. citeturn35search0  
`ModalRoute.didChangeNext`/`didChangePrevious` explicitly call `changedInternalState()`. citeturn31search0

Separately, `_RenderTheater`’s “skip layout of obscured entries” is a **layout-time** effect: `_RenderTheater._childrenInPaintOrder()` yields only onstage children starting from `_firstOnstageChild` (computed from `skipCount`), and `performLayout()` lays out only those children. Offstage children (the first `skipCount`) are **not** laid out. This is in `packages/flutter/lib/src/widgets/overlay.dart`:  
```dart
Iterable<RenderBox> _childrenInPaintOrder() sync* {
  RenderBox? child = _firstOnstageChild;
  while (child != null) {
    yield child;
    ...
    child = childParentData.nextSibling;
  }
}

void performLayout() {
  ...
  for (final RenderBox child in _childrenInPaintOrder()) {
    if (child != sizeDeterminingChild) {
      layoutChild(child, nonPositionedChildConstraints);
    }
  }
}
```  
citeturn29search0

So: **when** the route rebuild happens, it will occur in a build phase, and `_RenderTheater`’s skip happens in layout after that.

**Evidence (what is not guaranteed / where the assumption overstates):**  
`ModalRoute.changedInternalState()` does **not always** call `setState(...)` (and therefore may not always call `_routeSetState`). It explicitly skips calling `setState` when invoked during `SchedulerPhase.persistentCallbacks` (“build phase” in their comment). citeturn39search0  
This means the “old route is marked dirty” step is not unconditional; it depends on *when* the internal-state change is reported.

Also, the premise “`isCurrent` flips and `_routeSetState` is called because `isCurrent` updated” is slightly misleading: `Route.isCurrent` is a computed getter based on the navigator’s last present route entry. It flips as soon as history changes (no setter), and rebuild scheduling is driven by lifecycle notifications + `changedInternalState`, not by a direct `isCurrent` setter. citeturn33search0turn35search0

**Critical question (microtask window between build and layout):**  
The selection delegate’s scheduling is *not* “microtask between build and layout” in the common path. `MultiSelectableSelectionContainerDelegate._scheduleSelectableUpdate()` schedules `_updateSelectables()` using `SchedulerBinding.instance.addPostFrameCallback` unless already in `SchedulerPhase.postFrameCallbacks`, in which case it uses `scheduleMicrotask`. citeturn30search0  
This means `_flushAdditions()` normally runs **after** layout/paint (post-frame), not between build and layout. The microtask path occurs only when scheduling from within post-frame callbacks. citeturn30search0  
So the specific “microtask race between build and layout-skip decision” is unlikely as framed.

**Surprise findings (changes to fix plan):**  
The crash mechanism is better modelled as: **route subtree is built (maintainState), but `_RenderTheater` skips laying it out; later, a post-frame selection update reads geometry and hits `RenderBox was not laid out`.** That points to *“disable registration before the post-frame update”* rather than *“avoid microtasks between build and layout.”* citeturn29search0turn30search0

**Risk level:** **MEDIUM**  
Because the assumption relies too much on `_routeSetState` being called in all relevant timing scenarios, but `changedInternalState` deliberately avoids `setState` in `persistentCallbacks`. citeturn39search0  
The fix may still be correct, but this particular assumption is not fully reliable as written.

## Assumption that `SelectionContainer.disabled` forces descendants to deregister

**Verdict:** **VALID**

**Evidence:**  
`SelectionContainer.disabled` builds a `SelectionRegistrarScope._disabled` whose `registrar` is `null`. citeturn42search0  
`SelectionContainer.maybeOf(context)` returns the nearest `SelectionRegistrarScope.registrar`, so under a disabled scope `maybeOf` returns `null`. citeturn42search0

Enabled `SelectionContainer`s that are not given an explicit `registrar` update their `registrar` in `didChangeDependencies()` via:  
```dart
if (widget.registrar == null && !widget._disabled) {
  registrar = SelectionContainer.maybeOf(context);
}
```  
So when an ancestor `SelectionRegistrarScope` changes to `registrar=null`, they will set their registrar to `null` in `didChangeDependencies` during rebuild. citeturn42search0

The core “deregister” behaviour is guaranteed by the rendering-layer mixin `SelectionRegistrant` (in `packages/flutter/lib/src/rendering/selection.dart`). When `registrar` changes it calls `_removeSelectionRegistrarSubscription()`, which calls `remove(this)` on the old registrar if currently subscribed:  
```dart
void _removeSelectionRegistrarSubscription() {
  if (_subscribedToSelectionRegistrar) {
    _registrar!.remove(this);
    _subscribedToSelectionRegistrar = false;
  }
}
```  
citeturn36search0

So “registrar becomes null ⇒ remove from old registrar” is explicit and synchronous in the setter path.

**Does deregistration happen synchronously or deferred?**  
The registrar setter performs removal immediately in the same call stack (no scheduling). citeturn36search0  
The *delegate’s consequent rebuild/geometry work* is scheduled by the delegate (post-frame in the normal case), but removal from the registrar is immediate. citeturn30search0turn36search0

**Critical question (are all selectables guaranteed deregistered before the next `_flushAdditions` fires?):**  
In the delegate, `remove(Selectable)` first tries `_additions.remove(selectable)` and returns early if it was only “added this frame and not yet incorporated”, explicitly preventing a stale flush. citeturn30search0  
Combined with synchronous deregistration and the fact `_flushAdditions` runs post-frame in the typical path, the system is designed so that “disable scope this frame” removes/clears pending additions before the scheduled post-frame update. citeturn30search0turn36search0

**Surprise findings:**  
The `SelectionContainer.disabled` example test asserts the disabled subtree produces no selections, indicating this mechanism is already relied upon by framework tests. citeturn42search2

**Risk level:** **LOW**  
This is implemented directly in framework code and has test coverage for disabled behaviour in isolation. citeturn42search2turn42search4

## Assumption that `GlobalKey + KeyedSubtree` preserves state across the toggle

**Verdict:** **PARTIALLY VALID**

**Evidence (reparenting works):**  
Framework reparenting for `GlobalKey` is real and happens through `_retakeInactiveElement(GlobalKey key, Widget newWidget)` during `updateChild` when a widget with a global key appears in a new location. The code path is in `packages/flutter/lib/src/widgets/framework.dart`:  
- `updateChild` checks `if (key is GlobalKey)` and calls `_retakeInactiveElement(...)`. citeturn37search0  
- `_retakeInactiveElement` removes the old element from its parent (via `forgetChild`/`deactivateChild`) and pulls it from inactive elements to reuse it. citeturn37search0

This supports the claim that if a keyed subtree is removed as a direct child and then reinserted under a new wrapper with the same `GlobalKey`, the element can be retaken and its state preserved.

There are also explicit tests asserting reparenting preserves state, e.g. `reparent_state_test.dart` contains tests like “can reparent state” and checks that `key.currentState` remains the same across moves. citeturn38search1

**Constraints (must mention):**  
Reparenting depends on the `BuildOwner`’s `_globalKeyRegistry` and `_inactiveElements` list: the key’s element must be in the same owner and eligible to be retaken within the same frame’s inactive-element retention window. This is implicit in the `WidgetsBinding.instance.buildOwner!._globalKeyRegistry[...]` usage and the retake-from-owner flow. citeturn37search0

**Potential redundancy in the proposed plan:**  
`_ModalScopeState.build()` already wraps the route page subtree with a keyed `RepaintBoundary` using `widget.route._subtreeKey`. citeturn2view3turn3view0  
That existing global key already provides a state-preserving anchor for (at least) the route “page” subtree. If `_SelectionScopeForRoute` is inserted *above* the `Offstage` subtree and causes element structure churn, this existing `_subtreeKey` may already prevent recreating the page subtree below it, making an additional `GlobalKey` on a `KeyedSubtree` potentially redundant (depending on exactly what you wrap and what you need to preserve).

**Surprise findings:**  
Because `_ModalScopeState` already uses a global key in the route subtree, the fix plan should explicitly justify what additional state needs preserving above/beyond that boundary (e.g., whether anything *above* the keyed `RepaintBoundary` is stateful and important). Otherwise, the extra global key is “belt and braces,” but may be unnecessary complexity. citeturn2view3turn3view0

**Risk level:** **MEDIUM**  
Global key reparenting is solid, but the *assumption of necessity* is questionable due to the existing `_subtreeKey` anchor and because large-scale grafting can have subtle interactions (focus, overlays, portals) even if generally supported. citeturn37search0turn38search1turn39search0

## Assumption that inserting between `_ModalScopeStatus` and `Offstage` is the correct position

**Verdict:** **VALID**

**Evidence (actual nesting and stability):**  
`_ModalScopeState.build()` constructs: `AnimatedBuilder(... child: _ModalScopeStatus(... child: Offstage(... PageStorage(... Builder(... child: ... )))))`. citeturn39search0  
So the insertion point “as a child of `_ModalScopeStatus` and parent of `Offstage`” is structurally real; it would wrap the entire route subtree that is currently inside `Offstage`. citeturn39search0

**Does `Offstage` already affect selection?**  
`RenderOffstage.performLayout` lays out its child even when `offstage` is true:  
```dart
if (offstage) {
  child?.layout(constraints);
} else {
  super.performLayout();
}
```  
citeturn40search0  
And the `Offstage` widget documentation explicitly states it lays out without painting/hit testing. citeturn40search2  
So “Offstage still lays out children” remains true; Offstage is not the mechanism causing “RenderBox not laid out” in the reported crash—Overlay’s `_RenderTheater` skipCount is. citeturn40search0turn29search0

**Would inserting below `Offstage` be better?**  
From a correctness perspective for #151536, the “selection guard” must be applied when the route is built but may not be laid out due to overlay skip. Since Offstage does *not* stop layout, placing the guard relative to Offstage does not address the overlay skip mechanism directly. The key benefit of placing it above Offstage is that it wraps everything in the route subtree uniformly and is controlled by the route’s own status object. citeturn39search0turn40search0turn29search0

**Is `_ModalScopeStatus` inside a cached `child:` of `AnimatedBuilder` and will it update on `isCurrent` changes?**  
Yes: `_ModalScopeStatus` is passed as the `child:` parameter to an `AnimatedBuilder`. The comment beside the `isCurrent` argument explicitly states:  
```dart
isCurrent: widget.route.isCurrent, // _routeSetState is called if this updates
```  
citeturn39search0  
That is strong internal evidence that the framework expects `_ModalScopeState` rebuilds to be driven by `_routeSetState` exactly for these values.

**Surprise findings:**  
The insertion position is sensible for scoping, but it does not itself guarantee rebuild timeliness (that depends on route internal-state notification paths discussed under Assumption 1). citeturn39search0turn35search0

**Risk level:** **LOW**  
The structural target is correct and low-risk. The main risk is upstream (whether the rebuild happens in all relevant timing cases). citeturn39search0turn39search0

## Assumption that `isCurrent` is the correct signal to disable selection

**Verdict:** **PARTIALLY VALID**

**Evidence (offstage is not the same thing):**  
`ModalRoute.offstage` is explicitly documented as used for: “On the first frame of a route’s entrance transition, the route is built Offstage using an animation progress of 1.0… [to] let the HeroController determine the final location…” and updated via `set offstage(bool value) { setState(() { _offstage = value; }); ... changedInternalState(); }`. citeturn23search0turn39search0  
This supports the claim that `offstage` is not a “covered by an opaque route above” signal; it is a transition/hero mechanism.

**Evidence (`isCurrent` semantics):**  
`Route.isCurrent` returns true iff this route is the last present route entry in the navigator’s history. citeturn33search0  
So if another route is pushed on top and is present, the previous route’s `isCurrent` becomes false immediately as history changes.

**Where the assumption is weak / adversarial cases:**  
Overlay layout skipping is driven by `OverlayEntry.opaque` (and maintainState), not by `Route.isCurrent`. Overlay builds `_Theater(skipCount: children.length - onstageCount, ...)` where `onstage` flips false after encountering an opaque entry; and `_RenderTheater` then skips layout of the first `skipCount` children. citeturn18search0turn29search0  
Therefore, “non-current route” is **not equivalent** to “route whose overlay subtree will be skipped for layout.” A route can be non-current yet still onstage/laid out (e.g., if the route above is not fully opaque). That means disabling selection for all `!isCurrent` routes can be broader than necessary for preventing “not laid out” crashes. citeturn18search0turn29search0turn33search0  

**About the ‘dead-zone bug (#182573)’ reference:**  
I could not locate public evidence for an issue numbered `#182573` with the described “stale selectables in non-current routes intercept drag events” based on web search in this session. As a result, I cannot validate the premise or the interaction risk for that specific issue ID. (This may be a private tracker item, a future issue number, or a misreference.)

**Surprise findings:**  
A more semantically aligned guard for the crash would be tied to “will this route’s overlay subtree be laid out?” (overlay onstage-ness / skipCount boundary), which is closer to “covered by an opaque entry above” than to `isCurrent`. The proposed use of `isCurrent` may still fix #151536 but risks disabling selection in scenarios where the route is visible/laid out but not current. citeturn18search0turn29search0turn33search0

**Risk level:** **HIGH**  
Because this is the most likely place the fix changes behaviour beyond the crash: the signal may be too coarse compared to the real layout-skip condition. citeturn18search0turn29search0turn33search0

## Assumption that no existing mechanism already disables selection for non-current routes

**Verdict:** **VALID**

**Evidence:**  
`SelectionContainer.disabled` exists and is documented as a manual way to exclude a subtree from selection, but there is no indication (in the inspected framework code/docs) that routes or overlays apply it automatically based on route status. citeturn42search0turn43search3

In `routes.dart` `_ModalScopeState.build()`, the subtree is wrapped in `_ModalScopeStatus` and `Offstage`, plus other routing utilities, but there is no selection-related gating in that structure (no `SelectionContainer`, no `SelectionRegistrarScope`). citeturn39search0

`Offstage` is not a selection-disabling mechanism; it still lays out its child. citeturn40search0turn40search2

**Surprise findings:**  
The selection system documentation itself suggests using `SelectionContainer.disabled` in cases where a group should be excluded, implying that *automatic* exclusion is not generally applied by framework widgets like `Offstage` or routing wrappers. citeturn43search3turn42search0

**Risk level:** **LOW**  
This assumption is consistent with both route build structure and selection docs/tests.

## Assumption that the test will fail on master and pass with the fix

**Verdict:** **INVALID (as stated), with a clear fallback path**

**Evidence (why the proposed reproduction is doubtful):**  
There is already a framework test titled **“Does not crash when using Navigator pages”** in `packages/flutter/test/widgets/selectable_region_test.dart`, explicitly using `Navigator(pages: ...)` and `SelectableRegion` (regression test for another issue). It currently passes, which strongly suggests that a basic “Navigator pages with selectable content behind a top page” shape does **not** deterministically crash. citeturn45search1

Also, the selection delegate update that eventually calls `_flushAdditions()` is usually scheduled as a **post-frame callback**, not during build/layout. citeturn30search0  
This means you only get a crash if, at the time the post-frame callback runs, the delegate processes a selectable whose render object has not been laid out. That typically requires a more specific sequence than “two pages exist”: it needs (a) selectables being added/merged in that frame and (b) layout for that subtree being skipped (e.g., by `_RenderTheater.skipCount`). citeturn30search0turn29search0  
A simple `pumpWidget` with two pages may not create the necessary “additions after becoming offstage” timing.

**Evidence (the ‘SelectableRegion vs SelectionArea delegate difference’ sub-claim is wrong):**  
`SelectableRegion` uses `StaticSelectionContainerDelegate`, which extends `MultiSelectableSelectionContainerDelegate` (the class that has `_flushAdditions` and scheduling). citeturn30search0  
So `SelectableRegion` and `SelectionArea` are not distinguished by “delegate with/without `_flushAdditions`” in the way the assumption suggests.

**Recommended alternative test shape (likely to fail on master and pass with fix):**  
A structural assertion test is the right fallback: build a Navigator with a non-current route subtree that contains a widget which reads `SelectionContainer.maybeOf(context)` and asserts it is `null` when the route is non-current. This would be expected to **fail on master** (no route-level `SelectionContainer.disabled` wrapper exists in routing code) and **pass after the fix**. The fact that `maybeOf` returns null when the nearest scope is disabled is guaranteed by the selection-container implementation. citeturn42search0turn43search3turn39search0

**Surprise findings:**  
The existing “Navigator pages” test passing is an immediate red flag against assuming the new test will reproduce the crash without additional triggering conditions (e.g., a route becoming non-laid-out while additions are pending). citeturn45search1turn30search0

**Risk level:** **HIGH**  
If the PR depends on a crash reproduction test that doesn’t actually fail on current master, the change may be hard to land or may regress later. The structural test fallback is much more reliable.

## Summary

Assumptions that hold strongly:  
- **Assumption 2** is solid: `SelectionContainer.disabled` propagates a null registrar and causes synchronous deregistration via `SelectionRegistrant`, with delegate logic designed to clear same-frame additions before post-frame flushing. citeturn42search0turn36search0turn30search0  
- **Assumption 4** is correct about where `_ModalScopeState.build()` places `_ModalScopeStatus` and `Offstage`, and Offstage indeed still lays out children, so it is not the mechanism behind “RenderBox not laid out.” citeturn39search0turn40search0turn29search0  
- **Assumption 6** is consistent with current framework structure: there is no existing route-level selection disabling mechanism. citeturn39search0turn42search0  

Assumptions needing adjustment:  
- **Assumption 1** is only partially correct: `_routeSetState` is synchronous when invoked, and overlay skip happens in layout, but the framework deliberately avoids calling `setState` from `changedInternalState` during `persistentCallbacks`, so “rebuild always happens before skip” is not a safe invariant as written. Also, `_flushAdditions` is usually post-frame (not between build and layout), so the cited microtask race window is likely mis-framed. citeturn39search0turn30search0turn29search0  
- **Assumption 3** is partially correct: GlobalKey reparenting works and is tested, but the proposed extra GlobalKey wrapper may be redundant because `_ModalScopeState` already uses `widget.route._subtreeKey` on a `RepaintBoundary`. citeturn37search0turn38search1turn2view3turn3view0  
- **Assumption 5** is the most risky: `isCurrent` is a coarse signal relative to the true cause (overlay skipCount / opaque coverage). It may disable selection in cases where a route is not current but still onstage/laid out. citeturn33search0turn18search0turn29search0  
- **Assumption 7** is not supported: a simple Navigator-pages test likely won’t reproduce the crash reliably, and there is already a passing Navigator-pages regression test in `selectable_region_test.dart`. A structural assertion test around `SelectionContainer.maybeOf(context)` is the reliable fallback. citeturn45search1turn42search0  

**Single biggest risk to the fix plan:**  
Using **`!isCurrent`** as the guard condition may be semantically broader than the actual “subtree will not be laid out” condition (which is tied to overlay opacity/skipCount), creating behavioural regressions in edge cases where a non-current route is still onstage/visible. citeturn18search0turn29search0turn33search0