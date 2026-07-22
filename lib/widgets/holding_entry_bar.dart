import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/tile_design.dart';
import '../models/brand.dart';
import '../utils/holding_group.dart';
import 'combo_field.dart';

/// One order/dispatch line, entered from the keyboard:
///
///     delt ↓ Tab   m ↓ Tab   p ↓ Tab   40 Enter
///     │            │         │         └── quantity → Add
///     │            │         └── Quality   (skipped if only one)
///     │            └── Surface             (skipped if only one)
///     └── Design (the PRINT, not the holding)
///
/// The whole point is that a print is NOT a stock line. `DELTON_8_A` is six
/// holdings — brand × quality × surface — and a flat list of them is six
/// near-identical rows, one mis-tap from dispatching Standard when you meant
/// Premium. So this asks the print first, then narrows:
///
///  • Only variants actually IN STOCK for that print are offered, so "I picked
///    Glossy but only hold Matt" cannot happen.
///  • Every option carries its box count (`Premium · 121 boxes`) — the number is
///    what stops the wrong pick.
///  • A dimension with ONE option is filled in and skipped, so the common case
///    stays two keystrokes.
///  • The moment the choices leave exactly ONE holding, that holding IS the
///    answer — no pointless confirm.
///
/// The count shown is the caller's: dispatch counts what is on the shelf
/// (`boxQuantity`), an order counts what is free to promise (`fStock`).
/// (docs/DISPATCH_ORDER_BACKED_PLAN.md — Phase 2)
class HoldingEntryBar extends StatefulWidget {
  /// In-stock holdings to choose from.
  final List<TileDesign> designs;
  final List<Brand> brands;

  /// The number that matters on THIS screen — shelf stock, or free stock.
  final int Function(TileDesign) boxesOf;

  /// Added the line. [lot] is the batch this line ships from (dispatch only) —
  /// null when the screen doesn't track lots or the design has just one. Return
  /// false if it was rejected (over-stock declined, say) and the row should stay
  /// as the stockist left it.
  final Future<bool> Function(TileDesign design, int qty, Map<String, dynamic>? lot)
      onAdd;

  /// The batches of one holding — `[{lot_id, batch, location, box_quantity}]`,
  /// oldest first — when the screen wants a batch chosen AT ENTRY (dispatch's
  /// loading list). null = no batch field at all (orders, or untracked stock).
  /// More than one → a Batch dropdown appears; exactly one fills in read-only.
  final List<Map<String, dynamic>> Function(TileDesign)? lotsOf;

  /// Optional second way in — the browse/multi-select picker a screen already has.
  final VoidCallback? onBrowse;
  final String browseLabel;

  const HoldingEntryBar({
    super.key,
    required this.designs,
    required this.brands,
    required this.boxesOf,
    required this.onAdd,
    this.lotsOf,
    this.onBrowse,
    this.browseLabel = 'Browse',
  });

  @override
  State<HoldingEntryBar> createState() => _HoldingEntryBarState();
}

const _navy = Color(0xFF1B4F72);

class _HoldingEntryBarState extends State<HoldingEntryBar> {
  final _qtyCtrl = TextEditingController();
  final _fDesign = FocusNode();
  final _fBrand = FocusNode();
  final _fSurface = FocusNode();
  final _fQuality = FocusNode();
  final _fQty = FocusNode();

  HoldingPrint? _print;
  String? _brand;
  String? _surf;
  String? _qual;

  /// One boxes-to-load field per batch (lot_id -> controller), for a holding
  /// held in more than one batch. Filled straight in the batch list so the whole
  /// design is entered ONCE — no re-picking it per batch. (dispatch loading list)
  final Map<String, TextEditingController> _batchCtrls = {};

  late List<HoldingPrint> _prints = groupHoldingsByPrint(widget.designs);

  @override
  void didUpdateWidget(covariant HoldingEntryBar old) {
    super.didUpdateWidget(old);
    if (old.designs != widget.designs) {
      _prints = groupHoldingsByPrint(widget.designs);
    }
  }

