# Validating the `_SelectionScopeForRoute` fix for flutter#151536

The proposed fix correctly identifies the root cause — **selectables register during the build phase but `_RenderTheater` skips their layout**, causing `_flushAdditions` to crash when sorting by screen order — but it uses the wrong gating signal. Wrapping with `SelectionContainer.disabled` when `!isCurrent` will break text selection beneath non-opaque routes like dialogs and bottom sheets. Five of seven assumptions hold; two carry material risk.

---

## Assumption 1: Rebuild timing precedes layout skipping

**Verdict: VALID** | Risk: Low

The timing chain works exactly as assumed. When `NavigatorState.push()` fires, `_flushHistoryUpdates()` runs synchronously, calling `didChangeNext()` on the old route, which triggers `changedInternalState()` → `ModalRoute.setState()` → `_routeSetState()` → `setState()`. This marks the `_ModalScopeState` dirty. The key guard in `changedInternalState()` at `routes.dart` only skips the call during `SchedulerPhase.persistentCallbacks` (layout/paint phase), and a normal push runs during `idle`, so the guard passes.

The build phase processes all dirty elements synchronously before `_RenderTheater.performLayout()` runs. The theater computes `skipCount` in `OverlayState.build()` by iterating entries in reverse, counting until it hits an opaque entry, then passes `skipCount = children.length - onstageCount` to `_Theater`. During layout, the first `skipCount` children simply never receive `child.layout()`.

**The race condition is real but well-defined.** During build, selectables in the old route register with their delegate's `add()` method, which appends to `_additions` and calls `_scheduleSelectableUpdate()`. That method calls `SchedulerBinding.instance.addPostFrameCallback(runScheduledTask)` (unless already in `postFrameCallbacks` phase, where it uses `scheduleMicrotask`). The post-frame callback fires **after** layout and paint complete. By then, `_RenderTheater` has skipped layout for offstage children, and `_flushAdditions()` calls `_compareScreenOrder()` → `getTransformTo(null)` → accesses `size` on an unlaid-out `RenderBox`, throwing the `StateError`.

---

## Assumption 2: `SelectionContainer.disabled` forces synchronous deregistration

**Verdict: VALID** | Risk: Low

The deregistration chain is fully synchronous. `SelectionContainer.disabled` sets both `registrar` and `delegate` to `null` (`selection_container.dart` ~line 60). Its `build()` method returns `SelectionRegistrarScope._disabled(child: widget.child)`, which provides a **null registrar** via the `InheritedWidget`. When this `SelectionRegistrarScope` replaces the prior one, the framework calls `didChangeDependencies()` on all dependent render objects. Each `SelectionRegistrant` mixin's `registrar` setter runs synchronously: it calls `_removeSelectionRegistrarSubscription()`, which executes `_registrar!.remove(this)` on the old registrar immediately (`rendering/selection.dart` ~line 296).

**A critical safety net exists in the delegate.** The `remove()` method in `MultiSelectableSelectionContainerDelegate` (`selectable_region.dart` ~line 2410) first checks `_additions.remove(selectable)`. If the selectable was added in the same frame and hasn't been flushed yet, it's removed from `_additions` and the method returns early — **no geometry update needed, no crash possible**. This means even if `_flushAdditions` is already scheduled, the selectable won't be in `_additions` when it runs.

Deregistration is guaranteed to complete before `_flushAdditions` fires because the entire build phase is a single synchronous `buildScope()` call. Post-frame callbacks and microtasks cannot interleave with it.

---

## Assumption 3: GlobalKey reparenting preserves state through the wrapper toggle

**Verdict: VALID** | Risk: Low

Flutter's `inflateWidget()` in `framework.dart` (~line 4556) checks for inactive elements matching a `GlobalKey` via `_retakeInactiveElement()`. When a new wrapper widget is inserted above a `GlobalKey`-ed child, the reconciliation path is: parent's `updateChild` finds the old element can't update (different `runtimeType`), calls `deactivateChild`, then `inflateWidget` for the new wrapper. The wrapper's own `updateChild` calls `inflateWidget` for the `GlobalKey` child, finds the just-deactivated element, and calls `_activateWithParent()` to graft it under the new parent. **State objects survive intact.**

