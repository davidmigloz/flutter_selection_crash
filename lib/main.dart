// Minimal reproduction for flutter/flutter#151536:
//
//   StateError: Bad state: RenderBox was not laid out
//
// thrown from
// `MultiSelectableSelectionContainerDelegate._compareScreenOrder` when
// `_RenderTheater` skips laying out an obscured `OverlayEntry` while its
// `SelectionContainerDelegate` keeps processing registered selectables.
//
// Three approaches are kept — each hits a different frame of the same
// `_compareScreenOrder` method, confirming the bug is not isolated to a
// single code path inside `SelectableRegion`:
//
//   A — `_RenderTheater` with plain `Text` selectables. Crashes inside
//       `_getBoundingBox` → `SelectionContainerState.boundingBoxes` →
//       `RenderBox.paintBounds`. Matches the production stack trace and
//       Gustl22's repro on PR #158918.
//
//   B — `_RenderTheater` wrapping a `CustomScrollView` with `WidgetSpan`
//       selectables. Crashes inside `_SelectableTextContainerDelegate`
//       via `getBoxesForSelection`, proving the `text.dart` delegate is
//       vulnerable too (so fixing only `SelectionContainerState` would
//       not be enough).
//
//   C — `Navigator` with two `MaterialPage`s where the bottom route owns
//       the `SelectionArea`. Crashes inside `getTransformTo` via
//       `RenderFractionalTranslation.applyPaintTransform`, matching the
//       original stack trace on flutter/flutter#151536.
//
// Why there are no `flutter test` tests in this repo: `tester.pump()` is
// synchronous, so it cannot reproduce the post-frame microtask race that
// `_flushAdditions` hits. All reproduction has to happen in a real
// engine frame loop. See `investigation/2026-04-10_verification.md` for
// the documented evidence.
//
// A companion branch `fix/non-opaque-selectable-page` validates the
// mechanism: wrapping the topmost `Page` in a non-opaque route
// (`PageRouteBuilder(opaque: false, ...)`) so `_RenderTheater` continues
// laying out the underlying route. The comparator sees valid
// sizes/transforms, and the crash disappears. The branch only differs
// from `main` in Approach C.
//
// Note: `opaque: false` is a proof of concept, NOT a production fix —
// it causes the parent route to be painted behind the child (visual
// overlap). The production workaround is a route-aware SelectionArea
// toggle using `ModalRoute.isCurrent` + `SelectionContainer.disabled`
// (see flutter/packages#11062 for the go_router variant).
//
// Verified on Flutter 3.41.6 stable + Chrome + dart2wasm (debug and
// release).
//
// Run with:
//   flutter run -d chrome
//   flutter run -d chrome --wasm
//   flutter run -d chrome --release --wasm
import 'package:flutter/material.dart';

void main() {
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SelectionArea Crash Reproduction',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.red),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SelectionArea Crash Repro'),
        backgroundColor: Theme.of(context).colorScheme.errorContainer,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                'Reproduction for flutter/flutter#151536',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Three approaches. Each one triggers:\n'
                '"StateError: Bad state: RenderBox was not laid out"\n'
                'in a different frame of _compareScreenOrder.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              _ApproachCard(
                title: 'A: Overlay entries (Gustl22)',
                description:
                    'Direct Overlay with two OverlayEntry objects. Entry 0 '
                    'has SelectionArea + Text, Entry 1 is opaque on top. '
                    '_RenderTheater skips layout of Entry 0 but selectables '
                    'remain registered. Crashes inside _getBoundingBox -> '
                    'paintBounds -> size.',
                onTap: () => _push(context, const ApproachAPage()),
              ),
              _ApproachCard(
                title: 'B: Overlay + CustomScrollView',
                description:
                    'Like E, but Entry 0 has SelectionArea wrapping a '
                    'CustomScrollView with many slivers + WidgetSpans. '
                    'Crashes through _SelectableTextContainerDelegate via '
                    'getBoxesForSelection — a different delegate from E.',
                onTap: () => _push(context, const ApproachBPage()),
              ),
              _ApproachCard(
                title: 'C: Navigator deep-link (nested routes)',
                description:
                    'Navigator with two MaterialPages from the start. Bottom '
                    'route has SelectionArea + CustomScrollView, top route '
                    'is opaque. Crashes inside getTransformTo -> '
                    'RenderFractionalTranslation.applyPaintTransform.',
                onTap: () => _push(context, const ApproachCPage()),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }
}

