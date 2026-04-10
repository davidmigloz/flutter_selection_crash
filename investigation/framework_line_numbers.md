# W0.4 done — flutter-master refreshed

**Canonical master clone path:** `/Users/davidmigloz/repos/flutter-master`
**Flutter version on master:** `Flutter 3.43.0-1.0.pre-548 • channel master • https://github.com/flutter/flutter.git`
- Framework revision: `c6f719d7a5` (15 hours ago) • 2026-04-09 18:35:05 -0500
- Engine: hash `853a4ec472e4726319f3b6417d5bf199c9a7df32` (revision `b31ab800e8`) • 2026-04-09 23:07:12 UTC
- Tools: Dart 3.13.0 (build 3.13.0-4.0.dev) • DevTools 2.57.0

**Refresh method:** option (a) — in-place pull after switching `origin` URL from SSH (`git@github.com:flutter/flutter.git`) to HTTPS (`https://github.com/flutter/flutter.git`). Fetch and fast-forward pull both succeeded cleanly. Previous HEAD was `032dc5428f` from 2022-06-03 (Flutter 3.1.0-0.0.pre.1091). The local fork remote `davidmigloz` was left untouched.

- Previous HEAD: `032dc5428f35eb651c02530cd1bd7d7f59e6f2ec` (2022-06-03)
- New HEAD: `c6f719d7a523f0a9f7c349b963339a4b268db57d` (2026-04-09, "Skip freeze check in the merge queue (#184854)")
- Working tree clean; no local modifications.
- `./bin/flutter --version` triggered a fresh Dart SDK download + flutter tool build (~6 min on first run) and completed successfully.

## Framework line numbers on current master

### packages/flutter/lib/src/widgets/selectable_region.dart

| Symbol | Master line range | Stable 3.41.6 line range | Drift | Signature / notes |
|---|---|---|---|---|
| `_flushAdditions` | 2462–2511 | 2462–2511 | **0 lines** | `void _flushAdditions()` — identical body: sorts `_additions` by `compareOrder`, merges into `selectables`, updates `currentSelectionStartIndex` / `currentSelectionEndIndex`, preserves the `_additions = <Selectable>{}` reset at the end. |
| `_compareScreenOrder` | 2565–2573 | 2565–2573 | **0 lines** | `static int _compareScreenOrder(Selectable a, Selectable b)` — unchanged: transforms `_getBoundingBox(a)`/`_getBoundingBox(b)` to null ancestor, compares vertically then horizontally. |
| `_getBoundingBox` | 2550–2556 | 2550–2556 | **0 lines** | `static Rect _getBoundingBox(Selectable selectable)` — unchanged: seeds from `selectable.boundingBoxes.first`, then `expandToInclude` over the rest. Still calls `.first` on `boundingBoxes` without a length guard (the crash surface from the bug plan still exists). |
| `_scheduleSelectableUpdate` | 2428–2452 | 2428–2452 | **0 lines** | `void _scheduleSelectableUpdate()` — **microtask branch still present.** Exact shape: guards on `_scheduledSelectableUpdate`, defines nested `runScheduledTask`, then `if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.postFrameCallbacks) { scheduleMicrotask(runScheduledTask); } else { SchedulerBinding.instance.addPostFrameCallback(runScheduledTask, debugLabel: 'SelectionContainer.runScheduledTask'); }`. The `debugLabel` is still on `addPostFrameCallback`. |

Additional call-site references (unchanged): `_scheduleSelectableUpdate()` is invoked at lines 2407 and 2420; `_flushAdditions()` is invoked inside `_updateSelectables()` at line 2457.

### packages/flutter/lib/src/widgets/selection_container.dart

| Symbol | Master line | Stable 3.41.6 line | Drift | Signature / notes |
|---|---|---|---|---|
| `boundingBoxes` getter | 218 | 218 | **0 lines** | **Declared on `_SelectionContainerState` (private class, line 104), not on a publicly named `SelectionContainerState`.** Signature: `List<Rect> get boundingBoxes => <Rect>[(context.findRenderObject()! as RenderBox).paintBounds];`. Returns a fresh single-element list built from `RenderBox.paintBounds`, so at minimum one rect is always present when called post-layout. |
| `containerSize` getter | 327–331 | 327–331 | **0 lines** | Declared on `SelectionContainerDelegate` (abstract class, line 272). Body still has the `assert(hasSize, 'containerSize cannot be called before SelectionContainer is laid out.');` before returning `box.size`. The `hasSize` assert is intact. |
| `hasSize` getter | 315–322 | 315–322 | **0 lines** | Declared on `SelectionContainerDelegate`. Asserts `_selectionContainerContext?.findRenderObject() != null`, casts to `RenderBox`, returns `box.hasSize`. Unchanged. |

Class layout in `selection_container.dart` (master, unchanged from stable):
- Line 44: `class SelectionContainer extends StatefulWidget`
- Line 104: `class _SelectionContainerState extends State<SelectionContainer>` (private; hosts the `boundingBoxes` override at line 218)
- Line 247: `class SelectionRegistrarScope extends InheritedWidget`
- Line 272: `abstract class SelectionContainerDelegate implements SelectionHandler, SelectionRegistrar` (hosts `hasSize`, `containerSize`)

## API changes since stable 3.41.6

**None.** Both target files are byte-identical over the relevant regions between `db50e20168` (stable 3.41.6, 2026-03-25) and `c6f719d7a5` (master, 2026-04-09). Every symbol in the dossier occurs at the exact same line number with the exact same signature and body in both trees. The short (~2 week) window between the stable tag and current master explains the zero drift.

**Phase 7 fix plan does NOT need adjustment.** All assumptions about:
- `_getBoundingBox` calling `.first` on `boundingBoxes` unguarded,
- `_scheduleSelectableUpdate` having the `scheduleMicrotask` vs `addPostFrameCallback` branch,
- `_flushAdditions` merging `_additions` into `selectables` and clearing `_additions` at the end,
- `_SelectionContainerState.boundingBoxes` returning `[RenderBox.paintBounds]`,
- `SelectionContainerDelegate.containerSize` asserting on `hasSize`,

…all hold on current master. Any patch crafted against line numbers 2462–2511 / 2565–2573 / 2550–2556 / 2428–2452 in `selectable_region.dart` and 218 / 315–322 / 327–331 in `selection_container.dart` will apply cleanly to master.

**One nomenclature nit to carry forward:** the plan refers to "`SelectionContainerState.boundingBoxes`"; the actual class name in the framework is `_SelectionContainerState` (private, leading underscore). Any upstream framework PR touching that override must reference the private class name — it cannot be subclassed or re-overridden by external code, which constrains workaround strategies that would try to extend or mix into it from app code.

## Ready for next waves

- **Wave 2 (Phase 3 build matrix)** can use: `/Users/davidmigloz/repos/flutter-master` (master channel, `c6f719d7a5`, Flutter 3.43.0-1.0.pre-548). The in-place clone is ready; `./bin/flutter --version` has been run once so the Dart SDK / tool snapshot is warm.
- **Wave 4.2 (Phase 7 draft framework PR)** can use: `/Users/davidmigloz/repos/flutter-master`. Line numbers match stable 3.41.6 exactly, so the existing fix plan's patch targets are valid without rewrites. The `davidmigloz` fork remote is still configured (`https://github.com/davidmigloz/flutter.git`) and can be used for pushing a PR branch.
- **Stable 3.41.6 clone** at `/Users/davidmigloz/repos/flutter` (HEAD `db50e20168`) remains untouched and is still the reference for Phase 3 stable-channel runs.