`_ModalScopeState.build()` already uses `widget.route._subtreeKey` (a `GlobalKey`) on the inner `RepaintBoundary`. This key anchors the entire page content subtree. When the proposed `_SelectionScopeForRoute` wrapper toggles between `SelectionContainer.disabled` and a pass-through, the `GlobalKey` ensures the `RepaintBoundary` and its descendants are reparented rather than recreated.

The framework enforces that reparenting must happen within the same animation frame (`GlobalKey` docs, `framework.dart` ~line 130). The toggle occurs within a single `_routeSetState` rebuild, satisfying this constraint. The test `reparent_state_harder_test.dart` (164 lines, regression test for issue #5588) validates complex `GlobalKey + KeyedSubtree` reparenting scenarios, confirming the pattern is battle-tested.

---

## Assumption 4: The insertion point between `_ModalScopeStatus` and `Offstage` is correct

**Verdict: PARTIALLY VALID** | Risk: Medium

The exact nesting in `_ModalScopeState.build()` is:

1. `AnimatedBuilder` (outer, watches `restorationScopeId`)
2. → `RestorationScope` (inside builder callback)
3. → `_ModalScopeStatus` (the `child:` parameter of the outer AnimatedBuilder)
4. → `Offstage`
5. → `PageStorage` → `Builder` → `Actions` → `FocusScope` → `RepaintBoundary` (with `_subtreeKey`) → `AnimatedBuilder` (inner, watches animations)

The `_ModalScopeStatus` is passed as `child:` to the outer `AnimatedBuilder`, making it a "const-like" subtree that only rebuilds when `_ModalScopeState.setState()` runs — which **is** triggered when `isCurrent` changes (confirmed via the `changedInternalState()` → `setState()` → `_routeSetState()` chain). So the proposed insertion point will correctly receive updated `isCurrent` values.

**However, `Offstage` itself has no selection interaction.** `RenderOffstage` does not reference `SelectionRegistrar` at all. It only conditionally skips layout, hit-testing, painting, and semantics. This means inserting above or below `Offstage` is functionally equivalent for selection purposes. Inserting **below** `Offstage` would be marginally more precise (only affecting the on-stage subtree), but either position works. The risk here is architectural clarity rather than correctness.

**Surprise finding:** The `_ModalScopeStatus` carries `isCurrent`, `canPop`, `impliesAppBarDismissal`, `opaque`, and the `route` object itself. It's an `InheritedModel<_ModalRouteAspect>` supporting aspect-based dependency tracking. The proposed widget could read `isCurrent` from `_ModalScopeStatus` via `ModalRoute.isCurrentOf(context)` rather than receiving it as a constructor parameter, but doing so would create an unnecessary dependency cycle since the widget sits above `_ModalScopeStatus`'s child.

---

## Assumption 5: `isCurrent` is the right gating signal

**Verdict: PARTIALLY VALID** | Risk: **HIGH**

`Route.isCurrent` is a computed property (`navigator.dart`) that checks whether this route is the last present entry in `_history`. It becomes `false` immediately when any route — opaque or transparent — is pushed on top.

**This is too aggressive.** Consider these scenarios where `isCurrent` is `false` but selection should remain active:

- **Non-opaque dialogs** (`showDialog` with `barrierDismissible: true`, transparent background): the route below is fully visible and interactive through the barrier gaps
- **Bottom sheets** (`showModalBottomSheet`): text on the parent route remains visible above the sheet
- **Popup routes and dropdown menus**: the parent route is visible and selection should work
- **Custom `PageRoute` with `opaque: false`**: explicitly designed to show content below

The actual layout-skip only happens when `OverlayEntry.opaque` is `true` for the covering entry. The `_RenderTheater` skips layout based on `skipCount`, which is computed from overlay entry opacity — **not** from `isCurrent`. Meanwhile, `ModalRoute.offstage` is only set transiently during hero measurement flights and cannot serve as the signal either.

**The correct signal would be tied to whether `_RenderTheater` will actually skip layout** — something like checking whether the route's overlay entries are in the "offstage" portion of the theater's children. Alternatively, the fix could check `!widget.route.isCurrent && widget.route.opaque` of the covering route, or better yet, patch `_flushAdditions` itself to guard against unlaid-out render objects.

---

## Assumption 6: No existing framework mechanism handles this

**Verdict: VALID** | Risk: None (confirms a gap)

A thorough search confirms **no existing selection-disabling mechanism** exists for obscured routes:

- `routes.dart` does not import `selection_container.dart` and contains zero selection-related code
- `overlay.dart` contains no `SelectionContainer.disabled` or `SelectionRegistrarScope` usage
- `Offstage` (`RenderOffstage`) has no selection interaction — it only affects layout, paint, hit-test, and semantics
- `Visibility` widget does not import any selection files and wraps children only in `ExcludeFocus`, `IgnorePointer`, `TickerMode`, and `Offstage`
- `TickerMode` is purely about `AnimationController` muting; no selection analog exists
- **No `SelectionMode` widget exists anywhere** in the framework — this is a notable gap in the `TickerMode`/`ExcludeFocus`/`Offstage` family of subtree-control widgets
- No commits since January 2025 add selection guards to routes or overlay code

---

## Assumption 7: The test will reproduce the crash on master

**Verdict: PARTIALLY VALID** | Risk: Medium

Both `SelectableRegion` (used directly) and `SelectionArea` (Material wrapper) use `StaticSelectionContainerDelegate`, which extends `MultiSelectableSelectionContainerDelegate`. The `_flushAdditions` method and `_compareScreenOrder` crash path exist in both. So **the delegate type is not a differentiator** — the test widget choice doesn't matter for delegate behavior.

**Reproducing the crash requires `_RenderTheater` to skip layout.** A simple `tester.pumpWidget` with a `Navigator` containing two `Page`s where the bottom page has a `SelectionArea` should work: the bottom page's overlay entry will be offstage (skipCount covers it), its selectables register during build, and `_flushAdditions` fires as a post-frame callback. The crash should manifest if `tester.pump()` processes the post-frame callbacks in the same pump cycle.

**However**, a structural assertion test is more robust. Testing that `SelectionContainer.maybeOf(context)` returns `null` inside a non-current route's subtree would verify the fix's mechanism without depending on the crash timing. This approach validates the fix's intent (deregistration) rather than the symptom (crash), and is less fragile across future framework changes.

**Surprise finding:** Issue #182573 could not be found on GitHub. It may not yet exist, may be internal, or may reference a different repository.

---

## Summary

| # | Assumption | Verdict | Risk |
|---|-----------|---------|------|
| 1 | Rebuild precedes layout skip | **VALID** | Low |
| 2 | `SelectionContainer.disabled` deregisters synchronously | **VALID** | Low |
| 3 | GlobalKey preserves state through toggle | **VALID** | Low |
| 4 | Insertion between `_ModalScopeStatus` and `Offstage` | **PARTIALLY VALID** | Medium |
| 5 | `isCurrent` is the right signal | **PARTIALLY VALID** | **High** |
| 6 | No existing mechanism | **VALID** | None |
| 7 | Test reproduces crash on master | **PARTIALLY VALID** | Medium |

**The fix's core mechanism is sound** — wrapping route content in `SelectionContainer.disabled` will prevent `_flushAdditions` from crashing on unlaid-out render objects by ensuring selectables deregister before the post-frame callback fires. The `remove()` → `_additions.remove()` fast path is an especially elegant safety net.

**The critical flaw is the gating signal.** Using `!isCurrent` disables selection on routes beneath any pushed route, including transparent dialogs, bottom sheets, and popup menus where users expect text selection to work. A safer approach would either (a) gate on whether `_RenderTheater` actually skips layout for this route's entries, (b) guard `_flushAdditions` itself with `hasSize` checks on each selectable before sorting, or (c) introduce a dedicated `SelectionMode` mechanism analogous to `TickerMode` that the overlay manages based on actual visibility state. Option (b) is the lowest-risk fix — a two-line guard in `_compareScreenOrder` that returns `0` when either render object lacks a valid size — and avoids the false-positive suppression problem entirely.