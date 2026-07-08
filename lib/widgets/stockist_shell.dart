import 'package:flutter/material.dart';
import '../services/supabase_data_service.dart';

/// The router's current location, set at the top of the app's redirect (runs on
/// every navigation, all platforms). Drives the desktop sidebar shell — which
/// page is active and whether to show the sidebar at all.
final ValueNotifier<String> gRouteLocation = ValueNotifier<String>('/');

/// Desktop/web shell rendered in MaterialApp.router's `builder`, i.e. BESIDE the
/// app's single navigator (NOT a nested ShellRoute navigator). On wide windows
/// while on a stockist page it draws the persistent left sidebar around the page;
/// otherwise it returns the page untouched. Because there's only one navigator,
/// dialogs / back / pops all target it correctly — no blank panes.
/// Navigation is done through callbacks wired to the global router (context.go
/// isn't reachable from inside the app builder).
class StockistShell extends StatefulWidget {
  final Widget child;
  final void Function(String path) onNavigate;
  final Future<void> Function() onLogout;
  const StockistShell({
    super.key,
    required this.child,
    required this.onNavigate,
    required this.onLogout,
  });
  @override
  State<StockistShell> createState() => _StockistShellState();
}

class _StockistShellState extends State<StockistShell> {
  int _newOrders = 0;
  String _lastBadgeLoc = '';

  /// Pins the navigator's element identity across the two shapes below.
  ///
  /// [widget.child] is the app's single navigator. Without a key it sits at a
  /// DIFFERENT position in the element tree depending on whether the sidebar is
  /// drawn (bare child vs Scaffold > Row > Expanded > child), so every time we
  /// crossed that boundary — landing on a stockist page, or resizing past the
  /// wide breakpoint — Flutter deactivated the whole navigator subtree and
  /// re-inflated it, throwing away every page's State. That is what blanked
  /// pages after a dialog, and what made in-flight async work (e.g. the splash
  /// screen's context.go) explode with "deactivated widget's ancestor".
  ///
  /// A GlobalKey makes Flutter MOVE the existing element instead of rebuilding
  /// it, so the navigator survives the shape change intact.
  final GlobalKey _navigatorKey = GlobalKey(debugLabel: 'shell-child');

  Future<void> _loadBadge() async {
    try {
      final orders = await SupabaseDataService().getMyInquiries();
      if (!mounted) return;
      final n = orders.where((o) => o.status == 'sent').length;
      if (n != _newOrders) setState(() => _newOrders = n);
    } catch (_) {/* best-effort */}
  }

  bool _active(String path) {
    final loc = gRouteLocation.value;
    return loc == path || loc.startsWith('$path/');
  }

  @override
  Widget build(BuildContext context) {
    // The app builder doesn't rebuild on navigation, so we rebuild the frame
    // ourselves whenever the location changes.
    return ValueListenableBuilder<String>(
      valueListenable: gRouteLocation,
      builder: (context, loc, _) {
        final wide = MediaQuery.sizeOf(context).width >= 1000;
        final isStockist = loc.startsWith('/stockist');
        // Refresh the "new orders" badge on landing a new stockist page (deferred
        // so we never call setState during a build).
        if (isStockist && loc != _lastBadgeLoc) {
          _lastBadgeLoc = loc;
          WidgetsBinding.instance.addPostFrameCallback((_) => _loadBadge());
        }
        // Same element, both shapes — see _navigatorKey.
        final page = KeyedSubtree(key: _navigatorKey, child: widget.child);
        if (!(wide && isStockist)) return page; // phone / non-stockist
        return Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sidebar(),
              const VerticalDivider(width: 1, thickness: 1),
              Expanded(child: page),
            ],
          ),
        );
      },
    );
  }

  Widget _sidebar() {
    const bg = Color(0xFF12354D), bg2 = Color(0xFF0E2C40);
    return Container(
      width: 212,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [bg, bg2]),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
              child: Row(
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                        gradient: const LinearGradient(
                            colors: [Color(0xFF2F78A8), Color(0xFF1B4F72)]),
                        borderRadius: BorderRadius.circular(7)),
                    child: const Icon(Icons.grid_view_rounded,
                        size: 15, color: Colors.white),
                  ),
                  const SizedBox(width: 9),
                  const Text('TilesStock',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15)),
                ],
              ),
            ),
            _item(Icons.grid_view_rounded, 'My Stock', '/stockist/dashboard'),
            _item(Icons.collections_bookmark_outlined, 'Design Library',
                '/stockist/library'),
            _item(Icons.receipt_long_outlined, 'Inquiries',
                '/stockist/inquiries',
                badge: _newOrders),
            _item(Icons.local_shipping_outlined, 'Dispatches',
                '/stockist/dispatches'),
            _item(Icons.link, 'Stock Lists', '/stockist/lists'),
            _item(Icons.play_circle_outline, 'My Videos', '/stockist/videos'),
            const Spacer(),
            const Divider(
                color: Colors.white24, height: 8, indent: 14, endIndent: 14),
            _item(Icons.person_outline, 'Profile', '/stockist/profile'),
            _navRow(Icons.logout, 'Logout',
                active: false, onTap: () => widget.onLogout()),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _item(IconData icon, String label, String path, {int badge = 0}) =>
      _navRow(icon, label,
          active: _active(path),
          badge: badge,
          onTap: () => widget.onNavigate(path));

  Widget _navRow(IconData icon, String label,
      {required bool active, int badge = 0, VoidCallback? onTap}) {
    const ink = Color(0xFFC9D6E1);
    const activeBg = Color(0xFF1E5479);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: active ? activeBg : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                Icon(icon, size: 18, color: active ? Colors.white : ink),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(label,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: active ? Colors.white : ink)),
                ),
                if (badge > 0)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                    decoration: BoxDecoration(
                        color: const Color(0xFFB26206),
                        borderRadius: BorderRadius.circular(999)),
                    child: Text('$badge',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
