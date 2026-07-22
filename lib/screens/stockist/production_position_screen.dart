import 'package:flutter/material.dart';

/// 🏭 **PRODUCTION POSITION — the true state of a run, by design.**
///
/// Per design: **Program** (planned into the run) · **Premium made** (the run's
/// progress) · **Standard made** (the by-product, free stock) · **Left** (program
/// minus premium — progress is premium only). We do NOT enforce the gap; the
/// stockist handles any shortfall himself. Sending ready material to *Order from
/// stock* is the next step (M4). (docs/PRODUCTION_REDESIGN_PLAN.md §Phase 3)
class ProductionPositionScreen extends StatelessWidget {
  final Map<String, dynamic> run;
  const ProductionPositionScreen({super.key, required this.run});

  static const _navy = Color(0xFF1B4F72);
  static const _amber = Color(0xFFA96500);
  static const _green = Color(0xFF2E7D32);

  int _i(Map<String, dynamic> m, String k) => (m[k] as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    final boxes = [
      for (final b in (run['boxes'] as List?) ?? const [])
        Map<String, dynamic>.from(b as Map)
    ];
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        title: Text('Position · ${run['name'] ?? ''}'),
      ),
      body: boxes.isEmpty
          ? const Center(child: Text('No designs in this run.'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
              children: [for (final b in boxes) _card(b)],
            ),
    );
  }

  Widget _card(Map<String, dynamic> b) {
    final program = _i(b, 'target');
    final prem = _i(b, 'premium_made');
    final std = _i(b, 'standard_made');
    final left = (program - prem).clamp(0, 1 << 30);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${b['cover_word']}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
            Text('${b['brand']} · ${b['surface']} · ${b['size']}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            const SizedBox(height: 10),
            Wrap(spacing: 20, runSpacing: 8, children: [
              _fig('Program', program, Colors.grey.shade700),
              _fig('Premium made', prem, _green),
              _fig('Standard made', std, _navy),
              _fig('Left', left, _amber),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _fig(String label, int n, Color c) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$n',
              style:
                  TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: c)),
          Text(label, style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
        ],
      );
}
