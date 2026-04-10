# Validation of Framework Fix Assumptions for flutter/flutter#151536

The rendering pipeline of the Flutter framework operates on strict phase boundaries, synchronizing the construction of the element tree, the geometric layout of render objects, and the deferred execution of asynchronous microtasks. The proposed architectural intervention to resolve the `StateError: Bad state: RenderBox was not laid out` crash (documented in flutter/flutter#151536) attempts to exploit these phase boundaries by injecting a `SelectionContainer.disabled` wrapper at the route level. This crash occurs specifically within `MultiSelectableSelectionContainerDelegate._flushAdditions` when the framework's `_RenderTheater` bypasses the layout phase for an `OverlayEntry` belonging to a non-current route, leaving active selectables without computed physical geometries.   

Evaluating the proposed pull request requires an exhaustive validation of the mechanical assumptions underpinning the fix. The following analysis systematically assesses the viability, synchronization, and structural integrity of the proposed changes within the `packages/flutter/lib/src/widgets/routes.dart` and related selection libraries.

## Assumption 1: Phase Synchronization and Rebuild Timing

The primary assumption dictates that invoking `_routeSetState` to mark the old `_ModalScopeState` as dirty will trigger a rebuild in the build phase prior to the layout phase where `_RenderTheater` determines whether to skip the covered entry's layout. This sequence is intended to guarantee that `SelectionContainer.disabled` forces a deregistration cascade before any layout-skipping crash condition can materialize.

The Flutter framework definitively executes the build phase prior to the layout phase across all frames. Within `packages/flutter/lib/src/widgets/routes.dart`, the `_routeSetState` function explicitly invokes a synchronous `setState()` on the `_ModalScopeState`. When a new route is pushed onto the `Navigator` stack, the active route's `isCurrent` property is updated synchronously during the push operation. This immediate mutation flags the `_ModalScopeState` element as dirty, ensuring it will be rebuilt during the subsequent synchronous build phase.   

Following the completion of the build phase, the pipeline transitions to the layout phase. It is within this phase that `_RenderTheater.performLayout()` iterates through its associated `OverlayEntry` objects. The theater calculates a skip count based on opaque occlusion. Because the build phase has already inserted the `SelectionContainer.disabled` widget into the tree, the element tree is fully updated before the layout phase begins.   

Crucially, the timing of the `_flushAdditions` method prevents any race conditions. The `MultiSelectableSelectionContainerDelegate` utilizes `scheduleMicrotask` to process selection geometry additions. Microtasks are inherently deferred until the synchronous execution of the current frame (including both build and layout phases) concludes. Consequently, the selectables are deregistered during the build phase, completely circumventing the layout skip, and resulting in an empty queue when the microtask eventually fires.   

| Metric                | Assessment                                                                                                                                                                |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Verdict**           | VALID                                                                                                                                                                     |
| **Risk Level**        | LOW                                                                                                                                                                       |
| **Evidence**          | `routes.dart` (synchronous `setState` in `_routeSetState` ), `selectable_region.dart` (microtask deferral in `_flushAdditions` ).                                         |
| **Surprise Findings** | The rigid segregation between synchronous build/layout phases and deferred microtasks ensures absolute temporal safety. No race conditions exist in this specific vector. |

  

## Assumption 2: Deregistration Cascades via SelectionContainer.disabled

This assumption claims that the insertion of a `SelectionContainer.disabled` widget dynamically forces a `null` registrar to propagate down the tree, resulting in the immediate deregistration of all descendant selectables via `didChangeDependencies`.

The implementation of the `SelectionContainer.disabled` factory constructor explicitly creates a `SelectionContainer` instance where both the `registrar` and `delegate` properties are forcibly assigned to `null`. When this widget replaces the standard container during the build phase, it modifies the `InheritedWidget` hierarchy. All descendant `_SelectionContainerState` instances, alongside any widgets utilizing the `SelectionRegistrant` mixin, are immediately flagged for dependency updates.   

During this same build phase, the framework synchronously triggers `didChangeDependencies()` on these flagged state objects. The `_SelectionContainerState` issues a call to `SelectionContainer.maybeOf(context)`, which intercepts the newly inserted disabled container and returns the `null` registrar. The `SelectionRegistrant` mixin governs the lifecycle of the registration; when its internal `registrar` setter is updated with a `null` value, the mixin immediately and synchronously executes `remove(this)` on the previous registrar reference. This unregistration cascade is entirely synchronous. By the time the build phase yields to the layout phase, all selectables within the subtree have been expunged from the active `MultiSelectableSelectionContainerDelegate`.   

| Metric                | Assessment                                                                                                                                                                   |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Verdict**           | VALID                                                                                                                                                                        |
| **Risk Level**        | LOW                                                                                                                                                                          |
| **Evidence**          | `selection_container.dart` (`SelectionContainer.disabled` constructor ), `selection_registrar.dart` (`SelectionRegistrant` setter logic ).                                   |
| **Surprise Findings** | The `remove(this)` execution is immediate and not deferred to the end of the frame, guaranteeing the internal arrays of the delegate are cleared before layout computations. |

  

## Assumption 3: Element Reconciliation and GlobalKey Reparenting

The proposed fix posits that toggling between a standard `KeyedSubtree` and a `SelectionContainer.disabled` wrapping the same `KeyedSubtree` using a `GlobalKey` will seamlessly reparent the element, preserving all descendant state without destructive consequences.

This assumption reveals a fundamental misunderstanding of Flutter's element reconciliation algorithm and the severe performance penalties associated with `GlobalKey` reparenting. When a wrapper widget is conditionally inserted into the widget tree, the structural depth of the tree is altered. Flutter's `Widget.canUpdate` function evaluates the old and new widgets at a specific tree depth. Because the widget types diverge (a `KeyedSubtree` versus a `SelectionContainer`), `canUpdate` evaluates to `false`.

The framework responds by unmounting the existing `KeyedSubtree` element. Detecting the presence of a `GlobalKey`, the framework detaches the element and caches it via the `forgetChild` mechanism. When the new `SelectionContainer` builds, the framework "reparents" the cached element to the new sub-tree hierarchy via `inflateWidget`. However, the framework documentation explicitly classifies `GlobalKey` reparenting as an exceptionally expensive operation. Reparenting mandates a call to `State.deactivate` on the associated `State` and on *all of its descendants*. Furthermore, it severs all existing `InheritedWidget` dependencies, forcibly triggering full rebuilds across the entire affected sub-tree.   

Implementing this pattern at the route level means that every time a route is pushed or popped, the entire widget tree of the background route will undergo a massive deactivation and rebuild cycle. This will introduce catastrophic UI stutter (jank) precisely during transition animations.

| Metric                | Assessment                                                                                                                                                                                                                              |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Verdict**           | INVALID                                                                                                                                                                                                                                 |
| **Risk Level**        | HIGH                                                                                                                                                                                                                                    |
| **Evidence**          | `framework.dart` (`GlobalKey` reparenting documentation , `forgetChild` and `inflateWidget` execution paths ).                                                                                                                          |
| **Surprise Findings** | Relying on `GlobalKey` reparenting to toggle route states will severely degrade animation performance. A static structural wrapper that dynamically toggles its `delegate` property must be used instead to satisfy `Widget.canUpdate`. |

  

## Assumption 4: Structural Insertion Geometry

The proposal suggests inserting the `_SelectionScopeForRoute` as a child of `_ModalScopeStatus` and as the parent of the `Offstage` widget within `_ModalScopeState.build()`.

The `Offstage` widget is utilized primarily to manage the physical presence of a route during specific rendering sequences, such as hero flight animations, where the route must compute dimensions but remain visually hidden. A critical characteristic of the `Offstage` widget is that it explicitly preserves the active status of its children. Offstage children continue to participate in hit testing, focus traversal, and, crucially, selection propagation.   

If the selection interceptor were placed below the `Offstage` widget, the selection mechanics would theoretically operate correctly. However, placing it above the `Offstage` widget, directly beneath `_ModalScopeStatus`, provides superior semantic coverage. The `_ModalScopeStatus` is nested within a constant subtree provided to an `AnimatedBuilder`, meaning it rebuilds exclusively when `_routeSetState` is invoked due to a route state change, rather than rebuilding indiscriminately on every animation tick. By encapsulating the `Offstage` widget, the `SelectionContainer` ensures that the route's selectables are entirely isolated from the global selection registrar regardless of the route's internal offstage transition flags. This prevents edge-case dead zones where an offstage route might intercept global drag events.   

| Metric                | Assessment                                                                                                                                                          |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Verdict**           | VALID                                                                                                                                                               |
| **Risk Level**        | LOW                                                                                                                                                                 |
| **Evidence**          | `offstage.dart` (hit testing and focus preservation ), `routes.dart` (`_ModalScopeState.build` hierarchy ).                                                         |
| **Surprise Findings** | `Offstage` does not sever selection registrars automatically, validating the need for an explicit `SelectionContainer.disabled` wrapper higher in the element tree. |

  

## Assumption 5: Signal Correctness and Route State

The fix relies on `widget.route.isCurrent` as the deterministic boolean signal to trigger the `SelectionContainer.disabled` wrapper. The assumption explicitly dismisses `route.offstage` as incorrect.

While `offstage` is indeed an incorrect signal, utilizing `isCurrent` introduces a fatal regression regarding transparent routing. The `isCurrent` property strictly evaluates whether a route occupies the top-most position in the `Navigator` stack. Whenever a new route is pushed, the underlying route transitions to `isCurrent == false`.   

However, the Flutter routing system routinely deploys non-opaque routes, explicitly managed via the `opaque` boolean flag. Common UI patterns such as `PopupRoute` (dialogs) and `ModalBottomSheetRoute` are inherently transparent. When a transparent dialog is pushed, the underlying route becomes non-current. Crucially, because the new route is not opaque, `_RenderTheater` does *not* bypass the layout phase for the underlying route. The underlying route remains fully rendered, laid out, and visible.   

If the proposed PR forcefully disables selection based on `!isCurrent`, invoking a simple confirmation dialog will instantaneously annihilate text selection capabilities across the entire visible background page. Users attempting to copy text from the main interface while a bottom sheet is open will interact with an artificial dead zone. The crash condition outlined in issue #151536 is exclusively triggered when `_RenderTheater` skips layout, which only occurs under fully *opaque* overlay entries.

| Metric                | Assessment                                                                                                                                                                                                |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Verdict**           | INVALID                                                                                                                                                                                                   |
| **Risk Level**        | HIGH                                                                                                                                                                                                      |
| **Evidence**          | `routes.dart` (opaque vs transparent route logic ), overlay compositing mechanics (`_RenderTheater` layout skip rules ).                                                                                  |
| **Surprise Findings** | The `isCurrent` property does not map equivalently to layout-skipping. Tying selection capabilities to `isCurrent` will actively break selection mechanics beneath transparent overlays and dialog boxes. |

  

## Assumption 6: Existing Framework Redundancies

The assumption claims that no existing framework mechanism is capable of automatically disabling selection for non-current or obscured routes.

An architectural audit of the `packages/flutter/lib/src/widgets/` libraries confirms the absence of automated, depth-based selection gating. While Flutter provides mechanisms like `TickerMode` to automatically freeze `AnimationController` ticking within offstage subtrees, and `FocusScope` algorithms naturally prioritize top-level routes, the selection architecture lacks a parallel auto-suspension mechanism. The `SelectionContainer.disabled` widget is primarily deployed manually by developers to patch specific localized UX issues, such as preventing scrollable pagination buttons from becoming highlighted during bulk text selection.   

Neither the `Offstage` nor the `Visibility` widgets intrinsically sever the `SelectionRegistrarScope` linkage. Therefore, the introduction of a framework-level intervention to manage selection lifecycle across the routing stack addresses a verified architectural void.   

| Metric                | Assessment                                                                                                                                                     |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Verdict**           | VALID                                                                                                                                                          |
| **Risk Level**        | LOW                                                                                                                                                            |
| **Evidence**          | Structural audits of `visibility.dart` and `offstage.dart` , existing manual implementations of `SelectionContainer.disabled`.                                 |
| **Surprise Findings** | The selection architecture relies heavily on explicit developer containment, making route-level background leaks highly common in complex application layouts. |

  

## Assumption 7: Test Environment Determinism

The final assumption asserts that a standard `WidgetTester` test utilizing `tester.pumpWidget` to push a route over a page containing a `SelectionArea` will reliably reproduce the crash on the master branch, thereby validating the fix.

The execution context of the `WidgetTester` differs substantially from the standard Dart VM event loop. The crash in issue #151536 relies on a specific sequence: the layout is skipped, and subsequently, a microtask fires to evaluate bounding boxes on the skipped geometry. In a live application, `scheduleMicrotask` defers execution to the microtask queue, which is processed after the rendering pipeline yields.   

In a headless test environment, `tester.pump()` explicitly forces synchronous flushes of pending microtasks to maintain deterministic test execution. This aggressive flattening of asynchronous boundaries frequently masks race conditions and deferred execution bugs. While `_RenderTheater` will correctly skip the layout of the background route within the test, the `_flushAdditions` method might execute synchronously within the test binding before the layout phase accurately registers the unlaid-out boxes, leading to a false pass on the master branch. Furthermore, the test must explicitly utilize `SelectionArea`, as instantiating a raw `SelectableRegion` bypasses the `MultiSelectableSelectionContainerDelegate` responsible for the `_flushAdditions` vulnerability.   

To ensure absolute determinism, the test protocol should abandon crash-induction methodologies. Instead, the test should be structural: push an opaque route, extract the `SelectionRegistrar` from a `BuildContext` located within the background route, and explicitly assert that the resolved registrar is `null`.

| Metric                | Assessment                                                                                                                                                                                                               |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Verdict**           | PARTIALLY VALID                                                                                                                                                                                                          |
| **Risk Level**        | MEDIUM                                                                                                                                                                                                                   |
| **Evidence**          | `selectable_region.dart` (`MultiSelectableSelectionContainerDelegate` implementation ), `testWidgets` execution mechanics (`tester.pump` synchronous microtask flushing ).                                               |
| **Surprise Findings** | Asynchronous rendering bugs are notoriously flaky in `WidgetTester` environments. A state-based structural test (`expect(SelectionContainer.maybeOf(context), isNull)`) is mandatory for guaranteed regression tracking. |

  

## Summary

The proposed pull request identifies a genuine lifecycle mismatch between `_RenderTheater` layout skipping and the `SelectionContainerDelegate` geometry evaluations. The foundational mechanics of the proposed fix—specifically the synchronous nature of the build phase updates (Assumption 1), the immediate unlinking of selectables via `null` registrar propagation (Assumption 2), the appropriate semantic insertion point above the `Offstage` widget (Assumption 4), and the lack of existing framework redundancies (Assumption 6)—are entirely sound.

However, the implementation strategy carries two critical architectural flaws that dictate the PR must be heavily revised before integration:

1. **Catastrophic Performance Penalties (Assumption 3):** Utilizing a `GlobalKey` to toggle a `KeyedSubtree` in and out of a `SelectionContainer.disabled` wrapper forces the framework to unmount and reparent the element. This triggers `State.deactivate` across the entire route subtree, resulting in massive, synchronous rebuilds during route transitions. The UI will experience severe jank. The solution is to utilize a permanent `SelectionContainer` that dynamically updates its `delegate` property to `null`, completely bypassing element reparenting.

2. **Fatal UX Regressions (Assumption 5):** Tying the selection suspension logic to the `isCurrent` boolean will actively destroy text selection capabilities for users viewing background routes underneath transparent dialogs or bottom sheets. The crash only occurs when layout is skipped due to coverage by an *opaque* route.

**Ultimate Recommendation:** While tweaking the route-level logic to evaluate opacity and utilizing static wrappers will prevent the crash, this approach remains highly complex and structurally invasive. The most effective, lowest-risk solution is to patch the vulnerability at its exact point of failure. Modifying `MultiSelectableSelectionContainerDelegate._flushAdditions` to explicitly verify \`if (!selectable.hasSize |

\| selectable.debugNeedsLayout) continue;`prior to geometry extraction immediately neutralizes the`StateError\` without requiring any structural manipulations to the routing layer or risking the suppression of valid text selection mechanics.

[![](https://t1.gstatic.com/faviconV2?url=https://github.com/\&client=BARD\&type=FAVICON\&size=256\&fallback_opts=TYPE,SIZE,URL)](https://github.com/flutter/flutter/issues/151536)

[github.com](https://github.com/flutter/flutter/issues/151536)

[\[go\_router\]\[SelectionArea\]: Assertion error on subroutes with SelectionArea and AdaptiveScaffold · Issue #151536 · flutter/flutter - GitHub](https://github.com/flutter/flutter/issues/151536)

[Opens in a new window](https://github.com/flutter/flutter/issues/151536)

[![](https://t1.gstatic.com/faviconV2?url=https://github.com/\&client=BARD\&type=FAVICON\&size=256\&fallback_opts=TYPE,SIZE,URL)](https://github.com/flutter/flutter/issues/125065)

[github.com](https://github.com/flutter/flutter/issues/125065)

[SelectionArea crashes with debugNeedsLayout is not true · Issue #125065 - GitHub](https://github.com/flutter/flutter/issues/125065)

[Opens in a new window](https://github.com/flutter/flutter/issues/125065)

[![](https://t1.gstatic.com/faviconV2?url=https://github.com/\&client=BARD\&type=FAVICON\&size=256\&fallback_opts=TYPE,SIZE,URL)](https://github.com/flutter/flutter/issues/119849)

[github.com](https://github.com/flutter/flutter/issues/119849)

[Flutter 3.7 breaks TextField widgets that wrap MaterialApp.router · Issue #119849 - GitHub](https://github.com/flutter/flutter/issues/119849)

[Opens in a new window](https://github.com/flutter/flutter/issues/119849)

[![](https://t3.gstatic.com/faviconV2?url=https://flutter.googlesource.com/\&client=BARD\&type=FAVICON\&size=256\&fallback_opts=TYPE,SIZE,URL)](https://flutter.googlesource.com/mirrors/flutter/+/refs/tags/3.29.2/packages/flutter/lib/src/widgets/overlay.dart)

[flutter.googlesource.com](https://flutter.googlesource.com/mirrors/flutter/+/refs/tags/3.29.2/packages/flutter/lib/src/widgets/overlay.dart)

[packages/flutter/lib/src/widgets/overlay.dart - mirrors/flutter - Git at](https://flutter.googlesource.com/mirrors/flutter/+/refs/tags/3.29.2/packages/flutter/lib/src/widgets/overlay.dart)

[Opens in a new window](https://flutter.googlesource.com/mirrors/flutter/+/refs/tags/3.29.2/packages/flutter/lib/src/widgets/overlay.dart)

[![](https://t0.gstatic.com/faviconV2?url=https://codebrowser.dev/\&client=BARD\&type=FAVICON\&size=256\&fallback_opts=TYPE,SIZE,URL)](https://codebrowser.dev/flutter/flutter/packages/flutter/lib/src/widgets/selectable_region.dart.html)

[codebrowser.dev](https://codebrowser.dev/flutter/flutter/packages/flutter/lib/src/widgets/selectable_region.dart.html)

[selectable\_region.dart \[flutter/packages/flutter/lib/src/widgets/selectable\_region.dart\] - Codebrowser](https://codebrowser.dev/flutter/flutter/packages/flutter/lib/src/widgets/selectable_region.dart.html)

[Opens in a new window](https://codebrowser.dev/flutter/flutter/packages/flutter/lib/src/widgets/selectable_region.dart.html)

[![](https://t0.gstatic.com/faviconV2?url=https://api.flutter.dev/\&client=BARD\&type=FAVICON\&size=256\&fallback_opts=TYPE,SIZE,URL)](https://api.flutter.dev/flutter/widgets/SelectionContainer/SelectionContainer.disabled.html)

[api.flutter.dev](https://api.flutter.dev/flutter/widgets/SelectionContainer/SelectionContainer.disabled.html)

[SelectionContainer.disabled constructor - Dart API - Flutter](https://api.flutter.dev/flutter/widgets/SelectionContainer/SelectionContainer.disabled.html)

[Opens in a new window](https://api.flutter.dev/flutter/widgets/SelectionContainer/SelectionContainer.disabled.html)

[![](https://t2.gstatic.com/faviconV2?url=https://gitlab.estig.ipb.pt/\&client=BARD\&type=FAVICON\&size=256\&fallback_opts=TYPE,SIZE,URL)](https://gitlab.estig.ipb.pt/a40211/flutter/-/blob/3.16.5/examples/api/lib/material/selection_container/selection_container_disabled.0.dart)

[gitlab.estig.ipb.pt](https://gitlab.estig.ipb.pt/a40211/flutter/-/blob/3.16.5/examples/api/lib/material/selection_container/selection_container_disabled.0.dart)

[examples/api/lib/material/selection\_container/selection\_container\_disabled.0.dart · 3.16.5 · Ernesto Lima Teixeira / flutter - GitLab](https://gitlab.estig.ipb.pt/a40211/flutter/-/blob/3.16.5/examples/api/lib/material/selection_container/selection_container_disabled.0.dart)

[Opens in a new window](https://gitlab.estig.ipb.pt/a40211/flutter/-/blob/3.16.5/examples/api/lib/material/selection_container/selection_container_disabled.0.dart)

[![](https://t0.gstatic.com/faviconV2?url=https://codebrowser.dev/\&client=BARD\&type=FAVICON\&size=256\&fallback_opts=TYPE,SIZE,URL)](https://codebrowser.dev/flutter/flutter/packages/flutter/lib/src/widgets/selection_container.dart.html)

[codebrowser.dev](https://codebrowser.dev/flutter/flutter/packages/flutter/lib/src/widgets/selection_container.dart.html)

[selection\_container.dart \[flutter/packages/flutter/lib/src/widgets/selection\_container.dart\] - Codebrowser](https://codebrowser.dev/flutter/flutter/packages/flutter/lib/src/widgets/selection_container.dart.html)

[Opens in a new window](https://codebrowser.dev/flutter/flutter/packages/flutter/lib/src/widgets/selection_container.dart.html)

[![](https://t0.gstatic.com/faviconV2?url=https://api.flutter.dev/\&client=BARD\&type=FAVICON\&size=256\&fallback_opts=TYPE,SIZE,URL)](https://api.flutter.dev/flutter/rendering/SelectionRegistrant-mixin.html)

[api.flutter.dev](https://api.flutter.dev/flutter/rendering/SelectionRegistrant-mixin.html)

[SelectionRegistrant mixin - rendering library - Dart API - Flutter](https://api.flutter.dev/flutter/rendering/SelectionRegistrant-mixin.html)

[Opens in a new window](https://api.flutter.dev/flutter/rendering/SelectionRegistrant-mixin.html)

[![](https://t1.gstatic.com/faviconV2?url=https://github.com/\&client=BARD\&type=FAVICON\&size=256\&fallback_opts=TYPE,SIZE,URL)](https://github.com/flutter/flutter/issues/90507)

[github.com](https://github.com/flutter/flutter/issues/90507)

['package:flutter/src/widgets/framework.dart': Failed assertion: line 6075 pos 12: 'child == \_child': is not true. #90507 - GitHub](https://github.com/flutter/flutter/issues/90507)

[Opens in a new window](https://github.com/flutter/flutter/issues/90507)

[![](https://t1.gstatic.com/faviconV2?url=https://github.com/\&client=BARD\&type=FAVICON\&size=256\&fallback_opts=TYPE,SIZE,URL)](https://github.com/flutter/flutter/issues/173912)

[github.com](https://github.com/flutter/flutter/issues/173912)

[FormField with Sliver causes exception · Issue #173912 · flutter/flutter - GitHub](https://github.com/flutter/flutter/issues/173912)

[Opens in a new window](https://github.com/flutter/flutter/issues/173912)

[![](https://t0.gstatic.com/faviconV2?url=https://api.flutter.dev/\&client=BARD\&type=FAVICON\&size=256\&fallback_opts=TYPE,SIZE,URL)](https://api.flutter.dev/flutter/widgets/GlobalKey-class.html)

[api.flutter.dev](https://api.flutter.dev/flutter/widgets/GlobalKey-class.html)

[GlobalKey class - widgets library - Dart API - Flutter](https://api.flutter.dev/flutter/widgets/GlobalKey-class.html)

[Opens in a new window](https://api.flutter.dev/flutter/widgets/GlobalKey-class.html)

[![](https://t0.gstatic.com/faviconV2?url=https://api.flutter.dev/\&client=BARD\&type=FAVICON\&size=256\&fallback_opts=TYPE,SIZE,URL)](https://api.flutter.dev/flutter/widgets/ModalRoute/offstage.html)

[api.flutter.dev](https://api.flutter.dev/flutter/widgets/ModalRoute/offstage.html)

[offstage property - ModalRoute class - widgets library - Dart API - Flutter](https://api.flutter.dev/flutter/widgets/ModalRoute/offstage.html)

[Opens in a new window](https://api.flutter.dev/flutter/widgets/ModalRoute/offstage.html)

[![](https://t0.gstatic.com/faviconV2?url=https://api.flutter.dev/\&client=BARD\&type=FAVICON\&size=256\&fallback_opts=TYPE,SIZE,URL)](https://api.flutter.dev/flutter/widgets/Offstage-class.html)

[api.flutter.dev](https://api.flutter.dev/flutter/widgets/Offstage-class.html)

[Offstage class - widgets library - Dart API - Flutter](https://api.flutter.dev/flutter/widgets/Offstage-class.html)

[Opens in a new window](https://api.flutter.dev/flutter/widgets/Offstage-class.html)

[![](https://t0.gstatic.com/faviconV2?url=https://api.flutter.dev/\&client=BARD\&type=FAVICON\&size=256\&fallback_opts=TYPE,SIZE,URL)](https://api.flutter.dev/flutter/widgets/ModalRoute-class.html)

[api.flutter.dev](https://api.flutter.dev/flutter/widgets/ModalRoute-class.html)

[ModalRoute class - widgets library - Dart API - Flutter](https://api.flutter.dev/flutter/widgets/ModalRoute-class.html)

[Opens in a new window](https://api.flutter.dev/flutter/widgets/ModalRoute-class.html)

[![](https://t0.gstatic.com/faviconV2?url=https://api.flutter.dev/\&client=BARD\&type=FAVICON\&size=256\&fallback_opts=TYPE,SIZE,URL)](https://api.flutter.dev/flutter/widgets/Navigator-class.html)

[api.flutter.dev](https://api.flutter.dev/flutter/widgets/Navigator-class.html)

[Navigator class - widgets library - Dart API - Flutter](https://api.flutter.dev/flutter/widgets/Navigator-class.html)

[Opens in a new window](https://api.flutter.dev/flutter/widgets/Navigator-class.html)

[![](https://t0.gstatic.com/faviconV2?url=https://api.flutter.dev/\&client=BARD\&type=FAVICON\&size=256\&fallback_opts=TYPE,SIZE,URL)](https://api.flutter.dev/flutter/material/ModalBottomSheetRoute-class.html)

[api.flutter.dev](https://api.flutter.dev/flutter/material/ModalBottomSheetRoute-class.html)

[ModalBottomSheetRoute class - material library - Dart API - Flutter](https://api.flutter.dev/flutter/material/ModalBottomSheetRoute-class.html)

[Opens in a new window](https://api.flutter.dev/flutter/material/ModalBottomSheetRoute-class.html)

[![](https://t1.gstatic.com/faviconV2?url=https://github.com/\&client=BARD\&type=FAVICON\&size=256\&fallback_opts=TYPE,SIZE,URL)](https://github.com/flutter/flutter/issues/115787)

[github.com](https://github.com/flutter/flutter/issues/115787)

[\[Selection\] How To Avoid \`'!\_selectionStartsInScrollable': is not true.\` assertion when using SelectionArea with scrollable widget. · Issue #115787 - GitHub](https://github.com/flutter/flutter/issues/115787)

[Opens in a new window](https://github.com/flutter/flutter/issues/115787)

[![](https://t1.gstatic.com/faviconV2?url=https://github.com/\&client=BARD\&type=FAVICON\&size=256\&fallback_opts=TYPE,SIZE,URL)](https://github.com/flutter/flutter/issues/124928)

[github.com](https://github.com/flutter/flutter/issues/124928)

[Disable SelectionArea on buttons by default · Issue #124928 · flutter/flutter - GitHub](https://github.com/flutter/flutter/issues/124928)

[Opens in a new window](https://github.com/flutter/flutter/issues/124928)

[![](https://t0.gstatic.com/faviconV2?url=https://api.flutter.dev/\&client=BARD\&type=FAVICON\&size=256\&fallback_opts=TYPE,SIZE,URL)](https://api.flutter.dev/flutter/dart-async/scheduleMicrotask.html)

[api.flutter.dev](https://api.flutter.dev/flutter/dart-async/scheduleMicrotask.html)

[scheduleMicrotask function - dart:async library - Dart API - Flutter](https://api.flutter.dev/flutter/dart-async/scheduleMicrotask.html)

[Opens in a new window](https://api.flutter.dev/flutter/dart-async/scheduleMicrotask.html)

[![](https://t0.gstatic.com/faviconV2?url=https://api.flutter.dev/\&client=BARD\&type=FAVICON\&size=256\&fallback_opts=TYPE,SIZE,URL)](https://api.flutter.dev/flutter/flutter_test/testWidgets.html)

[api.flutter.dev](https://api.flutter.dev/flutter/flutter_test/testWidgets.html)

[testWidgets function - flutter\_test library - Dart API](https://api.flutter.dev/flutter/flutter_test/testWidgets.html)

[Opens in a new window](https://api.flutter.dev/flutter/flutter_test/testWidgets.html)

[![](https://t0.gstatic.com/faviconV2?url=https://api.flutter.dev/\&client=BARD\&type=FAVICON\&size=256\&fallback_opts=TYPE,SIZE,URL)](https://api.flutter.dev/flutter/widgets/MultiSelectableSelectionContainerDelegate-class.html)

[api.flutter.dev](https://api.flutter.dev/flutter/widgets/MultiSelectableSelectionContainerDelegate-class.html)

[MultiSelectableSelectionContain](https://api.flutter.dev/flutter/widgets/MultiSelectableSelectionContainerDelegate-class.html)
