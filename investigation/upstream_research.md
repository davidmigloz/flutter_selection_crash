# Phase 4 upstream research — SelectableRegion _flushAdditions crash

**Captured:** 2026-04-10
**Author:** Claude Code (W0.3 Explore agent; file written by orchestrator because Explore is read-only)

## 1. Current state of #151536

- **Status:** Open
- **Labels:** package, a: error message, has reproducible steps, P2, p: go_router, f: selection, customer: castaway, team-framework, triaged-framework, found in release: 3.22 & 3.24
- **Reactions:** 14 👍
- **Latest comments:**
  - 2024-10-31 (Gustl22): suspects stacked scaffolds confusing SelectionArea
  - 2024-08-17 (helpisdev): confirmed same error with Scaffold + GoRouter
  - 2024-07-30 (chunhtai): cc @Renzo-Olivares
- **New PRs linked since 2025-11-05:** None

## 2. Related upstream table

| Item | Author | Status | Date | Summary | Relationship | Action |
|---|---|---|---|---|---|---|
| [#151536](https://github.com/flutter/flutter/issues/151536) | reporter | **Open** | 2024-07-10 | Canonical: SelectableRegion crash "RenderBox not laid out" on paintBounds access | **PRIMARY** | Draft PR + comment |
| [#182573](https://github.com/flutter/flutter/issues/182573) | @davidmigloz | **Open** | 2026-02-18 | Offstage pages' SelectionArea dead zones block drag selection (our earlier filing) | Related (web platform) | Monitor |
| [#117527](https://github.com/flutter/flutter/issues/117527) | reporter | **Closed (resolved Mar 12, 2026)** | 2022-12-22 | SelectionArea assertion with nested routes | **Prior art — recently fixed** | Cite; identify fixing PR to understand what landed |
| [#119776](https://github.com/flutter/flutter/issues/119776) | reporter | **Closed (fixed)** | 2023-02-02 | SelectableRegion crash on background page | **Prior art — recently fixed** | Cite; identify fixing PR |
| [#147452](https://github.com/flutter/flutter/issues/147452) | reporter | **Open** | 2024-04-27 | Layout assertion with nested nav + bloc | Related family | Monitor |
| [#171632](https://github.com/flutter/flutter/issues/171632) | reporter | **Closed (resolved)** | 2025-07-04 | SelectionArea constraint passing (web vs native) | Fixed by PR #184083 | Reference |
| [#154253](https://github.com/flutter/flutter/issues/154253) | reporter | **Closed (resolved)** | before 2026-04-02 | Line breaks lost in SelectableRegion copy | Fixed by PR #184421 | Reference |
| [PR #157996](https://github.com/flutter/flutter/pull/157996) | Gustl22 | **Closed (self-closed 8 min)** | 2024-11-01 | Incomplete: add `_disabled`/`hasSize` getter to SelectionContainer | Draft | Build upon direction |
| [PR #158918](https://github.com/flutter/flutter/pull/158918) | Gustl22 | **Closed** | 2025-11-05 | Diagnostic draft exploring Overlay vs Offstage layout behavior; author flagged SelectionArea case as unsolved | Diagnostic | Credit + continue |
| [PR #184083](https://github.com/flutter/flutter/pull/184083) | Renzo-Olivares | **Merged 2026-03-24** | 2026-03-24 | SelectableRegion should passthrough constraints to child unmodified (StackFit.passthrough) | Related constraint fix | Reference in our PR |
| [PR #184421](https://github.com/flutter/flutter/pull/184421) | Renzo-Olivares | **Merged 2026-04-02** | 2026-03-31 | Fix: Line breaks lost in SelectableRegion; use BoxHeightStyle.max | Related paintBounds fix | Reference in our PR |

## 3. Competitor sweep verdict

- **Verdict:** **NO in-flight competitor PRs exist.** Direct searches for open PRs with keywords "selectable," "_flushAdditions," "selection_container," or author "Gustl22" on flutter/flutter returned zero results.
- **Confidence:** High.
- **Action:** Confidently proceed with draft PR (Wave 4.2). No need to throttle to "help" mode.

## 4. Gustl22 recent activity on flutter/flutter

Last 5 PRs by Gustl22:
1. **PR #184484** (Open, Draft) — 2026-04-01 — "Replace get hostPlatform with Dart's Abi.current" (tool refactoring)
2. **PR #184314** (Open) — 2026-03-29 — "Test packaging Windows on arm64" (CI/packaging)
3. **PR #183574** (Merged) — 2026-03-12 — "Remove bringup from windows_arm_host_engine orchestrator" (CI)
4. **PR #181373** (Merged) — 2026-01-23 — "Pass parameters from DropdownMenuFormField to DropDownMenu" (UI feature)
5. **PR #181369** (Merged) — 2026-01-23 — "Improve DropdownMenuFormField tests" (test improvement)

**Conclusion:** Gustl22 has pivoted away from SelectableRegion toward build infrastructure and form field features; not currently active on selection system. Safe to credit them without expecting collision.

## 5. Relevant framework commits since 2024-01-01

1. **c31247a7b3e** (Feb 2025) — "Fix crash on two finger selection gesture (#168598)"
2. **211d83d7729** (Oct 2023) — "fix: RangeError when selecting text in SelectionArea (#162228)"
3. **d620ec9274e** (Oct 2023) — "fix: SelectableRegion should only finalize selection after changing (#159698)"
4. **6fc33134090** (2025-10-17) — "SelectableRegion should use flutter rendered menu on web for Android/iOS (#177122)" (Renzo-Olivares)
5. **ccb1b7cf83e** (Mar 2026) — "SelectableRegion should passthrough constraints to child unmodified (#184083)" (Renzo-Olivares)

**Note:** The most recent commit touching `selection_container.dart` / `selectable_region.dart` since 2025-11-05 is only "Modernize framework lints (#179089)" on 2025-11-01 — **no substantive layout fixes post-Gustl22's PR #158918.** Our fix target remains open.

## 6. Additional notes

- **Renzo-Olivares is the primary active maintainer** of `SelectableRegion` (3 recent merged PRs addressing constraints, menu rendering, box heights). Our Phase 6 comment and Phase 7 draft PR should target their review.
- **Overlay vs Offstage distinction:** PR #158918 documented the key architectural difference — `Offstage` lays out hidden widgets; `Overlay` does not. This is central to the Fix B rationale in our plan.
- **Related web-platform issue #182573 (our own earlier filing)** describes overlapping offstage selectables creating dead zones — distinct but related manifestation of the same unlaid-out selectables problem.
- **No documented workaround on #151536:** the issue has 14 👍 and no workaround comments. Our production workaround (`ModalRoute.isCurrent` + `SelectionContainer.disabled` toggle) should be shared in the upstream comment. Note: an earlier `opaque: false` approach was abandoned due to visual overlap on full-screen routes.
- **#117527 and #119776 both CLOSED recently** — this is a change from the plan's assumptions. We need to verify what fixed them. **However**, W0.4 confirmed zero drift in `selectable_region.dart` / `selection_container.dart` line numbers and bodies between stable 3.41.6 and current master — meaning the fixes that closed #117527 and #119776 did NOT touch the `_flushAdditions` / `boundingBoxes` / `paintBounds` code path. Our Fix B target is still unfixed on master.

## 7. Renzo-Olivares' review directive on go_router PR #11062

Our own go_router PR [flutter/packages#11062](https://github.com/flutter/packages/pull/11062) (filed 2026-02-18, still open) implements the `SelectionContainer.disabled` + `ModalRoute.isCurrentOf` + `GlobalKey` pattern at the go_router builder level. On 2026-03-05, **@Renzo-Olivares reviewed** and directed us to move the fix to the framework:

> "I think the fix for this issue should probably live in the framework that way we can fix the root issue. [...] Generally any route we are making offstage/not the current route we should wrap with a `SelectionContainer.disabled` similar to how you've done in this pull request. Happy to help review and help with any questions. If that's not something you want to do then I'm also happy to take over as well."

**Implications for Phase 7:**
- **Renzo endorsed the `SelectionContainer.disabled` approach** — this is the pattern both our `_RouteAwareSelectionArea` (production workaround) and the go_router fork's `_OffstageSelectionDisabler` use. The framework fix should apply the same pattern.
- **The target is `_ModalScopeState.build()` in `packages/flutter/lib/src/widgets/routes.dart`** — wrap route content in `SelectionContainer.disabled` when the route is not current. This catches ALL routing packages (go_router, auto_route, Navigator directly), not just go_router.
- **Renzo is available as reviewer** and willing to take over. Tag @Renzo-Olivares on the framework PR.
- **PR #11062 stays open** until the framework fix lands; it may become unnecessary if the framework fix is comprehensive, or it may still be needed for the `StatefulShellRoute` inactive-branch case which `_ModalScopeState` doesn't cover.

**Gemini Code Assist also flagged** the tree-instability issue (toggling `SelectionContainer.disabled` changes the widget tree shape). Our response (GlobalKey + KeyedSubtree, matching the current `_RouteAwareSelectionArea` implementation) was accepted. An even cleaner approach — `SelectionContainer(registrar: isCurrent ? maybeOf(context) : null)` — was suggested but doesn't compile (public `SelectionContainer` constructor requires a non-null delegate, not a registrar). The framework PR could potentially add a `SelectionContainer.maybeDisabled` factory or expose the registrar toggle, making the pattern cleaner for both framework internals and package consumers.

## Gate G3 verdict

- **#151536 still canonical:** YES
- **No in-flight competitor:** YES
- **Renzo-Olivares is active in the area but not competing:** YES
- **Framework fix target (_flushAdditions / boundingBoxes / paintBounds) unchanged on master:** YES (verified by W0.4)
- **G3 pass:** ✅ **YES** — Phase 4/5/6/7 may proceed as planned.