  @override
  void dispose() {
    _qtyCtrl.dispose();
    _fDesign.dispose();
    _fBrand.dispose();
    _fSurface.dispose();
    _fQuality.dispose();
    _fQty.dispose();
    for (final c in _batchCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ── Faceting ───────────────────────────────────────────────────────────────
  // Each dimension's options are computed from the OTHER selections, so picking
  // in any order narrows correctly.

  List<TileDesign> _filter({String? brand, String? surf, String? qual}) =>
      (_print?.holdings ?? const <TileDesign>[])
          .where((d) =>
              (brand == null || brandKeyOf(d) == brand) &&
              (surf == null || surfaceKeyOf(d) == surf) &&
              (qual == null || d.quality == qual))
          .toList();

  List<String> _opts(String dim) {
    final rows = switch (dim) {
      'brand' => _filter(surf: _surf, qual: _qual),
      'surface' => _filter(brand: _brand, qual: _qual),
      _ => _filter(brand: _brand, surf: _surf),
    };
    final seen = <String>[];
    for (final d in rows) {
      final v = switch (dim) {
        'brand' => brandKeyOf(d),
        'surface' => surfaceKeyOf(d),
        _ => d.quality,
      };
      if (!seen.contains(v)) seen.add(v);
    }
    return seen;
  }

  /// Boxes behind one option — the number that stops the wrong pick.
  int _boxesFor(String dim, String value) {
    final rows = switch (dim) {
      'brand' => _filter(brand: value, surf: _surf, qual: _qual),
      'surface' => _filter(brand: _brand, surf: value, qual: _qual),
      _ => _filter(brand: _brand, surf: _surf, qual: value),
    };
    return rows.fold(0, (s, d) => s + widget.boxesOf(d));
  }

  /// A dimension with a single option needs no asking — take it.
  String? _eff(String dim, String? chosen) {
    if (chosen != null) return chosen;
    final o = _opts(dim);
    return o.length == 1 ? o.first : null;
  }

  /// The holding these choices land on, or null while still ambiguous.
  TileDesign? get _resolved {
    if (_print == null) return null;
    final c = _filter(
      brand: _eff('brand', _brand),
      surf: _eff('surface', _surf),
      qual: _eff('quality', _qual),
    );
    return c.length == 1 ? c.first : null;
  }

  String _brandName(String id) {
    if (id.isEmpty) return 'No brand';
    final m = widget.brands.where((b) => b.id == id).toList();
    return m.isEmpty ? 'No brand' : m.first.name;
  }

  String _surfName(String key) {
    final m = (_print?.holdings ?? const <TileDesign>[])
        .where((d) => surfaceKeyOf(d) == key)
        .toList();
    if (m.isEmpty) return key;
    final l = m.first.surfaceCardLabel;
    return l.isEmpty ? 'No surface' : l;
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  void _onPrint(HoldingPrint p) {
    setState(() {
      _print = p;
      _brand = null;
      _surf = null;
      _qual = null;
      _syncBatchCtrls();
    });
  }

  void _reset() {
    _print = null;
    _brand = null;
    _surf = null;
    _qual = null;
    _qtyCtrl.clear();
    _clearBatchCtrls();
  }

  // ── Batch (dispatch loading list) ────────────────────────────────────────────
  // The lots of the holding the choices have landed on. Empty when the screen
  // asks for no batch, or nothing is resolved yet.
  List<Map<String, dynamic>> get _lots {
    final d = _resolved;
    if (d == null || widget.lotsOf == null) return const [];
    return widget.lotsOf!(d);
  }

  /// Real = the lot carries a batch or a location (untracked stock is one blank
  /// lot, which is no real batch at all).
  bool get _hasRealBatch => _lots.any((l) =>
      (l['batch'] ?? '').toString().isNotEmpty ||
      (l['location'] ?? '').toString().isNotEmpty);

  /// More than one real batch → the stockist loads boxes-per-batch inline (one
  /// entry, no re-picking the design). Exactly one → a plain single quantity.
  bool get _multiBatch => _lots.length > 1 && _hasRealBatch;
  Map<String, dynamic>? get _singleLot =>
      _lots.length == 1 && _hasRealBatch ? _lots.first : null;

  String _lotLabel(Map<String, dynamic> l) {
    final b = (l['batch'] ?? '').toString();
    return b.isEmpty ? 'No batch' : 'Batch $b';
  }

  String _lotDetail(Map<String, dynamic> l) {
    final loc = (l['location'] ?? '').toString();
    final n = (l['box_quantity'] as num?)?.toInt() ?? 0;
    return [if (loc.isNotEmpty) loc, '$n avail'].join('  ·  ');
  }

  /// Give each batch of a multi-batch holding a quantity field, and drop any left
  /// over from a previously resolved holding. Called whenever the resolution changes.
  void _syncBatchCtrls() {
    final wanted = _multiBatch
        ? _lots.map((l) => l['lot_id'].toString()).toSet()
        : <String>{};
    for (final k in _batchCtrls.keys.toList()) {
      if (!wanted.contains(k)) _batchCtrls.remove(k)!.dispose();
    }
    for (final id in wanted) {
      _batchCtrls.putIfAbsent(id, () => TextEditingController());
    }
  }

  void _clearBatchCtrls() {
    for (final c in _batchCtrls.values) {
      c.dispose();
    }
    _batchCtrls.clear();
  }

  Future<void> _add() async {
    final d = _resolved;
    if (d == null) {
      _snack(_print == null
          ? 'Pick a design first.'
          : 'This design is in stock in more than one version — pick which.');
      return;
    }

    // Multi-batch: boxes typed against each batch → one line per batch, entered
    // ONCE. A batch left blank is simply not loaded.
    if (_multiBatch) {
      final picks = <(Map<String, dynamic>, int)>[];
      for (final lot in _lots) {
        final q =
            int.tryParse(_batchCtrls[lot['lot_id'].toString()]?.text.trim() ?? '') ??
                0;
        if (q > 0) picks.add((lot, q));
      }
      if (picks.isEmpty) {
        _snack('Enter boxes for at least one batch.');
        return;
      }
      var any = false;
      for (final (lot, q) in picks) {
        final ok = await widget.onAdd(d, q, lot);
        if (!mounted) return;
        if (ok) any = true;
      }
      if (any) {
        setState(_reset);
        _fDesign.requestFocus();
      }
      return;
    }

    // Single batch (or untracked): one quantity, the only lot (or none).
    final qty = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
    if (qty <= 0) {
      _snack('Enter a quantity.');
      return;
    }
    final added = await widget.onAdd(d, qty, _singleLot);
    if (!mounted || !added) return;
    setState(_reset);
    _fDesign.requestFocus();
  }

  void _snack(String m) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
        SnackBar(content: Text(m), backgroundColor: Colors.red.shade600));

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final brandOpts = _opts('brand');
    final surfOpts = _opts('surface');
    final qualOpts = _opts('quality');
    final d = _resolved;
    // The single Qty field's "of N": the one batch when there's just one, else
    // the whole holding. (Multi-batch has a count per batch, not this.)
    final singleStock = d == null
        ? null
        : (_singleLot != null
            ? (_singleLot!['box_quantity'] as num?)?.toInt() ?? 0
            : widget.boxesOf(d));

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            _field(
              'Design',
              ComboField<HoldingPrint>(
                focusNode: _fDesign,
                value: _print,
                options: _prints,
                labelOf: (p) => p.name,
                detailOf: (p) => [
                  p.size.replaceAll(' mm', ''),
                  if (p.variantHint.isNotEmpty) p.variantHint,
                  '${p.boxes(widget.boxesOf)} boxes',
                ].join('  ·  '),
                hint: 'Type to search design',
                hasError: _print == null,
                onSelected: _onPrint,
              ),
              width: 280,
            ),
            _field('Size', _readonly(_print?.size.replaceAll(' mm', '') ?? '—'),
                width: 96),
            // Brand / Surface / Quality are only ASKED when this print is really
            // held in more than one of them. A single-variant print resolves on
            // the design pick alone, and Tab flows straight to the quantity.
            _field(
              'Brand',
              ComboField<String>(
                focusNode: _fBrand,
                enabled: brandOpts.length > 1,
                value: _eff('brand', _brand),
                options: brandOpts,
                labelOf: _brandName,
                detailOf: (b) => '${_boxesFor('brand', b)} boxes',
                hint: '—',
                onSelected: (b) => setState(() {
                  _brand = b;
                  _syncBatchCtrls();
                }),
              ),
              width: 140,
            ),
            _field(
              'Surface',
              ComboField<String>(
                focusNode: _fSurface,
                enabled: surfOpts.length > 1,
                value: _eff('surface', _surf),
                options: surfOpts,
                labelOf: _surfName,
                detailOf: (s) => '${_boxesFor('surface', s)} boxes',
                hint: '—',
                onSelected: (s) => setState(() {
                  _surf = s;
                  _syncBatchCtrls();
                }),
              ),
              width: 170,
            ),
            _field(
              'Quality',
              ComboField<String>(
                focusNode: _fQuality,
                enabled: qualOpts.length > 1,
                value: _eff('quality', _qual),
                options: qualOpts,
                labelOf: (q) => q,
                detailOf: (q) => '${_boxesFor('quality', q)} boxes',
                hint: '—',
                onSelected: (q) => setState(() {
                  _qual = q;
                  _syncBatchCtrls();
                }),
              ),
              width: 150,
            ),
            // Multi-batch → boxes-per-batch, entered inline so the whole design
            // goes on in ONE Add. Exactly one batch → shown read-only beside a
            // single Qty. Untracked → no batch field at all.
            if (_multiBatch)
              _field(
                'Batches — boxes to load',
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [for (final lot in _lots) _batchQtyRow(lot)],
                ),
                width: 300,
              )
            else if (_singleLot != null)
              _field(
                'Batch',
                _readonly(
                    '${_lotLabel(_singleLot!)}  ·  ${_lotDetail(_singleLot!)}'),
                width: 200,
              ),
            if (!_multiBatch)
              _field(
                'Qty (boxes)',
                SizedBox(
                  height: 44,
                  child: TextField(
                    controller: _qtyCtrl,
                    focusNode: _fQty,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onSubmitted: (_) => _add(),
                    decoration: InputDecoration(
                      hintText: '0',
                      isDense: true,
                      // The count for the exact holding they landed on. This is
                      // the last thing they see before typing a number into it.
                      helperText: singleStock == null ? null : 'of $singleStock',
                      helperStyle: TextStyle(
                          fontSize: 10.5, color: Colors.grey.shade700),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
                width: 104,
              ),
            SizedBox(
              height: 44,
              child: ElevatedButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: _navy, foregroundColor: Colors.white),
              ),
            ),
            if (widget.onBrowse != null)
              SizedBox(
                height: 44,
                child: OutlinedButton.icon(
                  onPressed: widget.onBrowse,
                  icon: const Icon(Icons.grid_view_rounded, size: 18),
                  label: Text(widget.browseLabel),
                  style: OutlinedButton.styleFrom(foregroundColor: _navy),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// One batch of a multi-batch holding: its label + a boxes-to-load field.
  Widget _batchQtyRow(Map<String, dynamic> lot) {
    final ctrl = _batchCtrls[lot['lot_id'].toString()];
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_lotLabel(lot),
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600)),
              Text(_lotDetail(lot),
                  style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 60,
          height: 42,
          child: TextField(
            controller: ctrl,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onSubmitted: (_) => _add(),
            decoration: InputDecoration(
              hintText: '0',
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _field(String label, Widget child, {required double width}) => SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade600)),
            const SizedBox(height: 5),
            child,
          ],
        ),
      );

  Widget _readonly(String v) => Container(
        height: 44,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
            color: Colors.grey.shade100,
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(8)),
        child: Text(v,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade700)),
      );
}
