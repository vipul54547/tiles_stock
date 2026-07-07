import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../models/inquiry_order.dart';
import '../../services/supabase_data_service.dart';

/// Buyer "My Dispatch" — the record of finished orders: fully dispatched,
/// rejected, or ones the buyer resolved (Re-order / Close). Live orders stay in
/// My Orders; this is the history, with a link into each order's dispatch notes.
/// (project_order_remaining_model)
class MyDispatchScreen extends StatefulWidget {
  const MyDispatchScreen({super.key});

  @override
  State<MyDispatchScreen> createState() => _MyDispatchScreenState();
}

class _MyDispatchScreenState extends State<MyDispatchScreen> {
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
      _orders = orders.where((o) => o.isFinalized).toList();
      _loading = false;
    });
  }

  // A finished order's label: rejected, closed-short (buyer/stockist), or done.
  (String, Color, Color) _finalStatus(InquiryOrder o) {
    if (o.status == 'rejected') {
      return ('Rejected', Colors.red.shade700, const Color(0xFFFFEBEE));
    }
    if (o.remainingBoxes > 0) {
      return ('Closed', const Color(0xFF6A1B9A), const Color(0xFFF3E5F5));
    }
    return ('Completed', const Color(0xFF2E7D32), const Color(0xFFE8F5E9));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Dispatch'),
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
              Icon(Icons.local_shipping_outlined,
                  size: 56, color: Colors.grey.shade400),
              const SizedBox(height: 12),
              Text('No finished orders yet',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade700)),
              const SizedBox(height: 6),
              Text('Completed and closed orders will appear here as a record.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
            ],
          ),
        ),
      );

  Widget _card(InquiryOrder o) {
    final (label, fg, bg) = _finalStatus(o);
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
                child: Text(o.stockistName.isEmpty ? 'Supplier' : o.stockistName,
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
                child: Text(label,
                    style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.bold, color: fg)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text('${o.token}  ·  ${o.lineCount} design${o.lineCount == 1 ? '' : 's'}',
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
          const SizedBox(height: 12),
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
                _stat('Not taken', o.remainingBoxes,
                    o.remainingBoxes > 0 ? const Color(0xFF6A1B9A) : Colors.grey),
              ],
            ),
          ),
          if (o.dispatchedBoxes > 0) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () =>
                    context.push('/my-dispatches?token=${o.token}'),
                icon: const Icon(Icons.receipt_long_outlined, size: 16),
                label: const Text('View dispatch notes'),
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