class _ApproachCard extends StatelessWidget {
  const _ApproachCard({
    required this.title,
    required this.description,
    required this.onTap,
  });

  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(description),
              const SizedBox(height: 8),
              const Align(
                alignment: Alignment.centerRight,
                child: Icon(Icons.arrow_forward),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// Approach A: Direct Overlay entries (based on Gustl22's reproduction from
// flutter/flutter#151536 PR #158918)
//
// Mechanism: _RenderTheater intentionally skips layout for non-topmost entries.
// Entry 0 has SelectionArea + Text widgets — selectables register during build.
// Entry 1 is opaque on top -> Entry 0 not laid out.
// _flushAdditions() sorts -> accesses unlaid-out RenderBoxes -> crash.
//
// Verified stack frame (2026-04-10, Flutter 3.41.6):
//   _compareScreenOrder -> _getBoundingBox -> boundingBoxes.first ->
//   SelectionContainerState.boundingBoxes -> (RenderBox).paintBounds -> size
// ===========================================================================

class ApproachAPage extends StatelessWidget {
  const ApproachAPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('A: Overlay entries')),
      body: Material(
        child: Overlay(
          initialEntries: [
            OverlayEntry(
              builder:
                  (_) => SelectionArea(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Text('rootA — This text is in the bottom entry'),
                        SizedBox(height: 16),
                        Text(
                          'rootB — SelectionArea registers these as selectables',
                        ),
                        SizedBox(height: 16),
                        Text(
                          'rootC — But _RenderTheater skips layout for this entry',
                        ),
                      ],
                    ),
                  ),
              opaque: true,
              canSizeOverlay: true,
              maintainState: true,
            ),
            OverlayEntry(
              builder:
                  (_) => const Center(
                    child: Card(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                          'Top entry (opaque)\n\n'
                          'The SelectionArea in the bottom entry\n'
                          'should have its selectables registered\n'
                          'but RenderBoxes NOT laid out.\n\n'
                          'Check console for:\n'
                          '"RenderBox was not laid out"',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
              opaque: true,
              canSizeOverlay: true,
              maintainState: true,
            ),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// Approach B: Overlay + CustomScrollView (matching production)
//
// Like E, but the bottom entry has SelectionArea wrapping a CustomScrollView
// with many slivers containing WidgetSpans. The Scrollable creates a nested
// SelectionContainer that registers with the offstage SelectionArea's delegate.
//
// Verified stack frame (2026-04-10, Flutter 3.41.6):
//   _SelectableTextContainerDelegate._compareScreenOrder ->
//   _SelectableFragment.boundingBoxes -> RenderParagraph.getBoxesForSelection
//   (asserts !debugNeedsLayout, which fails for the offstage paragraph)
// ===========================================================================

class ApproachBPage extends StatelessWidget {
  const ApproachBPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('B: Overlay + CustomScrollView')),
      body: Material(
        child: Overlay(
          initialEntries: [
            OverlayEntry(
              builder:
                  (_) => SelectionArea(
                    child: CustomScrollView(
                      slivers: [
                        SliverAppBar(
                          expandedHeight: 120,
                          pinned: true,
                          flexibleSpace: FlexibleSpaceBar(
                            title: Text.rich(
                              TextSpan(
                                children: [
                                  const TextSpan(
                                    text: 'Offstage Property',
                                    style: TextStyle(fontSize: 14),
                                  ),
                                  const WidgetSpan(child: SizedBox(width: 4)),
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: Icon(
                                      Icons.flag,
                                      size: 14,
                                      color: Colors.orange.shade300,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            background: Container(color: Colors.blue.shade200),
                          ),
                        ),
                        ..._buildRichSlivers(30, prefix: 'Offstage'),
                      ],
                    ),
                  ),
              opaque: true,
              canSizeOverlay: true,
              maintainState: true,
            ),
            OverlayEntry(
              builder:
                  (_) => const Center(
                    child: Card(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                          'Top entry covers the bottom entry.\n\n'
                          'Bottom has SelectionArea + CustomScrollView\n'
                          'with 30 slivers + WidgetSpans.\n\n'
                          'The Scrollable creates a nested SelectionContainer\n'
                          'that registers with the offstage delegate.\n\n'
                          'Check console for crash.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
              opaque: true,
              canSizeOverlay: true,
              maintainState: true,
            ),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// Approach C: Navigator deep-link simulation
//
// Simulates the go_router deep-link pattern from flutter/flutter#151536:
// Navigate directly to a nested route so the parent route's SelectionArea
// is built but immediately offstage (never gets laid out in the first frame).
//
// Verified stack frame (2026-04-10, Flutter 3.41.6):
//   _compareScreenOrder -> MatrixUtils.transformRect(a.getTransformTo(null),
//   ...) -> RenderFractionalTranslation.applyPaintTransform -> .size (throws)
// ===========================================================================

class ApproachCPage extends StatelessWidget {
  const ApproachCPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const _DeepLinkNavigator();
  }
}

class _DeepLinkNavigator extends StatefulWidget {
  const _DeepLinkNavigator();

  @override
  State<_DeepLinkNavigator> createState() => _DeepLinkNavigatorState();
}

class _DeepLinkNavigatorState extends State<_DeepLinkNavigator> {
  @override
  Widget build(BuildContext context) {
    // Simulate deep-link: both routes exist from the start.
    // Route 0 has SelectionArea + CustomScrollView (offstage).
    // Route 1 is on top (visible).
    return Navigator(
      pages: [
        MaterialPage(
          child: SelectionArea(
            child: Scaffold(
              appBar: AppBar(title: const Text('Parent route (offstage)')),
              body: CustomScrollView(
                slivers: [
                  SliverAppBar(
                    expandedHeight: 100,
                    flexibleSpace: FlexibleSpaceBar(
                      title: Text.rich(
                        TextSpan(
                          children: [
                            const TextSpan(
                              text: 'Parent Route',
                              style: TextStyle(fontSize: 12),
                            ),
                            const WidgetSpan(child: SizedBox(width: 4)),
                            WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: Icon(
                                Icons.flag,
                                size: 12,
                                color: Colors.orange.shade300,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  ..._buildRichSlivers(20, prefix: 'Parent'),
                ],
              ),
            ),
          ),
        ),
        MaterialPage(
          child: Scaffold(
            appBar: AppBar(title: const Text('C: Child route (visible)')),
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'Parent route has SelectionArea +\n'
                    'CustomScrollView with 20 slivers.\n\n'
                    'It should be offstage (not laid out)\n'
                    'because this child route covers it.\n\n'
                    'Check console for crash.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Pop to parent route'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
      onPopPage: (route, result) {
        return route.didPop(result);
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Shared: builds slivers matching production PrivateDealContent pattern.
// Uses RichText with WidgetSpans (inline Icons, SizedBox spacing).
// ---------------------------------------------------------------------------

List<Widget> _buildRichSlivers(int count, {String prefix = ''}) {
  return [
    for (int i = 0; i < count; i++)
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '$prefix Section $i',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const WidgetSpan(child: SizedBox(width: 8)),
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Icon(
                        Icons.flag,
                        size: 16,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text.rich(
                TextSpan(
                  children: [
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Icon(
                        Icons.euro,
                        size: 14,
                        color: Colors.green.shade700,
                      ),
                    ),
                    const WidgetSpan(child: SizedBox(width: 4)),
                    TextSpan(
                      text: '${100 + i * 50}.000',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const WidgetSpan(child: SizedBox(width: 16)),
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Icon(
                        Icons.percent,
                        size: 14,
                        color: Colors.blue.shade700,
                      ),
                    ),
                    const WidgetSpan(child: SizedBox(width: 4)),
                    TextSpan(
                      text: '${4 + (i % 3)}.${i % 10}%',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text.rich(
                TextSpan(
                  children: [
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Icon(
                        Icons.location_on,
                        size: 14,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const WidgetSpan(child: SizedBox(width: 4)),
                    TextSpan(text: 'Amsterdam, Netherlands — Property $i'),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Description text for section $i with enough content to be '
                'meaningful. This includes property details, financial '
                'metrics, and additional metadata.',
              ),
              const Divider(height: 24),
            ],
          ),
        ),
      ),
  ];
}
