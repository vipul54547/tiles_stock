import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../models/inquiry_order.dart';
import '../../services/supabase_data_service.dart';

/// Buyer order tracker (Phase 3 of project_order_remaining_model).
///
/// Every order the buyer placed, with its lifecycle status and the three
/// numbers that matter: Ordered · Dispatched · Remaining. A closed order that
/// left a remaining offers "Re-order remaining" (drops the leftover back into
/// My Choice as a fresh selection). Read-only otherwise; reuses `my_orders`.
class MyOrdersScreen extends StatefulWidget {
  const MyOrdersScreen({super.key});

  @override
  State<MyOrdersScreen> createState() => _MyOrdersScreenState();
}

class _MyOrdersScreenState extends State<MyOrdersScreen> {
  static const _navy = Color(0xFF1B4F72);
  final _service = SupabaseDataService();

  bool _loading = true;
  List<InquiryOrder> _orders = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final orders = await _service.getMyOrders();
    if (!mounted) return;
    setState(() {
      // My Orders = live orders + closed-short orders awaiting the buyer's
      // decision. Drafts (basket) live in My Choice; finalized orders (fully
      // dispatched / rejected / buyer re-ordered or closed) live in My Dispatch.
      _orders = orders
          .where((o) => o.status != 'draft' && !o.isFinalized)
          .toList();
      _loading = false;
    });
  }

  (Color, Color) _statusColors(String status) => switch (status) {
        'sent' => (const Color(0xFF1565C0), const Color(0xFFE3F2FD)),
        'locked' => (const Color(0xFF6A1B9A), const Color(0xFFF3E5F5)),
        'dispatching' => (const Color(0xFFE65100), const Color(0xFFFFF3E0)),
        'completed' => (const Color(0xFF2E7D32), const Color(0xFFE8F5E9)),
        'rejected' => (Colors.red.shade700, const Color(0xFFFFEBEE)),
        _ => (Colors.grey.shade700, const Color(0xFFF5F5F5)),
      };

  Future<void> _reorder(InquiryOrder o) async {
    try {
      final n = await _service.reorderRemaining(o.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(n > 0
            ? 'Added $n design${n == 1 ? '' : 's'} to My Choice — send them as a new order.'
            : 'Nothing left to re-order.'),
        backgroundColor: const Color(0xFF2E7D32),
      ));
      if (n > 0) await context.push('/my-choices');
      if (mounted) _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _close(InquiryOrder o) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Close this order?'),
        content: Text(
            'You won\'t re-order the ${o.remainingBoxes} leftover box'
            '${o.remainingBoxes == 1 ? '' : 'es'}. The order moves to My Dispatch.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('Close order')),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await _service.buyerCloseOrder(o.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Order closed — moved to My Dispatch.'),
          backgroundColor: Color(0xFF2E7D32)));
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e'), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Orders'),
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _orders.isEmpty
              ? _empty()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    itemCount: _orders.length,
                    itemBuilder: (_, i) => _card(_orders[i]),
                  ),
                ),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.receipt_long_outlined,
                  size: 56, color: Colors.grey.shade400),
              const SizedBox(height: 12),
              Text('No orders yet',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade700)),
              const SizedBox(height: 6),
              Text('Add designs to My Choice and send them to a supplier.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
            ],
          ),
        ),
      );

  Widget _card(InquiryOrder o) {
    final (fg, bg) = _statusColors(o.status);
    // A closed-short order the buyer must resolve (Re-order or Close).
    final decide = o.awaitingBuyerDecision;
    final kept = o.status == 'dispatching' && o.remainingBoxes > 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.storefront, size: 18, color: _navy),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    o.stockistName.isEmpty ? 'Supplier' : o.stockistName,
                    style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.bold,
                        color: _navy),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: bg, borderRadius: BorderRadius.circular(20)),
                child: Text(o.statusLabel,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: fg)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text('${o.token}  ·  ${o.lineCount} design${o.lineCount == 1 ? '' : 's'}',
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
          const SizedBox(height: 12),
          // Ordered · Dispatched · Remaining.
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: _navy.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                _stat('Ordered', o.totalBoxes, _navy),
                _divider(),
                _stat('Dispatched', o.dispatchedBoxes, const Color(0xFF2E7D32)),
                _divider(),
                _stat('Remaining', o.remainingBoxes,
                    o.remainingBoxes > 0 ? const Color(0xFFE65100) : Colors.grey),
              ],
            ),
          ),
          if (kept)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                  '${o.remainingBoxes} boxes still reserved for you — coming in a later dispatch.',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontStyle: FontStyle.italic,
                      color: Colors.grey.shade700)),
            ),
          if (decide) ...[
            const SizedBox(height: 8),
            Text(
                'This order was closed with ${o.remainingBoxes} box'
                '${o.remainingBoxes == 1 ? '' : 'es'} not dispatched — re-order the '
                'rest or close it.',
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _reorder(o),
                    icon: const Icon(Icons.replay, size: 16),
                    label: Text('Re-order ${o.remainingBoxes}'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFE65100),
                      side: const BorderSide(color: Color(0xFFE65100)),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _close(o),
                    icon: const Icon(Icons.check_circle_outline, size: 16),
                    label: const Text('Close order'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF2E7D32),
                      side: const BorderSide(color: Color(0xFF2E7D32)),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (o.dispatchedBoxes > 0) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () =>
                    context.push('/my-dispatches?token=${o.token}'),
                icon: const Icon(Icons.local_shipping_outlined, size: 16),
                label: const Text('View dispatches'),
                style: TextButton.styleFrom(
                    foregroundColor: _navy,
                    padding: const EdgeInsets.symmetric(horizontal: 4)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stat(String label, int value, Color color) => Expanded(
        child: Column(
          children: [
            Text('$value',
                style: TextStyle(
                    fontSize: 17, fontWeight: FontWeight.bold, color: color)),
            Text(label,
                style: const TextStyle(fontSize: 10.5, color: Colors.grey)),
          ],
        ),
      );

  Widget _divider() =>
      Container(width: 1, height: 26, color: Colors.grey.shade300);
}
