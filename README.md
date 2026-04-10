# SelectableRegion `_flushAdditions` crash reproduction

## Live Demo

https://davidmigloz.github.io/flutter_selection_crash/

Minimal reproduction for [flutter/flutter#151536](https://github.com/flutter/flutter/issues/151536):
`StateError: Bad state: RenderBox was not laid out` thrown from
`MultiSelectableSelectionContainerDelegate._compareScreenOrder` when
`_RenderTheater` skips laying out an obscured `OverlayEntry` while its
`SelectionContainerDelegate` keeps processing registered selectables.

## TL;DR

- **Bug:** open, P2, unfixed on Flutter 3.41.6 stable and current master.
- **Mechanism:** `_RenderTheater` skips layout of non-topmost `OverlayEntry`;
  their registered selectables have no `size`; `_flushAdditions` sort crashes.
- **Three reproductions** of the same root cause in different code paths:
  A (`_getBoundingBox` via `paintBounds`), B (`_SelectableTextContainerDelegate`
  via `getBoxesForSelection`), C (`getTransformTo` via
  `RenderFractionalTranslation.applyPaintTransform`).
- **Proof-of-concept branch:** `fix/non-opaque-selectable-page` — wrapping
  the top Page in `opaque: false` prevents `_RenderTheater` from skipping
  the parent's layout, proving the mechanism. **Not production-ready** for
  full-screen routes (causes visual overlap).
- **Framework fix:** try/catch guard in `_compareScreenOrder` — catches the
  crash at its exact throw site with zero behavioral regressions. Route-level
  `SelectionContainer.disabled` wrappers were invalidated (nested
  `SelectionArea` creates its own registrar that shadows the disabled scope).

## Reproduce

```sh
git clone https://github.com/davidmigloz/flutter_selection_crash.git
cd flutter_selection_crash
flutter run -d chrome --wasm
```

Click into any of the three approach cards. Browser console shows the crash
immediately — no interaction required. Each approach hits a different frame
in the same `_compareScreenOrder` method. See
[investigation/2026-04-10_verification.md](investigation/2026-04-10_verification.md)
for the full stack traces.

## Proof of concept (`opaque: false`)

```sh
git checkout fix/non-opaque-selectable-page
flutter run -d chrome --wasm
```

Approach C now uses a local `_NonOpaquePage extends Page<void>` that creates
a `PageRouteBuilder(opaque: false, ...)`. The bottom route stays laid out,
the comparator sees valid sizes/transforms, no crash.

**Caveat:** `opaque: false` causes the parent route to be **painted** behind
the child (both Scaffolds render), creating visual text/widget overlap on
full-screen routes. This branch proves the crash mechanism but is NOT
suitable for production use.

## App-level workaround

The fix applied in production apps uses a **route-aware `SelectionArea`
toggle**: when the route is current, child is wrapped in `SelectionArea`
(text selectable); when another route covers it, child is wrapped in
`SelectionContainer.disabled` (selectables deregister). Uses
`ModalRoute.of(context)?.isCurrent` + `GlobalKey` + `KeyedSubtree`.

This works at the app level because the app controls where `SelectionArea`
is placed. It **cannot** be applied at the framework level because
`SelectionArea`/`SelectableRegion` create their own registrar that shadows
any outer disabled scope — see [INVESTIGATION.md](INVESTIGATION.md) for the
detailed analysis of why route-level `SelectionContainer.disabled` wrappers
don't work.

## Proposed framework fix

Guard `_compareScreenOrder` with a try/catch for `StateError`/`AssertionError`
when accessing geometry on unlaid-out `RenderBox`es. This is the minimal
surgical fix at the exact crash site, with zero behavioral regressions.

See [INVESTIGATION.md](INVESTIGATION.md) for the full proposal and known
limitations.

## Documentation

- [`INVESTIGATION.md`](INVESTIGATION.md) — full investigation summary, fix proposals, and why route-level wrappers don't work.
- [`investigation/2026-04-10_verification.md`](investigation/2026-04-10_verification.md) — crash verdicts, stack traces, `opaque: false` validation.
- [`investigation/upstream_research.md`](investigation/upstream_research.md) — current state of #151536 and related issues.
- [`investigation/framework_line_numbers.md`](investigation/framework_line_numbers.md) — verified Flutter master line numbers.
- [`investigation/report1.md`](investigation/report1.md), [`report2.md`](investigation/report2.md), [`report3.md`](investigation/report3.md) — independent research reports validating fix assumptions.

## Related issues

- [flutter/flutter#151536](https://github.com/flutter/flutter/issues/151536) — canonical, open
- [flutter/packages#11062](https://github.com/flutter/packages/pull/11062) — our go_router PR (open; @Renzo-Olivares directed to move fix to framework)
- [flutter/flutter#117527](https://github.com/flutter/flutter/issues/117527) — related, recently resolved
- [flutter/flutter#119776](https://github.com/flutter/flutter/issues/119776) — related, resolved
- [flutter/flutter#182573](https://github.com/flutter/flutter/issues/182573) — sibling (dead-zone variant)
- [PR #157996](https://github.com/flutter/flutter/pull/157996) — Gustl22's incomplete draft
- [PR #158918](https://github.com/flutter/flutter/pull/158918) — Gustl22's diagnostic draft

## Build matrix

| Command | Reproduces? |
|---|---|
| `flutter run -d chrome` (DDC debug) | Yes |
| `flutter run -d chrome --wasm` (dart2wasm debug) | Yes |
| `flutter run -d chrome --release --wasm` (dart2wasm release) | Yes |
| `flutter run -d chrome --release` (dart2js release) | Yes |
| `flutter test` (VM) | No (synchronous pump) |

## Production impact

This bug has been observed in production Flutter web apps: 640+ Sentry events
across 5+ users. Routes affected: any child route stacked on a parent that
wraps its content in `SelectionArea`. Workaround applied: route-aware
`SelectionArea` toggle using `ModalRoute.isCurrent` +
`SelectionContainer.disabled` (see "Production workaround" above).
