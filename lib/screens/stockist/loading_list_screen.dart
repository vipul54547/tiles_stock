import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../services/supabase_data_service.dart';

/// The loading lists a stockist has prepared — the step between HOLD and
/// DISPATCH. A DRAFT is a truck being planned (pick batches, print for the
/// supervisor); once loaded it becomes a recorded dispatch. Drafts sit on top.
/// (docs/LOT_LAYER_PLAN.md · Loading List)
class LoadingListScreen extends StatefulWidget {
  const LoadingListScreen({super.key});
  @override
  State<LoadingListScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);
const _amber = Color(0xFFB26A00);
const _green = Color(0xFF2E7D32);

class _State extends State<LoadingListScreen> {
  final _svc = SupabaseDataService();
  bool _loading = true;
  List<Map<String, dynamic>> _lists = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final lists = await _svc.myLoadingLists();
    if (!mounted) return;
    setState(() {
      // Only lists still awaiting a truck. Once dispatched, the record lives in
      // Dispatches (as its dispatch note) — no need to linger here too.
      _lists = lists
          .where((l) => (l['status'] ?? 'draft').toString() == 'draft')
          .toList();
      _loading = false;
    });
  }

  Future<void> _new() async {
    final changed = await context.push<bool>('/stockist/loading-lists/edit');
    if (changed == true) _load();
  }

  Future<void> _open(String id) async {
    final changed = await context
        .push<bool>('/stockist/loading-lists/edit', extra: {'id': id});
    if (changed == true) _load();
  }

  Future<void> _discard(Map<String, dynamic> l) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard this draft?'),
        content: const Text('The loading list is deleted. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFC62828),
                foregroundColor: Colors.white),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _svc.loadingListDelete((l['id']).toString());
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        title: const Text('Loading Lists'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _new,
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('New loading list'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _lists.isEmpty
              ? _empty()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 90),
                  itemCount: _lists.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _tile(_lists[i]),
                ),
    );
  }

  Widget _empty() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.local_shipping_outlined,
                size: 54, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text('No loading lists yet',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade700)),
            const SizedBox(height: 4),
            Text('Prepare one when a truck comes to load.',
                style: TextStyle(color: Colors.grey.shade500)),
          ],
        ),
      );

  Widget _tile(Map<String, dynamic> l) {
    final draft = (l['status'] ?? 'draft').toString() == 'draft';
    final customer = (l['customer'] ?? '').toString();
    final order = (l['order_token'] ?? '').toString();
    final truck = (l['truck_no'] ?? '').toString();
    final po = (l['party_order_no'] ?? '').toString();
    final lines = (l['lines'] as num?)?.toInt() ?? 0;
    final boxes = (l['boxes'] as num?)?.toInt() ?? 0;
    final who = customer.isNotEmpty
        ? customer
        : (order.isNotEmpty ? 'Order $order' : 'Walk-in');

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: draft ? () => _open((l['id']).toString()) : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: (draft ? _amber : _green).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(draft ? 'DRAFT' : 'DISPATCHED',
                          style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.4,
                              color: draft ? _amber : _green)),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(who,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 14.5)),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  Text(
                      [
                        if (truck.isNotEmpty) '🚚 $truck',
                        if (po.isNotEmpty) 'PO $po',
                        '$lines line${lines == 1 ? '' : 's'}',
                        '$boxes boxes',
                      ].join('  ·  '),
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                ],
              ),
            ),
            if (draft)
              IconButton(
                tooltip: 'Discard draft',
                icon: Icon(Icons.delete_outline, color: Colors.red.shade400),
                onPressed: () => _discard(l),
              )
            else
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(Icons.check_circle, color: _green.withValues(alpha: .7)),
              ),
          ]),
        ),
      ),
    );
  }
}
