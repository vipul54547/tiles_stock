import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/supabase_data_service.dart';
import '../services/supabase_auth_service.dart';

/// Desktop/web shell for the stockist section. On wide windows it renders a
/// persistent left navigation sidebar and puts the routed page in the content
/// area — so the sidebar stays on EVERY page, including deep ones (edit,
/// dispatch, import), because those routes live inside this shell's navigator.
/// On phones it adds nothing (returns the page as-is). (nested-navigator shell)
class StockistShell extends StatefulWidget {
  final Widget child;
  final String location;
  const StockistShell({super.key, required this.child, required this.location});
  @override
  State<StockistShell> createState() => _StockistShellState();
}

class _StockistShellState extends State<StockistShell> {
  int _newOrders = 0;

  @override
  void initState() {
    super.initState();
    _loadBadge();
  }

  @override
  void didUpdateWidget(covariant StockistShell old) {
    super.didUpdateWidget(old);
    // Refresh the "new orders" badge whenever the page changes.
    if (old.location != widget.location) _loadBadge();
  }

  Future<void> _loadBadge() async {
    try {
      final orders = await SupabaseDataService().getMyInquiries();
      if (!mounted) return;
      setState(() =>
          _newOrders = orders.where((o) => o.status == 'sent').length);
    } catch (_) {/* badge is best-effort */}
  }

  bool _active(String path) =>
      widget.location == path || widget.location.startsWith('$path/');

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    if (!wide) return widget.child; // phone: page as-is, no sidebar
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sidebar(),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(child: widget.child),
        ],
      ),
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
            _navRow(Icons.logout, 'Logout', active: false, onTap: () async {
              await SupabaseAuthService().logout();
              if (mounted) context.go('/login');
            }),
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
          onTap: () => context.go(path));

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
