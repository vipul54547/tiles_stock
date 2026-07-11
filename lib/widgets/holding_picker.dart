import 'package:flutter/material.dart';
import '../models/tile_design.dart';
import '../models/brand.dart';
import 'tile_card.dart' show TileImage;
import '../utils/tile_sizes.dart';
import '../utils/holding_group.dart';

/// Pick ONE holding by hand, safely.
///
/// The old flat picker listed every holding as its own row, so a print stocked
/// in 3 surfaces x 2 qualities showed as SIX near-identical rows — and tapping
/// Premium when you meant Standard (or Matt when you meant Glossy) was one slip
/// away. This picker splits that into two questions the human can actually
/// answer:
///
///   1. WHICH PRINT?    one row per print (library_id = name + size), searchable.
///   2. WHICH VARIANT?  only the dimensions that are genuinely ambiguous for that
///                      print, each option carrying its box count.
///
/// Rules that make it safe:
///  • Only ever offers variants that ARE IN STOCK for the chosen print — never
///    the full surface/quality list, so "I picked Glossy but only hold Matt"
///    cannot happen.
///  • Every option shows its boxes (`Premium 121`), because seeing the number is
///    what stops the wrong tap.
///  • A dimension with only ONE option is not asked at all. A single-variant
///    print resolves on the tap that picks it — the fast path stays fast.
///
/// Returns the chosen holding, or null if dismissed. The result is the same
/// [TileDesign] the old flat list produced, so nothing downstream changes.
/// (docs/DISPATCH_ORDER_BACKED_PLAN.md — Phase 1)
Future<TileDesign?> showHoldingPicker(
  BuildContext context, {
  required List<TileDesign> designs,
  required List<Brand> brands,
  String title = 'Select design',
}) {
  return showModalBottomSheet<TileDesign>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) =>
        _HoldingPicker(designs: designs, brands: brands, title: title),
  );
}

const _navy = Color(0xFF1B4F72);

// Grouping lives in utils/holding_group.dart — the keyboard entry bar
// (HoldingEntryBar) asks exactly the same questions and must group identically.
String _surfKey(TileDesign d) => surfaceKeyOf(d);
String _brandKey(TileDesign d) => brandKeyOf(d);

class _HoldingPicker extends StatefulWidget {
  final List<TileDesign> designs;
  final List<Brand> brands;
  final String title;
  const _HoldingPicker(
      {required this.designs, required this.brands, required this.title});
  @override
  State<_HoldingPicker> createState() => _HoldingPickerState();
}

class _HoldingPickerState extends State<_HoldingPicker> {
  String _q = '';
  HoldingPrint? _print; // null = still choosing the print

  // Variant selections (null = not chosen yet).
  String? _brand;
  String? _surf;
  String? _qual;

  late final List<HoldingPrint> _prints = groupHoldingsByPrint(widget.designs);

  String _brandName(String id) {
    if (id.isEmpty) return '';
    final m = widget.brands.where((b) => b.id == id).toList();
    return m.isEmpty ? '' : m.first.name;
  }

  // ── Variant faceting ───────────────────────────────────────────────────────

  /// Holdings still possible under the current selections. Each dimension's
  /// options are computed from the OTHER selections, so picking in any order
  /// narrows correctly.
  List<TileDesign> _filter({String? brand, String? surf, String? qual}) =>
      (_print?.holdings ?? const <TileDesign>[])
          .where((d) =>
              (brand == null || _brandKey(d) == brand) &&
              (surf == null || _surfKey(d) == surf) &&
              (qual == null || d.quality == qual))
          .toList();

  List<TileDesign> get _candidates =>
      _filter(brand: _brand, surf: _surf, qual: _qual);

  List<String> _opts(String dim) {
    final rows = switch (dim) {
      'brand' => _filter(surf: _surf, qual: _qual),
      'surface' => _filter(brand: _brand, qual: _qual),
      _ => _filter(brand: _brand, surf: _surf),
    };
    final seen = <String>[];
    for (final d in rows) {
      final v = switch (dim) {
        'brand' => _brandKey(d),
        'surface' => _surfKey(d),
        _ => d.quality,
      };
      if (!seen.contains(v)) seen.add(v);
    }
    return seen;
  }

  /// Boxes behind one option — the number that stops the wrong tap.
  int _boxesFor(String dim, String value) {
    final rows = switch (dim) {
      'brand' => _filter(brand: value, surf: _surf, qual: _qual),
      'surface' => _filter(brand: _brand, surf: value, qual: _qual),
      _ => _filter(brand: _brand, surf: _surf, qual: value),
    };
    return rows.fold(0, (s, d) => s + d.boxQuantity);
  }

  /// The label for a surface option: the stockist's own word + canonical.
  String _surfLabel(String key) {
    final m = (_print?.holdings ?? const <TileDesign>[])
        .where((d) => _surfKey(d) == key)
        .toList();
    if (m.isEmpty) return key;
    final l = m.first.surfaceCardLabel;
    return l.isEmpty ? 'No surface' : l;
  }

