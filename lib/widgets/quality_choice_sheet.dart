import 'package:flutter/material.dart';
import '../models/tile_design.dart';
import '../models/choice_state.dart';
import '../utils/my_choice.dart';
import '../utils/quality_merge.dart';
import '../utils/surface_labels.dart';

/// Scenario-2 buyer merge (step 3). Bottom sheet opened from a merged buyer card:
/// pick how many boxes of each grade (Premium / Standard) to add to My Choice.
/// The cart is keyed per holding id, so "Both" is simply two independent
/// steppers writing to two holdings. Returns nothing; call setState after it
/// closes to refresh the card's chosen state.
Future<void> showQualityChoiceSheet(
    BuildContext context, MergedDesign card) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _QualityChoiceSheet(card: card),
  );
}

class _QualityChoiceSheet extends StatefulWidget {
  final MergedDesign card;
  const _QualityChoiceSheet({required this.card});
  @override
  State<_QualityChoiceSheet> createState() => _QualityChoiceSheetState();
}

class _QualityChoiceSheetState extends State<_QualityChoiceSheet> {
  // LOCAL working quantities — nothing is written to My Choice until the buyer
  // taps "Add to My Choice". Dismissing the sheet (tap outside / back) commits
  // nothing, so a design is never selected by accident.
  late final Map<String, int> _qty;

  @override
  void initState() {
    super.initState();
    // Start from the current choice if any, else default to full available stock
    // (buyer trims down). Local only.
    _qty = {
      for (final h in widget.card.holdings)
        h.id: myChoiceQuantities[h.id] ?? (h.boxQuantity > 0 ? h.boxQuantity : 0),
    };
  }

  // Numeric entry — tap the box count to type an exact quantity (clamped to the
  // available stock).
  Future<void> _editQty(TileDesign holding, int max) async {
    int? entered = _qty[holding.id] ?? 0;
    final value = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Quantity (max $max boxes)'),
        content: TextFormField(
          initialValue: '$entered',
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            hintText: 'Enter boxes',
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => entered = int.tryParse(v.trim()),
          onFieldSubmitted: (v) => Navigator.pop(ctx, int.tryParse(v.trim())),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, entered),
            child: const Text('Set'),
          ),
        ],
      ),
    );
    if (value != null) {
      setState(() => _qty[holding.id] = value.clamp(0, max));
    }
  }

  @override
  Widget build(BuildContext context) {
    final rep = widget.card.rep;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(rep.name,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 16),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(
                [
                  rep.size.replaceAll(' mm', ''),
                  if (rep.hasSurface)
                    surfaceLabels.label(rep.stockistId, rep.surfaceType),
                  if (rep.brandName.isNotEmpty) rep.brandName,
                ].join(' · '),
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            const SizedBox(height: 16),
            if (widget.card.premium != null)
              _gradeRow(
                holding: widget.card.premium!,
                label: 'Premium',
                icon: Icons.star_rounded,
                fg: const Color(0xFFF9A825),
                bg: const Color(0xFFFFF8E1),
              ),
            if (widget.card.premium != null && widget.card.standard != null)
              const SizedBox(height: 10),
            if (widget.card.standard != null)
              _gradeRow(
                holding: widget.card.standard!,
                label: 'Standard',
                icon: Icons.verified_outlined,
                fg: const Color(0xFF1565C0),
                bg: const Color(0xFFE3F2FD),
              ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  // Commit the local quantities now (0 removes / skips a grade).
                  for (final h in widget.card.holdings) {
                    setMyChoiceQty(h.id, _qty[h.id] ?? 0);
                  }
                  Navigator.of(context).pop();
                },
                child: const Text('Add to My Choice'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _gradeRow({
    required TileDesign holding,
    required String label,
    required IconData icon,
    required Color fg,
    required Color bg,
  }) {
    final qty = _qty[holding.id] ?? 0;
    final max = holding.boxQuantity;
    void set(int v) {
      setState(() => _qty[holding.id] = v.clamp(0, max));
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: fg.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: fg, fontSize: 13)),
                Text('$max boxes available',
                    style:
                        TextStyle(color: Colors.grey.shade600, fontSize: 11)),
              ],
            ),
          ),
          _stepBtn(Icons.remove, qty > 0 ? () => set(qty - 1) : null),
          GestureDetector(
            onTap: () => _editQty(holding, max),
            child: SizedBox(
              width: 44,
              child: Text('$qty',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: fg,
                      decoration: TextDecoration.underline,
                      decorationColor: fg.withValues(alpha: 0.4))),
            ),
          ),
          _stepBtn(Icons.add, qty < max ? () => set(qty + 1) : null),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: qty == max ? () => set(0) : () => set(max),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: fg.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(qty == max ? 'Clear' : 'All',
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepBtn(IconData icon, VoidCallback? onTap) => InkResponse(
        onTap: onTap,
        radius: 18,
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
                color: onTap == null ? Colors.grey.shade300 : Colors.grey),
          ),
          child: Icon(icon,
              size: 16,
              color: onTap == null ? Colors.grey.shade300 : Colors.grey.shade800),
        ),
      );
}