  /// Take a selection; the moment the choices leave exactly ONE holding, that
  /// holding IS the answer — return it rather than asking a question that has
  /// only one possible reply.
  void _select(String dim, String value) {
    switch (dim) {
      case 'brand':
        _brand = value;
      case 'surface':
        _surf = value;
      default:
        _qual = value;
    }
    final c = _candidates;
    if (c.length == 1) {
      Navigator.pop(context, c.first);
    } else {
      setState(() {});
    }
  }

  void _openPrint(HoldingPrint p) {
    // Nothing to disambiguate — the tap that picked the print picked the
    // holding too.
    if (p.holdings.length == 1) {
      Navigator.pop(context, p.holdings.first);
      return;
    }
    setState(() {
      _print = p;
      _brand = null;
      _surf = null;
      _qual = null;
    });
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.78,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: _print == null ? _printList() : _variantChooser(_print!),
      ),
    );
  }

  // Step 1 — which print?
  Widget _printList() {
    final ql = _q.trim().toLowerCase();
    final res = _prints.where((p) {
      if (ql.isEmpty) return true;
      if (p.name.toLowerCase().contains(ql) ||
          p.size.toLowerCase().contains(ql)) {
        return true;
      }
      // Also match on a variant's own words, so searching "raindrop" or a brand
      // still finds the print that holds it.
      return p.holdings.any((d) =>
          d.surfaceCardLabel.toLowerCase().contains(ql) ||
          _brandName(_brandKey(d)).toLowerCase().contains(ql));
    }).toList();

    return Column(
      children: [
        const SizedBox(height: 12),
        Text(widget.title,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: TextField(
            autofocus: true,
            onChanged: (v) => setState(() => _q = v),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search),
              hintText: 'Search design, size, brand, surface…',
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
        Expanded(
          child: res.isEmpty
              ? const Center(child: Text('No in-stock designs match.'))
              : ListView.separated(
                  itemCount: res.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) => _printRow(res[i]),
                ),
        ),
      ],
    );
  }

  Widget _printRow(HoldingPrint p) {
    // What is still to be decided about this print — so the stockist knows a
    // second question is coming before they tap.
    final surfaces = p.holdings.map(_surfKey).toSet().length;
    final quals = p.holdings.map((d) => d.quality).toSet().length;
    final brandsN = p.holdings.map(_brandKey).toSet().length;
    final bits = [
      if (brandsN > 1) '$brandsN brands',
      if (surfaces > 1) '$surfaces surfaces',
      if (quals > 1) '$quals qualities',
    ];
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 44,
          height: 44,
          child: p.imageUrl.isEmpty
              ? Container(
                  color: Colors.grey.shade100,
                  child: const Icon(Icons.image_not_supported,
                      size: 18, color: Colors.grey))
              : TileImage(
                  url: p.imageUrl,
                  tileAspectRatio: aspectRatioFromSize(p.size),
                  thumbWidth: 120),
        ),
      ),
      title: Text(p.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        [
          p.size.replaceAll(' mm', ''),
          if (bits.isNotEmpty) bits.join(' · '),
        ].join('  ·  '),
        style: TextStyle(
            fontSize: 12,
            color: bits.isEmpty ? Colors.grey.shade600 : _navy),
      ),
      trailing: Text('${p.boxes((d) => d.boxQuantity)} boxes',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      onTap: () => _openPrint(p),
    );
  }

  // Step 2 — which variant? Only the ambiguous dimensions are shown; a
  // dimension with one option is never asked.
  Widget _variantChooser(HoldingPrint p) {
    final brandOpts = _opts('brand');
    final surfOpts = _opts('surface');
    final qualOpts = _opts('quality');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => setState(() => _print = null),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                  Text(p.size.replaceAll(' mm', ''),
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                ],
              ),
            ),
            const SizedBox(width: 12),
          ],
        ),
        const Divider(height: 12),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            children: [
              Text('This design is in stock in more than one version. '
                  'Pick the exact one you are dispatching.',
                  style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700)),
              if (brandOpts.length > 1)
                _dimSection('Brand', 'brand', brandOpts,
                    (v) => _brandName(v).isEmpty ? 'No brand' : _brandName(v),
                    _brand),
              if (qualOpts.length > 1)
                _dimSection('Quality', 'quality', qualOpts, (v) => v, _qual),
              if (surfOpts.length > 1)
                _dimSection('Surface', 'surface', surfOpts, _surfLabel, _surf),
            ],
          ),
        ),
      ],
    );
  }

  Widget _dimSection(String label, String dim, List<String> opts,
      String Function(String) labelOf, String? selected) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(label.toUpperCase(),
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                color: Colors.grey.shade600)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final o in opts)
              _optButton(
                text: labelOf(o),
                boxes: _boxesFor(dim, o),
                selected: selected == o,
                onTap: () => _select(dim, o),
              ),
          ],
        ),
      ],
    );
  }

  /// One choice. The box count is part of the button, not a footnote — it is
  /// the thing that tells the stockist they are about to pick the right line.
  Widget _optButton({
    required String text,
    required int boxes,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? _navy.withValues(alpha: 0.10) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: selected ? _navy : Colors.grey.shade300,
              width: selected ? 1.6 : 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: selected ? _navy : Colors.black87)),
            const SizedBox(height: 2),
            Text('$boxes boxes',
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }
}
