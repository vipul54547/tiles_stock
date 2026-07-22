import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:printing/printing.dart';
import '../../config/app_config.dart';
import '../../utils/dispatch_pdf.dart';
import '../../models/tile_design.dart';
import '../../models/brand.dart';
import '../../models/choice_state.dart';
import '../../models/inquiry_order.dart';
import '../../services/supabase_data_service.dart';
import '../../widgets/save_bar.dart';
import '../../widgets/holding_picker.dart';
import '../../widgets/holding_entry_bar.dart';
import '../../widgets/customer_picker.dart';
import '../../utils/tile_types.dart';

/// Manual dispatch, in the same batch shape as Add Stock: pick designs → set
/// boxes → Add to a running list, fill dispatch details, then Record. Over-
/// dispatch is allowed — dispatch is the final truth.
///
/// An ORDER is optional. Without one this is the walk-in case (dispatch_walkin):
/// no remaining, and Customer is a plain optional name unless the admin turned
/// on "My Customers" (customers_enabled), which makes it a save-and-reuse picker.
///
/// Attach an order and it becomes the order-linked case (dispatch_inquiry, with
/// prune=false): the order's lines pre-fill at 0 boxes, remaining is tracked,
/// and Close/Keep decides the fate of what doesn't go on this truck. The rows
/// here are "what's on the truck", never "the whole order" — so removing an
/// order row only takes it off the truck, and prune=false stops the server from
/// deleting it. Designs that aren't on the order may still be added; they join
/// it fully-dispatched. Customer is hidden while attached (the order names the
/// buyer, and dispatch_inquiry ignores customer_id).
/// (project_unified_dispatch_customers — attach-order)
class ManualDispatchScreen extends StatefulWidget {
  /// Arrive with an order already attached (Inquiries → Dispatch). Null = the
  /// screen opens empty and the order, if any, is attached by hand.
  final String? orderId;

  /// When opened from a Loading List: its lines (design · batch · boxes) prefill
  /// the truck, and recording marks the list dispatched. (LOT layer · Loading List)
  final String? loadingListId;

  /// Stock mode chosen by the caller, if it wants to preselect one.
  final bool? reduceStock;

  const ManualDispatchScreen(
      {super.key, this.orderId, this.reduceStock, this.loadingListId});
  @override
  State<ManualDispatchScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);
const _red = Color(0xFFC62828);

class _Line {
  final TileDesign d;
  int qty;

  /// Boxes ordered, when this row came from the attached order. null = the row
  /// is not on the order (a walk-in row, or an extra loaded on top of an order).
  final int? ordered;

  /// Boxes already sent against this order line by earlier dispatches.
  final int done;

  /// Boxes of this design held (H_Quantity) across ALL orders.
  final int held;

  /// Boxes held by THIS order alone.
  final int lineHeld;

  /// The batch this line ships from — one line = one (design, batch) picking
  /// instruction for the supervisor. All null when the stockist tracks no lots.
  /// (LOT layer L3 · dispatch loading list)
  final String? lotId;
  final String? batch;
  final String? location;

  /// Boxes in that batch, for the over-count warning (you load from the lot).
  final int lotQty;

  _Line(this.d, this.qty,
      {this.ordered,
      this.done = 0,
      this.held = 0,
      this.lineHeld = 0,
      this.lotId,
      this.batch,
      this.location,
      this.lotQty = 0});

  bool get onOrder => ordered != null;

  /// The batch/location as one short string for a row, or '' when untracked.
  String get lotLabel {
    final b = (batch ?? '').trim();
    final l = (location ?? '').trim();
    if (b.isEmpty && l.isEmpty) return '';
    return [if (b.isNotEmpty) 'Batch $b', if (l.isNotEmpty) l].join(' · ');
  }

  /// Boxes promised to OTHER buyers' orders. Dispatching past what's left over
  /// after these is allowed, but the stockist is warned.
  int get otherHeld => (held - lineHeld).clamp(0, 1 << 30);

  /// What stays on the order once this truck leaves. Over-dispatching floors it
  /// at 0 rather than going negative.
  int get remainingAfter =>
      ordered == null ? 0 : (ordered! - done - qty).clamp(0, 1 << 30);
}

class _State extends State<ManualDispatchScreen> {
  final _svc = SupabaseDataService();
  bool _loading = true;
  bool _saving = false;

  /// Every holding, in stock or not — an attached order can name a design that
  /// has since run down to 0, and that row still has to render.
  List<TileDesign> _all = [];

  /// What the design picker offers: only what there is stock of.
  List<TileDesign> _designs = [];
  /// library_id -> "11.5–12.0 mm" for a product FORKED off a print by a genuinely different
  /// thickness. Two such products share a NAME, so without this you cannot tell which stock you
  /// are dispatching. (docs/THICKNESS_AND_BODY_IDENTITY_PLAN.md)
  Map<String, String> _forkLabels = const {};

  /// The design's name as it must READ here — with its thickness when a same-named sibling exists.
  String _dispName(TileDesign d) {
    final fork = _forkLabels[d.libraryId];
    return fork == null ? d.name : '${d.name} ($fork)';
  }
  List<Brand> _brands = [];
  bool _customersEnabled = false;
  List<Map<String, dynamic>> _customers = [];
  String _stockistName = ''; // for the printed dispatch note header

  // Attached order (null = walk-in dispatch).
  InquiryOrder? _order;
  bool _busyOrder = false;

  /// Fate of the boxes that don't go on this truck. false = keep the order open
  /// and the remaining reserved; true = close it and release them.
  /// null = not chosen. NO DEFAULT: both fates are consequential, so the
  /// stockist picks rather than inherits one by reflex.
  bool? _close;

  /// What this dispatch does to stock. true = reduce P_Stock by the dispatched
  /// boxes. false = release the order's holding only and leave P_Stock alone,
  /// for a stockist who keeps their real count in other software. Only offered
  /// with an order attached — a walk-in has no holding to release.
  /// null = not chosen, same no-default rule as [_close].
  /// (project_dispatch_order_redesign · Phase D)
  bool? _reduceStock;

  // Entry being built.
  TileDesign? _sel;
  final _qtyCtrl = TextEditingController();

  final _lines = <_Line>[];

  /// holding id -> its lots (batch · location · boxes), oldest first. Loaded once
  /// so the entry bar can offer a batch per design without a call each. (L3)
  Map<String, List<Map<String, dynamic>>> _stockLots = {};

  /// Lots only exist to be chosen between when the stockist tracks batch or
  /// location. Off → one NULL lot per holding → no batch field, dispatch as before.
  bool get _lotsTracked =>
      currentStockistTrackBatches || currentStockistTrackLocations;

  /// The batches of a holding, for the entry bar's Batch field. (L3)
  List<Map<String, dynamic>> _lotsOf(TileDesign d) =>
      _lotsTracked ? (_stockLots[d.id] ?? const []) : const [];

  // Dispatch details.
  final _invoiceCtrl = TextEditingController();
  final _vehicleCtrl = TextEditingController();
  final _transporterCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  DateTime _date = DateTime.now();

  // Customer.
  final _custNameCtrl = TextEditingController(); // free text (flag OFF)
  String? _custId; // set when a saved customer is picked/created (flag ON)

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _qtyCtrl.dispose();
    _invoiceCtrl.dispose();
    _vehicleCtrl.dispose();
    _transporterCtrl.dispose();
    _noteCtrl.dispose();
    _custNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final all = await _svc.getDesignsByStockist(currentStockistUUID);
    final brands = await _svc.getMyBrands();
    final profile = await _svc.getMyProfile();
    final enabled = (profile?['customers_enabled'] as bool?) ?? false;
    final customers = enabled ? await _svc.listCustomers() : <Map<String, dynamic>>[];
    // The batches behind each holding, so the entry bar can offer a batch per
    // design with no call each. Only fetched when the stockist tracks lots.
    final lots = _lotsTracked
        ? await _svc.myStockLots()
        : <String, List<Map<String, dynamic>>>{};
    if (!mounted) return;
    setState(() {
      _all = all;
      _stockLots = lots;
      _designs = all.where((d) => d.boxQuantity > 0).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      // A print carried in two thicknesses is two products with the SAME name. Without this the
      // dispatch list shows two identical rows and you cannot tell which stock you are sending.
      _forkLabels = thicknessForkLabels(all);
      _brands = brands;
      _customersEnabled = enabled;
      _customers = customers;
      _stockistName = (profile?['name'] ?? '').toString();
      _loading = false;
    });

    // Opened from Inquiries → Dispatch: the order is already decided. Needs the
    // designs above to be loaded first, so it runs after the setState.
    final id = widget.orderId;
    if (id != null && _order == null) await _attachOrderById(id);

    // From a Loading List: overlay its batch lines onto the (now attached) order.
    if (widget.loadingListId != null) await _prefillFromLoadingList(widget.loadingListId!);
  }

  /// Fill the truck from a saved loading list — each item is a (design, batch,
  /// boxes) already decided at loading time. Fills the matching order row where
  /// there is one, else adds a line; a design loaded from two batches becomes two
  /// lines. Stock always moves for a real truck, so reduce-stock defaults on.
  Future<void> _prefillFromLoadingList(String id) async {
    final data = await _svc.loadingListGet(id);
    if (data == null || !mounted) return;
    final items = (data['items'] as List?) ?? const [];
    setState(() {
      for (final raw in items) {
        final m = Map<String, dynamic>.from(raw as Map);
        final did = (m['design_id']).toString();
        final d = _designById(did);
        if (d == null) continue;
        final boxes = (m['boxes'] as num?)?.toInt() ?? 0;
        if (boxes <= 0) continue;
        final lotId = (m['lot_id'])?.toString();
        final batch = (m['batch'] ?? '').toString();
        final loc = (m['location'] ?? '').toString();
        final lots = _stockLots[did] ?? const [];
        final match = lots.where((l) => (l['lot_id']).toString() == lotId).toList();
        final avail =
            match.isEmpty ? boxes : (match.first['box_quantity'] as num?)?.toInt() ?? boxes;

        final orderIdx = _lines
            .indexWhere((l) => l.d.id == did && l.onOrder && l.qty == 0);
        if (orderIdx >= 0) {
          final o = _lines[orderIdx];
          _lines[orderIdx] = _Line(d, boxes,
              ordered: o.ordered, done: o.done, held: o.held, lineHeld: o.lineHeld,
              lotId: lotId, batch: batch, location: loc, lotQty: avail);
        } else {
          _lines.insert(0,
              _Line(d, boxes, lotId: lotId, batch: batch, location: loc, lotQty: avail));
        }
      }
      _reduceStock ??= true;
    });
  }

  Future<void> _attachOrderById(String id) async {
    setState(() => _busyOrder = true);
    final all = await _svc.getMyInquiries();
    if (!mounted) return;
    final match = all.where((o) => o.id == id).toList();
    if (match.isEmpty) {
      setState(() => _busyOrder = false);
      _snack('That order is no longer open.', _red);
      return;
    }
    await _attachOrder(match.first);
    if (!mounted) return;
    if (widget.reduceStock != null) {
      setState(() => _reduceStock = widget.reduceStock!);
    }
  }

  int get _totalBoxes => _lines.fold(0, (s, l) => s + l.qty);

  /// Rows actually going on the truck. Order rows sitting at 0 don't count.
  int get _loadedCount => _lines.where((l) => l.qty > 0).length;

  /// Boxes still on the order after this dispatch.
  int get _remainingAfter =>
      _lines.where((l) => l.onOrder).fold(0, (s, l) => s + l.remainingAfter);

  TileDesign? _designById(String id) {
    for (final d in _all) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// Who the dispatch is for. An attached order names its buyer; dispatch_inquiry
  /// labels the dispatch from the company (falling back to the stockist's hint).
  String get _buyerLabel {
    final o = _order;
    if (o == null) return '';
    final c = o.company.trim();
    if (c.isNotEmpty) return c;
    final h = o.customerHint.trim();
    return h.isNotEmpty ? h : 'Walk-in';
  }

  String _brandName(String? id) {
    if (id == null) return '';
    final m = _brands.where((b) => b.id == id).toList();
    return m.isEmpty ? '' : m.first.name;
  }

  /// The surface this holding was made on, or '' when it has none. No brand-mode
  /// The stockist's own word for the surface + admin canonical in brackets,
  /// e.g. "Goldenseries (Glossy)". '' when None. (project_per_brand_surface_mode)
  String _surfaceOf(TileDesign d) => d.surfaceCardLabel;

  String _holdingLabel(TileDesign d) {
    final b = _brandName(d.brandId);
    final surf = _surfaceOf(d);
    return [
      d.size.replaceAll(' mm', ''),
      if (surf.isNotEmpty) surf,
      if (b.isNotEmpty) b,
      d.quality,
    ].join(' · ');
  }

  void _snack(String m, [Color c = const Color(0xFF2E7D32)]) =>
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(m), backgroundColor: c));

  // ── Design picker ───────────────────────────────────────────────────────────

  /// Hand-picking a holding is where the wrong line gets chosen: one print can
  /// be held in several brand x quality x surface variants, and a flat list of
  /// them all is six near-identical rows. [showHoldingPicker] asks the print
  /// first, then only the variants that are actually ambiguous — each with its
  /// box count. (docs/DISPATCH_ORDER_BACKED_PLAN.md)
  Future<void> _pickDesign() async {
    final chosen = await showHoldingPicker(
      context,
      designs: _designs, // in-stock only
      brands: _brands,
    );
    if (chosen != null) setState(() => _sel = chosen);
  }

  void _resetRow() {
    _sel = null;
    _qtyCtrl.clear();
  }

  /// The batches of the selected design, and whether there's a real choice — the
  /// mobile add-flow branches on this the way the desktop entry bar does.
  bool get _selMultiBatch {
    if (_sel == null) return false;
    final lots = _lotsOf(_sel!);
    return lots.length > 1 &&
        lots.any((l) =>
            (l['batch'] ?? '').toString().isNotEmpty ||
            (l['location'] ?? '').toString().isNotEmpty);
  }

  /// The mobile path: a design in `_sel`, a quantity typed in `_qtyCtrl`. A design
  /// held in more than one batch instead opens a per-batch box entry, so the
  /// phone picks WHICH batch ships — same as the desktop entry bar.
  Future<void> _addLine() async {
    if (_sel == null) {
      _snack('Pick a design first.', _red);
      return;
    }
    final d = _sel!;
    if (_selMultiBatch) {
      await _mobileBatchEntry(d);
      return;
    }
    final qty = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
    if (qty <= 0) {
      _snack('Enter a quantity.', _red);
      return;
    }
    // One real batch → carry it so the line records its batch/location; untracked
    // → no lot, server takes the only lot.
    final lots = _lotsOf(d);
    final lot = (lots.length == 1 &&
            ((lots.first['batch'] ?? '').toString().isNotEmpty ||
                (lots.first['location'] ?? '').toString().isNotEmpty))
        ? lots.first
        : null;
    if (await _addLineFor(d, qty, lot)) setState(_resetRow);
  }

  /// Per-batch box entry for the phone: every batch with an empty box, type the
  /// boxes to dispatch from each, one Add creates a line per batch. (mobile L3)
  Future<void> _mobileBatchEntry(TileDesign d) async {
    final lots = _lotsOf(d);
    final ctrls = {
      for (final l in lots) (l['lot_id']).toString(): TextEditingController()
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Batches — ${_dispName(d)}'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('Type boxes to dispatch from each batch',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              ),
              const SizedBox(height: 8),
              for (final l in lots)
                _mobileLotRow(l, ctrls[(l['lot_id']).toString()]!),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: _navy, foregroundColor: Colors.white),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (ok == true) {
      var any = false;
      for (final l in lots) {
        final q =
            int.tryParse(ctrls[(l['lot_id']).toString()]!.text.trim()) ?? 0;
        if (q > 0 && await _addLineFor(d, q, l)) any = true;
      }
      if (any && mounted) setState(_resetRow);
    }
    for (final c in ctrls.values) {
      c.dispose();
    }
  }

  Widget _mobileLotRow(Map<String, dynamic> l, TextEditingController ctrl) {
    final batch = (l['batch'] ?? '').toString();
    final loc = (l['location'] ?? '').toString();
    final avail = (l['box_quantity'] as num?)?.toInt() ?? 0;
    final label = [
      if (batch.isNotEmpty) 'Batch $batch',
      if (loc.isNotEmpty) '📍 $loc',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
          child: Text(label.isEmpty ? 'No batch' : label,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
        Text('Avail: $avail',
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w800, color: _navy)),
        const SizedBox(width: 10),
        SizedBox(
          width: 62,
          child: TextField(
            controller: ctrl,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
                hintText: '0', isDense: true, border: OutlineInputBorder()),
          ),
        ),
      ]),
    );
  }

  /// Put [qty] boxes of [d] on the note, from batch [lot] (null when the stockist
  /// tracks no lots). One line = one (design, batch) picking instruction, so a
  /// second batch of the same design is a NEW line, not a duplicate. Shared by
  /// the mobile picker and the desktop keyboard bar. Returns false when the line
  /// was NOT added, so the caller leaves the row exactly as it was.
  Future<bool> _addLineFor(TileDesign d, int qty,
      [Map<String, dynamic>? lot]) async {
    // Over-count is against the BATCH you load from (or the whole holding when
    // untracked). Over-dispatch stays ALLOWED — the truck is the final truth —
    // but it must be a deliberate yes, not a typo. Cancel leaves the row as is.
    final avail =
        lot != null ? (lot['box_quantity'] as num?)?.toInt() ?? 0 : d.boxQuantity;
    if (qty > avail) {
      final allow = await _confirmOverStock(d, qty, avail, lot);
      if (!allow) return false;
    }
    final lotId = lot?['lot_id'] as String?;

    // An order row waiting at 0 boxes isn't a duplicate — it's the line being
    // filled in. Adopt its order numbers and attach the chosen batch.
    final orderIdx = _lines
        .indexWhere((l) => l.d.id == d.id && l.onOrder && l.qty == 0);
    if (orderIdx >= 0) {
      final o = _lines[orderIdx];
      setState(() {
        _lines[orderIdx] = _Line(d, qty,
            ordered: o.ordered,
            done: o.done,
            held: o.held,
            lineHeld: o.lineHeld,
            lotId: lotId,
            batch: lot?['batch'] as String?,
            location: lot?['location'] as String?,
            lotQty: avail);
        _lift(orderIdx);
      });
      return true;
    }

    // Same design AND same batch already on the note = a real duplicate.
    final dupIdx = _lines
        .indexWhere((l) => l.d.id == d.id && l.lotId == lotId && l.qty > 0);
    if (dupIdx >= 0) {
      await _resolveDuplicate(dupIdx, qty);
      return true;
    }

    setState(() {
      // Newest on top: the design-selection bar is pinned above the list, so the
      // row you just added lands right under it instead of off-screen below the
      // order's pre-filled rows.
      _lines.insert(
          0,
          _Line(d, qty,
              lotId: lotId,
              batch: lot?['batch'] as String?,
              location: lot?['location'] as String?,
              lotQty: avail));
    });
    return true;
  }

  /// Move the row you just put boxes on to the top, under the selection bar.
  /// Whether the row was new or an order line you filled in, "what I just
  /// touched" belongs where you can see it.
  void _lift(int idx) {
    if (idx <= 0) return;
    _lines.insert(0, _lines.removeAt(idx));
  }

  /// "You are dispatching more than you have." Names the exact holding (a print
  /// can be held in several surfaces/qualities, and the wrong one is precisely
  /// the mistake this screen is trying to prevent), shows both numbers, and
  /// makes the stockist say yes. Returns true = add the line anyway.
  Future<bool> _confirmOverStock(TileDesign d, int qty, int avail,
      [Map<String, dynamic>? lot]) async {
    // When a batch is chosen the ceiling is that batch, not the whole holding.
    final batch = (lot?['batch'] ?? '').toString();
    final inLabel = batch.isEmpty ? 'In godown' : 'In batch $batch';
    final short = qty - avail;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(batch.isEmpty ? 'More than godown stock' : 'More than this batch'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_dispName(d),
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            Text(_holdingLabel(d),
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(inLabel, style: const TextStyle(fontSize: 13)),
                Text('$avail boxes',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('You entered', style: TextStyle(fontSize: 13)),
                Text('$qty boxes',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600, color: _red)),
              ],
            ),
            const Divider(height: 18),
            Text('$short box${short == 1 ? '' : 'es'} more than you have.',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.bold, color: _red)),
            const SizedBox(height: 6),
            Text(
                'You can still dispatch it — stock will drop to 0, not below. '
                'Only allow this if the boxes really are going out.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: _red, foregroundColor: Colors.white),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _resolveDuplicate(int idx, int newQty) async {
    final l = _lines[idx];
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Already added'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${_dispName(l.d)} · ${_holdingLabel(l.d)}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Text('Existing:  ${l.qty} boxes'),
            Text('New:        $newQty boxes'),
            const SizedBox(height: 8),
            Text('Add both = ${l.qty + newQty} boxes',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, color: Color(0xFF2E7D32))),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'one'),
              child: const Text('Remove one')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, 'both'),
              child: const Text('Add both')),
        ],
      ),
    );
    if (choice == 'both') {
      setState(() {
        l.qty += newQty;
        // The dialog was open while the list could not change, so idx still
        // points at this row.
        _lift(idx);
        _resetRow();
      });
    } else if (choice == 'one') {
      setState(_resetRow);
    }
  }

  Future<void> _editQty(_Line l) async {
    final ctrl = TextEditingController(text: '${l.qty}');
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Boxes'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () =>
                  Navigator.pop(ctx, int.tryParse(ctrl.text.trim()) ?? l.qty),
              child: const Text('Set')),
        ],
      ),
    );
    if (v != null && v > 0) setState(() => l.qty = v);
  }

  /// The ✕ means different things on the two kinds of row. An order row must
  /// survive it — taking a design off the truck is not the same as taking it off
  /// the order — so it drops to 0 boxes and stays visible with its remaining.
  void _removeLine(int i) => setState(() {
        if (_lines[i].onOrder) {
          _lines[i].qty = 0;
        } else {
          _lines.removeAt(i);
        }
      });

  // ── Attached order ───────────────────────────────────────────────────────────

  Future<void> _pickOrder() async {
    setState(() => _busyOrder = true);
    final all = await _svc.getMyInquiries();
    if (!mounted) return;
    setState(() => _busyOrder = false);

    // A closed or rejected order can't take a dispatch — dispatch_inquiry raises.
    final open = all
        .where((o) => !o.isCompleted && !o.isRejected)
        .toList();

    if (open.isEmpty) {
      _snack('No open orders to attach.', _red);
      return;
    }

    final chosen = await showModalBottomSheet<InquiryOrder>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        String q = '';
        return StatefulBuilder(builder: (ctx, setSheet) {
          final ql = q.trim().toLowerCase();
          final res = open.where((o) {
            if (ql.isEmpty) return true;
            return o.token.toLowerCase().contains(ql) ||
                o.connectionCode.toLowerCase().contains(ql) ||
                o.company.toLowerCase().contains(ql) ||
                o.customerHint.toLowerCase().contains(ql);
          }).toList();
          return SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.7,
            child: Column(
              children: [
                const SizedBox(height: 12),
                const Text('Attach an order',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                  child: TextField(
                    onChanged: (v) => setSheet(() => q = v),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search order no, C-code, buyer…',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                Expanded(
                  child: res.isEmpty
                      ? const Center(child: Text('No orders match.'))
                      : ListView.separated(
                          itemCount: res.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final o = res[i];
                            final who = o.company.trim().isNotEmpty
                                ? o.company.trim()
                                : (o.customerHint.trim().isNotEmpty
                                    ? o.customerHint.trim()
                                    : 'Walk-in');
                            return ListTile(
                              leading: const Icon(Icons.receipt_long_outlined,
                                  color: _navy),
                              title: Text(o.token,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              subtitle: Text([
                                who,
                                if (o.connectionCode.isNotEmpty) o.connectionCode,
                                o.statusLabel,
                              ].join(' · ')),
                              trailing: Text('${o.totalBoxes} boxes',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade600)),
                              onTap: () => Navigator.pop(ctx, o),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        });
      },
    );
    if (chosen != null) await _attachOrder(chosen);
  }

  Future<void> _attachOrder(InquiryOrder o) async {
    setState(() => _busyOrder = true);
    final detail = await _svc.getInquiryDetail(o.id);
    if (!mounted) return;
    if (detail == null) {
      setState(() => _busyOrder = false);
      _snack('Could not load that order.', _red);
      return;
    }

    final lines = (detail['lines'] as List?) ?? const [];
    var missing = 0;
    setState(() {
      _order = o;
      _busyOrder = false;
      // 🏭 A full-software stockist (book orders on) tracks stock IN the app, so a
      // dispatch ALWAYS reduces it — "release hold only" would leave phantom boxes.
      // Force reduce and hide the choice (below). External-count stockists still pick.
      if (currentStockistBookOrders) _reduceStock = true;
      // The order names the buyer; a customer would be collected and dropped.
      _custId = null;
      _custNameCtrl.clear();

      for (final raw in lines) {
        final m = Map<String, dynamic>.from(raw as Map);
        final id = (m['design_id'] ?? '').toString();
        final ordered = (m['quantity'] as num?)?.toInt() ?? 0;
        final done = (m['dispatched_qty'] as num?)?.toInt() ?? 0;
        final held = (m['held'] as num?)?.toInt() ?? 0;
        final lineHeld = (m['line_held'] as num?)?.toInt() ?? 0;
        final d = _designById(id);
        if (d == null) {
          missing++;
          continue;
        }
        final idx = _lines.indexWhere((l) => l.d.id == id);
        if (idx >= 0) {
          // Already loaded by hand — keep the boxes, adopt the order's numbers.
          _lines[idx] = _Line(d, _lines[idx].qty,
              ordered: ordered, done: done, held: held, lineHeld: lineHeld);
        } else {
          _lines.add(_Line(d, 0,
              ordered: ordered, done: done, held: held, lineHeld: lineHeld));
        }
      }
    });
    if (missing > 0) {
      _snack('$missing order line${missing == 1 ? '' : 's'} skipped — design no longer exists.',
          Colors.orange.shade800);
    }
  }

  /// Detaching keeps whatever is already on the truck, as plain walk-in rows.
  void _detachOrder() => setState(() {
        _order = null;
        _close = null;
        _reduceStock = null; // no holding to release without an order
        _lines.removeWhere((l) => l.onOrder && l.qty == 0);
        for (var i = 0; i < _lines.length; i++) {
          if (_lines[i].onOrder) _lines[i] = _Line(_lines[i].d, _lines[i].qty);
        }
      });

  // ── Customer (opt-in) ────────────────────────────────────────────────────────

  Future<void> _pickCustomer() async {
    final picked = await CustomerPicker.show(context,
        customers: _customers, svc: _svc);
    if (picked == null) return;
    final id = (picked['id'] ?? '').toString();
    if (id.isEmpty) return;
    setState(() {
      // A freshly created customer is not yet in _customers — keep it so a
      // re-open of the picker shows it too.
      if (!_customers.any((c) => (c['id'] ?? '').toString() == id)) {
        _customers = [..._customers, picked];
      }
      _custId = id;
      _custNameCtrl.text = (picked['name'] ?? '').toString();
    });
  }

  // ── Record ───────────────────────────────────────────────────────────────────

  Future<void> _record() async {
    if (_lines.isEmpty) {
      _snack('Add at least one design.', _red);
      return;
    }
    // With an order attached the rows start at 0 boxes, so a non-empty list is
    // not yet a dispatch.
    if (_totalBoxes <= 0) {
      _snack('Enter boxes on at least one line.', _red);
      return;
    }

    // With an order attached, neither fate is assumed. Say what's missing and
    // send the stockist straight back to the chips.
    if (_order != null) {
      final missing = <String>[
        // Full-software stockists never see the stock chips (always reduce).
        if (_reduceStock == null && !currentStockistBookOrders) 'stock',
        if (_remainingAfter > 0 && _close == null) 'leftovers',
      ];
      if (missing.isNotEmpty) {
        await _explainMissing(missing);
        return;
      }
    }

    // Both warnings only matter when stock actually moves. In "release holding
    // only" mode P_Stock is untouched, so neither can happen.
    final over = _reduceStock == true
        ? _lines.where((l) => l.qty > 0 && l.qty > l.d.boxQuantity).toList()
        : const <_Line>[];
    final breaks = _reduceStock == true
        ? _lines
            .where((l) =>
                l.qty > 0 &&
                l.otherHeld > 0 &&
                (l.d.boxQuantity - l.qty) < l.otherHeld)
            .toList()
        : const <_Line>[];

    if (!await _confirmSheet(over, breaks)) return;

    setState(() => _saving = true);
    try {
      // Only what's actually on the truck. Order rows left at 0 are omitted —
      // prune=false means the server leaves them, and their remaining, alone.
      final sent = _lines.where((l) => l.qty > 0).toList();
      // One line = one (design, batch), but the server takes a design ONCE with a
      // per-batch `lots` array. Group same-design lines: sum the boxes, collect
      // the batches. A line with no batch (untracked) sends no lots → oldest-first.
      final byDesign = <String, Map<String, dynamic>>{};
      for (final l in sent) {
        final m = byDesign.putIfAbsent(
            l.d.id, () => {'design_id': l.d.id, 'dispatch': 0});
        m['dispatch'] = (m['dispatch'] as int) + l.qty;
        if (l.lotId != null) {
          final lots = (m['lots'] as List?) ?? <Map<String, dynamic>>[];
          lots.add({'lot_id': l.lotId, 'qty': l.qty});
          m['lots'] = lots;
        }
      }
      final lines = byDesign.values.toList();
      final total = _totalBoxes;

      final order = _order;
      final Map<String, dynamic> res;
      if (order != null) {
        res = await _svc.dispatchInquiry(
          order.id,
          lines,
          invoiceNo: _invoiceCtrl.text.trim(),
          vehicleNo: _vehicleCtrl.text.trim(),
          transporter: _transporterCtrl.text.trim(),
          note: _noteCtrl.text.trim(),
          date: _date,
          // Full-software stockists always reduce (no chips shown).
          reduceStock: currentStockistBookOrders ? true : _reduceStock!,
          // A full dispatch always closes; a partial uses the chosen fate.
          close: _remainingAfter == 0 ? true : _close!,
          prune: false, // these rows are the truck, not the whole order
        );
      } else {
        res = await _svc.dispatchWalkin(
          lines,
          customerId: _customersEnabled ? _custId : null,
          customerName: _custNameCtrl.text.trim(),
          invoice: _invoiceCtrl.text.trim(),
          vehicle: _vehicleCtrl.text.trim(),
          transporter: _transporterCtrl.text.trim(),
          note: _noteCtrl.text.trim(),
          date: _date,
        );
      }
      if (!mounted) return;

      final no = (res['dispatch_no'] ?? '').toString();
      final status = (res['status'] ?? '').toString();
      final outstanding = (res['outstanding'] as num?)?.toInt() ?? 0;

      final noteId = (res['note_id'] ?? '').toString();
      // Close the loop back to the loading list this dispatch came from.
      if (widget.loadingListId != null && noteId.isNotEmpty) {
        await _svc.loadingListMarkDispatched(widget.loadingListId!, noteId);
      }
      final report = _buildReport(no, sent, total, outstanding, status);
      await _showReportSheet(report, status,
          outstanding: outstanding,
          noteId: noteId,
          sent: sent,
          total: total,
          dispatchNo: no);
      if (!mounted) return;

      if (Navigator.of(context).canPop()) {
        Navigator.pop(context, true);
      } else {
        setState(() {
          _lines.clear();
          _order = null;
          _close = null;
          _reduceStock = null;
          _saving = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('$e', _red);
    }
  }

  /// Nothing was chosen, so nothing is assumed. Spell out each pending choice
  /// and what its two options mean; Close drops the stockist back on the screen
  /// with the chips waiting, nothing entered lost.
  Future<void> _explainMissing(List<String> missing) async {
    Widget block(String title, String a, String aSub, String b, String bSub,
        Color ca, Color cb) {
      Widget opt(String t, String s, Color c) => Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.radio_button_off, size: 15, color: c),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: c)),
                    Text(s,
                        style: TextStyle(
                            fontSize: 11.5, color: Colors.grey.shade700)),
                  ],
                ),
              ),
            ]),
          );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),
          Text(title,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey.shade600,
                  letterSpacing: 0.3)),
          opt(a, aSub, ca),
          opt(b, bSub, cb),
        ],
      );
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Choose before recording'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  missing.length == 2
                      ? 'Two choices are still empty. Nothing is picked for you '
                          '— both change what this dispatch does.'
                      : 'One choice is still empty. Nothing is picked for you '
                          '— it changes what this dispatch does.',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade800)),
              if (missing.contains('stock'))
                block(
                    'WHAT THIS DOES TO STOCK',
                    'Reduce stock',
                    'Your system stock drops by the dispatched boxes.',
                    'Release hold only',
                    'Stock is unchanged; only the held boxes are freed. '
                        'Update your own count afterwards.',
                    _red,
                    const Color(0xFF1565C0)),
              if (missing.contains('leftovers'))
                block(
                    'BOXES LEFT ON THE ORDER ($_remainingAfter)',
                    'Keep open',
                    'The order stays open and the $_remainingAfter boxes stay '
                        'reserved for the buyer.',
                    'Close order',
                    'The order is completed now and the $_remainingAfter boxes '
                        'are released — the buyer must re-order them.',
                    _navy,
                    _red),
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(
                backgroundColor: _navy, foregroundColor: Colors.white),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// One confirmation for everything: what's leaving, what it does to the order,
  /// the over-stock and booking warnings, and — when an order is attached and a
  /// stock mode was therefore chosen — a blinking notice of what that mode does,
  /// with Record gated behind a 3-second countdown so it can't be hit by reflex.
  Future<bool> _confirmSheet(List<_Line> over, List<_Line> breaks) async {
    final attached = _order != null;
    final reduce = _reduceStock == true; // guarded above when attached
    final modeMsg = reduce
        ? 'Quantity is reduced from Stock'
        : 'Release quantity from Holding';
    final modeDetail = reduce
        ? 'Your system stock will drop by the dispatched boxes.'
        : 'Your system stock is NOT changed — only the held boxes are released. '
            'Update your own stock count afterwards.';
    final modeColor = reduce ? _red : const Color(0xFF1565C0);

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        int countdown = attached ? 3 : 0;
        bool visible = true;
        Timer? blink;
        Timer? tick;
        return StatefulBuilder(builder: (ctx, setD) {
          if (attached) {
            blink ??= Timer.periodic(const Duration(milliseconds: 450), (t) {
              if (!ctx.mounted) return t.cancel();
              setD(() => visible = !visible);
            });
            tick ??= Timer.periodic(const Duration(seconds: 1), (t) {
              if (!ctx.mounted) return t.cancel();
              if (countdown <= 1) {
                t.cancel();
                setD(() => countdown = 0);
              } else {
                setD(() => countdown--);
              }
            });
          }
          void close(bool v) {
            blink?.cancel();
            tick?.cancel();
            Navigator.pop(ctx, v);
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        'Dispatch $_loadedCount design${_loadedCount == 1 ? '' : 's'} · '
                        '$_totalBoxes boxes'
                        '${attached ? ' for $_buyerLabel' : (_custNameCtrl.text.trim().isNotEmpty ? ' to ${_custNameCtrl.text.trim()}' : '')}?',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                    if (attached) ...[
                      const SizedBox(height: 8),
                      Text('Order ${_order!.token}',
                          style: const TextStyle(fontSize: 12.5)),
                      const SizedBox(height: 4),
                      Text(
                          _remainingAfter == 0
                              ? 'Nothing left on the order — it will be completed.'
                              : _close == true
                                  ? '$_remainingAfter box${_remainingAfter == 1 ? '' : 'es'} left over — '
                                      'the order will be CLOSED and they are released.'
                                  : '$_remainingAfter box${_remainingAfter == 1 ? '' : 'es'} left over — '
                                      'the order stays OPEN and they stay reserved.',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade700)),
                      const SizedBox(height: 12),
                      AnimatedOpacity(
                        opacity: visible ? 1 : 0.15,
                        duration: const Duration(milliseconds: 200),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 14),
                          decoration: BoxDecoration(
                            color: modeColor.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: modeColor),
                          ),
                          child: Text(modeMsg,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: modeColor)),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(modeDetail,
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade700)),
                    ],
                    if (over.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                          '${over.length} line${over.length == 1 ? '' : 's'} exceed current stock — '
                          'allowed, stock floors at 0:',
                          style: TextStyle(
                              fontSize: 12, color: Colors.orange.shade800)),
                      for (final l in over)
                        Text('• ${_dispName(l.d)}: ${l.qty} > ${l.d.boxQuantity}',
                            style: TextStyle(
                                fontSize: 11.5, color: Colors.orange.shade800)),
                    ],
                    if (breaks.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                          '${breaks.length} design${breaks.length == 1 ? '' : 's'} would be left '
                          'short of boxes already committed to other buyers:',
                          style: TextStyle(
                              fontSize: 12, color: Colors.orange.shade800)),
                      for (final l in breaks)
                        Text(
                            '• ${l.d.name}: ${(l.d.boxQuantity - l.qty).clamp(0, 1 << 30)} left '
                            'vs ${l.otherHeld} booked',
                            style: TextStyle(
                                fontSize: 11.5, color: Colors.orange.shade800)),
                    ],
                    const SizedBox(height: 14),
                    Row(children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => close(false),
                          child: const Text('Back'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: countdown > 0 ? null : () => close(true),
                          style: ElevatedButton.styleFrom(
                              backgroundColor: _red,
                              foregroundColor: Colors.white),
                          child: Text(countdown > 0
                              ? 'Record Dispatch ($countdown)'
                              : 'Record Dispatch'),
                        ),
                      ),
                    ]),
                  ],
                ),
              ),
            ),
          );
        });
      },
    );
    return ok == true;
  }

  // ── Buyer report ─────────────────────────────────────────────────────────────

  /// Phone to WhatsApp the report to: the order's buyer, else the saved customer.
  /// Empty when neither has one — then Copy is the only option.
  (String, String) get _reportPhone {
    final o = _order;
    if (o != null) return (o.countryCode, o.phone);
    if (_customersEnabled && _custId != null) {
      for (final c in _customers) {
        if ((c['id'] ?? '').toString() == _custId) {
          return (
            (c['country_code'] ?? '').toString(),
            (c['phone'] ?? '').toString()
          );
        }
      }
    }
    return ('', '');
  }

  String _buildReport(String dispatchNo, List<_Line> sent, int total,
      int outstanding, String status) {
    final o = _order;
    final b = StringBuffer();
    if (o != null) {
      b.writeln('Dispatch update — Order ${o.token}');
    } else {
      final who = _custNameCtrl.text.trim();
      b.writeln('Dispatch${who.isEmpty ? '' : ' — $who'}');
    }
    if (dispatchNo.isNotEmpty) b.writeln('Dispatch No: $dispatchNo');
    b.writeln('Date: ${_fmtDate(_date)}');
    if (_invoiceCtrl.text.trim().isNotEmpty) {
      b.writeln('Invoice No: ${_invoiceCtrl.text.trim()}');
    }
    if (_vehicleCtrl.text.trim().isNotEmpty) {
      b.writeln('Vehicle No: ${_vehicleCtrl.text.trim()}');
    }
    if (_transporterCtrl.text.trim().isNotEmpty) {
      b.writeln('Transporter: ${_transporterCtrl.text.trim()}');
    }
    b.writeln();
    b.writeln('Dispatched now:');
    for (var i = 0; i < sent.length; i++) {
      final l = sent[i];
      b.writeln(
          '${i + 1}. ${_dispName(l.d)} (${l.d.size.replaceAll(' mm', '')}) — ${l.qty} boxes');
    }
    b.writeln('Total dispatched: $total boxes');
    if (o != null && outstanding > 0) {
      b.writeln(status == 'completed'
          ? 'Remaining $outstanding boxes: not included — please place a new '
              'order if you still need them.'
          : 'Balance $outstanding boxes: reserved for you, coming in a later '
              'dispatch.');
    }
    if (_noteCtrl.text.trim().isNotEmpty) {
      b.writeln();
      b.writeln('Note: ${_noteCtrl.text.trim()}');
    }
    return b.toString();
  }

  /// The order's outstanding note, for the printed / shared dispatch.
  String _balanceLine(String status, int outstanding) {
    if (_order == null || outstanding <= 0) return '';
    return status == 'completed'
        ? 'Remaining $outstanding boxes: not included — please place a new order '
            'if you still need them.'
        : 'Balance $outstanding boxes: reserved for you, coming in a later dispatch.';
  }

  /// The dispatch note as printable PDF bytes. [loadingList] = the supervisor's
  /// pre-load copy: titled LOADING LIST, no dispatch number, and no order-balance
  /// line (nothing has shipped yet). Batch · location print on both. (LOT L3)
  Future<Uint8List> _dispatchPdfBytes(
      List<_Line> sent, int total, String dispatchNo, String status,
      int outstanding, {bool loadingList = false}) async {
    final bytes = await buildDispatchPdf(DispatchPdfData(
      stockistName: _stockistName,
      who: _order != null ? _buyerLabel : _custNameCtrl.text.trim(),
      dispatchNo: dispatchNo,
      date: _fmtDate(_date),
      invoice: _invoiceCtrl.text.trim(),
      vehicle: _vehicleCtrl.text.trim(),
      transporter: _transporterCtrl.text.trim(),
      note: _noteCtrl.text.trim(),
      lines: [
        for (final l in sent)
          DispatchPdfLine(
            name: l.d.name,
            size: l.d.size,
            surface: l.d.hasSurface ? l.d.surfaceCardLabel : '',
            quality: l.d.quality,
            boxes: l.qty,
            brand: _brandName(l.d.brandId),
            batch: l.batch ?? '',
            location: l.location ?? '',
          )
      ],
      total: total,
      balanceLine: loadingList ? '' : _balanceLine(status, outstanding),
      title: loadingList ? 'LOADING LIST' : 'DISPATCH NOTE',
      totalLabel: loadingList ? 'Total to load' : 'Total dispatched',
    ));
    return Uint8List.fromList(bytes);
  }

  /// Print the loading list a stockist hands the supervisor BEFORE the truck is
  /// loaded — from the current draft, nothing saved, no stock moved. (LOT L3)
  Future<void> _printLoadingList() async {
    final sent = _lines.where((l) => l.qty > 0).toList();
    if (sent.isEmpty) {
      _snack('Add designs to the list first.', _red);
      return;
    }
    try {
      final bytes =
          await _dispatchPdfBytes(sent, _totalBoxes, '', '', 0, loadingList: true);
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    } catch (e) {
      if (mounted) _snack('$e', _red);
    }
  }

  /// Preview the report, then act on it: Copy, WhatsApp, Print, PDF, Send Link.
  /// WhatsApp is offered even with NO saved number — it opens WhatsApp to pick a
  /// contact. Only Call needs a number. ([[feedback_copy_when_no_whatsapp]])
  ///
  /// [outstanding] separates the two ways an order reaches 'completed': nothing
  /// left (finished) versus closed short with boxes released.
  Future<void> _showReportSheet(String report, String status,
      {int outstanding = 0,
      String noteId = '',
      List<_Line> sent = const [],
      int total = 0,
      String dispatchNo = ''}) async {
    final (code, phone) = _reportPhone;
    final hasPhone = phone.trim().isNotEmpty;
    final digits = '$code$phone'.replaceAll(RegExp(r'[^0-9]'), '');

    // WhatsApp the given text — to the number if we have one, else open WhatsApp
    // so the stockist can choose a contact.
    Future<void> whatsApp(String text) async {
      final uri = hasPhone
          ? Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(text)}')
          : Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}');
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        bool busy = false;
        return StatefulBuilder(builder: (ctx, setSheet) {
          Future<void> guard(Future<void> Function() body) async {
            if (busy) return;
            setSheet(() => busy = true);
            try {
              await body();
            } catch (e) {
              if (mounted) _snack('$e', _red);
            } finally {
              if (ctx.mounted) setSheet(() => busy = false);
            }
          }

          Widget act(IconData icon, String label, Color color,
                  Future<void> Function() onTap) =>
              OutlinedButton.icon(
                onPressed: busy ? null : () => guard(onTap),
                icon: Icon(icon, size: 18, color: color),
                label: Text(label, style: TextStyle(color: color)),
                style: OutlinedButton.styleFrom(
                    side: BorderSide(color: color.withValues(alpha: 0.5)),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 11)),
              );

          return Padding(
            padding: EdgeInsets.fromLTRB(
                16, 16, 16, 16 + MediaQuery.of(ctx).viewPadding.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.check_circle, color: Color(0xFF2E7D32)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        status != 'completed'
                            ? 'Dispatch recorded'
                            : outstanding > 0
                                ? 'Order closed · $outstanding released'
                                : 'Order completed',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                ]),
                const SizedBox(height: 10),
                Text(
                    _order != null
                        ? 'Dispatch report for the buyer:'
                        : 'Dispatch report:',
                    style: const TextStyle(fontSize: 12.5)),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 220),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: SingleChildScrollView(
                    child: Text(report,
                        style: const TextStyle(fontSize: 12.5, height: 1.5)),
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    act(Icons.copy, 'Copy', _navy, () async {
                      await Clipboard.setData(ClipboardData(text: report));
                      if (mounted) _snack('Report copied.');
                    }),
                    act(Icons.chat_rounded, 'WhatsApp',
                        const Color(0xFF25D366), () => whatsApp(report)),
                    act(Icons.print_outlined, 'Print', _navy, () async {
                      final bytes = await _dispatchPdfBytes(
                          sent, total, dispatchNo, status, outstanding);
                      await Printing.layoutPdf(onLayout: (_) async => bytes);
                    }),
                    act(Icons.picture_as_pdf_outlined, 'PDF', _red, () async {
                      final bytes = await _dispatchPdfBytes(
                          sent, total, dispatchNo, status, outstanding);
                      await Printing.sharePdf(
                          bytes: bytes,
                          filename:
                              'dispatch_${dispatchNo.isEmpty ? 'note' : dispatchNo}.pdf');
                    }),
                    act(Icons.link, 'Send link', const Color(0xFF00838F),
                        () async {
                      if (noteId.isEmpty) {
                        if (mounted) _snack('No link for this dispatch.', _red);
                        return;
                      }
                      final token = await _svc.createDispatchLink(noteId);
                      if (token == null || token.isEmpty) return;
                      final url = '${AppConfig.shareBaseUrl}/d/$token';
                      await Clipboard.setData(ClipboardData(text: url));
                      await whatsApp('Dispatch details:\n$url');
                      if (mounted) _snack('Link copied & WhatsApp opened.');
                    }),
                  ],
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Done')),
                ),
              ],
            ),
          );
        });
      },
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  String _fmtDate(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: _red,
        foregroundColor: Colors.white,
        title: const Text('Dispatch'),
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The supervisor's loading list — printed BEFORE the truck loads, so it
          // sits ahead of Record. Nothing is saved; it's just the pull sheet.
          // Hidden until there's something to load. (LOT layer L3)
          if (_lines.any((l) => l.qty > 0))
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: SizedBox(
                width: double.infinity,
                height: 46,
                child: OutlinedButton.icon(
                  onPressed: _saving ? null : _printLoadingList,
                  icon: const Icon(Icons.print_outlined, size: 18),
                  label: const Text('Print loading list',
                      style: TextStyle(fontSize: 15)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _navy,
                    side: BorderSide(color: _navy.withValues(alpha: 0.5)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ),
          SaveBar(
            label: _lines.isEmpty
                ? 'Record Dispatch'
                : 'Record Dispatch ($_totalBoxes boxes)',
            icon: Icons.local_shipping_outlined,
            color: _red,
            onPressed: _record,
            saving: _saving,
            dirty: _lines.isNotEmpty,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (wide ? _desktopBody() : _mobileBody()),
    );
  }

  // Shared: the customer + dispatch-details section.
  Widget _detailsCard() {
    InputDecoration dec(String l) => InputDecoration(
        labelText: l,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)));
    final attached = _order != null;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(attached ? 'Order & dispatch details' : 'Customer & dispatch details',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 10),
            _orderField(),
            const SizedBox(height: 10),
            // While attached, the order already carries its own customer (chosen
            // when the order was made) and dispatch_inquiry copies it onto the
            // note — so re-entering it here would be redundant. A walk-in has no
            // order, so it collects the customer itself. (project_customer_history)
            if (!attached) ...[
              if (_customersEnabled)
                InkWell(
                  onTap: _pickCustomer,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                    decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade400),
                        borderRadius: BorderRadius.circular(8)),
                    child: Row(children: [
                      const Icon(Icons.person_outline, size: 18, color: _navy),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                            _custNameCtrl.text.trim().isEmpty
                                ? 'Select or add customer (optional)'
                                : _custNameCtrl.text.trim(),
                            style: TextStyle(
                                fontSize: 14,
                                color: _custNameCtrl.text.trim().isEmpty
                                    ? Colors.grey.shade500
                                    : Colors.black87)),
                      ),
                      Icon(Icons.arrow_drop_down, color: Colors.grey.shade600),
                    ]),
                  ),
                )
              else
                TextField(
                  controller: _custNameCtrl,
                  onChanged: (_) => setState(() {}),
                  decoration: dec('Customer name (optional)'),
                ),
              const SizedBox(height: 10),
            ],
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: _invoiceCtrl, decoration: dec('Invoice No'))),
              const SizedBox(width: 10),
              Expanded(
                  child: TextField(
                      controller: _vehicleCtrl,
                      decoration: dec('Truck / Vehicle No'))),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: _date,
                      firstDate: DateTime(2025),
                      lastDate: DateTime.now().add(const Duration(days: 1)),
                    );
                    if (d != null) setState(() => _date = d);
                  },
                  icon: const Icon(Icons.event, size: 16),
                  label: Text('Date: ${_fmtDate(_date)}',
                      style: const TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: _navy,
                      minimumSize: const Size.fromHeight(44)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                  child: TextField(
                      controller: _transporterCtrl,
                      decoration: dec('Transporter (optional)'))),
            ]),
            const SizedBox(height: 10),
            TextField(
                controller: _noteCtrl,
                maxLines: 2,
                decoration: dec('Note (optional)')),
            // "Release hold only" is for stockists who keep their real count in
            // OTHER software. A full-software (book orders) stockist tracks stock
            // here, so a dispatch always reduces it — no choice, no foot-gun.
            if (attached && !currentStockistBookOrders) ...[
              const SizedBox(height: 14),
              Text('What this does to stock',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Colors.grey.shade600)),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: _fateChip(
                      label: 'Reduce stock',
                      sub: 'P drops by the boxes',
                      selected: _reduceStock == true,
                      color: _red,
                      onTap: () => setState(() => _reduceStock = true)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _fateChip(
                      label: 'Release hold only',
                      sub: 'stock unchanged',
                      selected: _reduceStock == false,
                      color: const Color(0xFF1565C0),
                      onTap: () => setState(() => _reduceStock = false)),
                ),
              ]),
            ],
            // The order's fate (the boxes still on it) is a SEPARATE question
            // from the stock reduction, so it shows for every attached order —
            // full-software ones included.
            if (attached && _remainingAfter > 0) ...[
              const SizedBox(height: 14),
              Text('Boxes left on the order ($_remainingAfter)',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Colors.grey.shade600)),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: _fateChip(
                      label: 'Keep open',
                      sub: 'stay reserved',
                      selected: _close == false,
                      color: _navy,
                      onTap: () => setState(() => _close = false)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _fateChip(
                      label: 'Close order',
                      sub: 'released',
                      selected: _close == true,
                      color: _red,
                      onTap: () => setState(() => _close = true)),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _fateChip({
    required String label,
    required String sub,
    required bool selected,
    required Color color,
    required VoidCallback onTap,
  }) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: 0.08) : null,
            border: Border.all(
                color: selected ? color : Colors.grey.shade400,
                width: selected ? 1.6 : 1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 16, color: selected ? color : Colors.grey.shade500),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: selected ? color : Colors.black87)),
                  Text(sub,
                      style: TextStyle(
                          fontSize: 10.5, color: Colors.grey.shade600)),
                ],
              ),
            ),
          ]),
        ),
      );

  /// Attach / show / detach the order this dispatch is against.
  Widget _orderField() {
    if (_busyOrder) {
      return Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade400),
            borderRadius: BorderRadius.circular(8)),
        child: const SizedBox(
            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final o = _order;
    if (o == null) {
      return InkWell(
        onTap: _pickOrder,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
          decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade400),
              borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            const Icon(Icons.link, size: 18, color: _navy),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Attach an order (optional)',
                  style: TextStyle(fontSize: 14, color: Colors.grey.shade500)),
            ),
            Icon(Icons.arrow_drop_down, color: Colors.grey.shade600),
          ]),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
          color: _navy.withValues(alpha: 0.05),
          border: Border.all(color: _navy.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        const Icon(Icons.receipt_long, size: 18, color: _navy),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                  [o.token, if (o.connectionCode.isNotEmpty) o.connectionCode]
                      .join('  ·  '),
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w700, color: _navy)),
              const SizedBox(height: 1),
              Text(_buyerLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Detach order',
          icon: Icon(Icons.link_off, size: 20, color: Colors.grey.shade600),
          onPressed: _detachOrder,
        ),
      ]),
    );
  }

  // ── Phone layout ─────────────────────────────────────────────────────────────

  Widget _mobileBody() => ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        children: [
          _detailsCard(),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _selectField('Design',
                      _sel == null ? 'Search & select design' : _sel!.name,
                      Icons.grid_view_rounded, _pickDesign, _sel == null),
                  if (_sel != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, left: 4),
                      child: Text(
                          '${_holdingLabel(_sel!)} · ${_sel!.boxQuantity} in stock',
                          style: TextStyle(
                              fontSize: 11.5, color: Colors.grey.shade600)),
                    ),
                  const SizedBox(height: 10),
                  // A design in several batches picks boxes per batch; otherwise a
                  // single quantity, as before.
                  if (_selMultiBatch)
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton.icon(
                        onPressed: _addLine,
                        icon: const Icon(Icons.inventory_2_outlined, size: 18),
                        label: const Text('Set batches & add'),
                        style: ElevatedButton.styleFrom(
                            backgroundColor: _navy,
                            foregroundColor: Colors.white),
                      ),
                    )
                  else
                    Row(children: [
                      Expanded(child: _qtyField()),
                      const SizedBox(width: 10),
                      SizedBox(
                        height: 48,
                        child: ElevatedButton.icon(
                          onPressed: _addLine,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add'),
                          style: ElevatedButton.styleFrom(
                              backgroundColor: _navy,
                              foregroundColor: Colors.white),
                        ),
                      ),
                    ]),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          if (_lines.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                  child: Text('No designs added yet.',
                      style: TextStyle(color: Colors.grey.shade500))),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text('$_loadedCount to dispatch · $_totalBoxes boxes',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: Colors.grey.shade700)),
            ),
            const SizedBox(height: 8),
            ..._lines.asMap().entries.map((e) => _lineTile(e.key)),
          ],
        ],
      );

  // ── Attribute chips ──────────────────────────────────────────────────────────
  //
  // A holding used to read as one grey run-on line. Each attribute now gets its
  // own chip, in the order brand · size · quality · surface. Quality keeps the
  // app-wide badge colours (TileCard's _QualityBadge): Premium amber, Standard
  // blue, Both green — so a Premium box looks the same here as on a buyer card.

  static Widget _chip(String text,
      {required Color bg, required Color fg, IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 10, color: fg),
            const SizedBox(width: 3),
          ],
          Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 10, color: fg, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  static Widget _qualityChip(String quality) {
    switch (quality.toLowerCase()) {
      case 'premium':
        return _chip(quality,
            bg: const Color(0xFFFFF8E1),
            fg: const Color(0xFFF9A825),
            icon: Icons.star_rounded);
      case 'both':
        return _chip(quality,
            bg: const Color(0xFFE8F5E9),
            fg: const Color(0xFF2E7D32),
            icon: Icons.layers_outlined);
      default:
        return _chip(quality,
            bg: const Color(0xFFE3F2FD),
            fg: const Color(0xFF1565C0),
            icon: Icons.verified_outlined);
    }
  }

  static final _greyChipBg = Colors.grey.shade100;
  static final _greyChipFg = Colors.grey.shade700;

  /// brand · size · quality · surface, in that order.
  List<Widget> _attrChips(TileDesign d) {
    final brand = _brandName(d.brandId);
    final surface = _surfaceOf(d);
    return [
      if (brand.isNotEmpty)
        _chip(brand,
            bg: const Color(0xFFE3F2FD),
            fg: const Color(0xFF1565C0),
            icon: Icons.business_outlined),
      _chip(d.size.replaceAll(' mm', ''),
          bg: _greyChipBg, fg: _greyChipFg, icon: Icons.straighten),
      _qualityChip(d.quality),
      if (surface.isNotEmpty)
        _chip(surface, bg: _greyChipBg, fg: _greyChipFg),
    ];
  }

  /// The numbers, kept apart from the attributes: stock, what the order expects,
  /// and boxes already promised to OTHER buyers.
  String _numbersFor(_Line l) {
    final parts = <String>['${l.d.boxQuantity} stock'];
    if (l.onOrder) {
      parts.add('ordered ${l.ordered}');
      if (l.done > 0) parts.add('${l.done} sent');
      parts.add('${l.remainingAfter} left');
    }
    if (l.otherHeld > 0) parts.add('${l.otherHeld} booked');
    return parts.join('  ·  ');
  }

  /// The batch/location this line ships from, as a small tag for a row. Empty
  /// string → nothing (untracked stock). (LOT layer L3)
  Widget? _batchTag(_Line l) {
    final label = l.lotLabel;
    if (label.isEmpty) return null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _navy.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _navy.withValues(alpha: 0.25)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.inventory_2_outlined, size: 13, color: _navy),
        const SizedBox(width: 4),
        Text(label,
            style: const TextStyle(
                fontSize: 11.5, color: _navy, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Widget _lineTile(int i) {
    final l = _lines[i];
    final over = l.qty > l.d.boxQuantity;
    final idle = l.qty == 0; // an order row not on this truck
    final lotChip = _batchTag(l);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        child: Row(children: [
          if (l.onOrder)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Icon(Icons.receipt_long,
                  size: 15, color: _navy.withValues(alpha: idle ? 0.35 : 0.8)),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.d.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: idle ? Colors.grey.shade500 : Colors.black87)),
                const SizedBox(height: 5),
                Opacity(
                  opacity: idle ? 0.55 : 1,
                  child: Wrap(
                      spacing: 5, runSpacing: 4, children: _attrChips(l.d)),
                ),
                const SizedBox(height: 5),
                Text('${_numbersFor(l)}${over ? '  ·  over!' : ''}',
                    style: TextStyle(
                        fontSize: 11.5,
                        color: over ? _red : Colors.grey.shade600)),
                if (lotChip != null) ...[
                  const SizedBox(height: 6),
                  Align(alignment: Alignment.centerLeft, child: lotChip),
                ],
              ],
            ),
          ),
          InkWell(
            onTap: () => _editQty(l),
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                  color: (idle ? Colors.grey : _red).withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(6)),
              child: Text('${l.qty}',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: idle ? Colors.grey.shade500 : _red)),
            ),
          ),
          IconButton(
            tooltip: l.onOrder ? 'Take off this truck' : 'Remove',
            icon: Icon(
                l.onOrder ? Icons.remove_circle_outline : Icons.delete_outline,
                size: 20,
                color: idle ? Colors.grey.shade400 : Colors.red.shade400),
            onPressed: idle ? null : () => _removeLine(i),
          ),
        ]),
      ),
    );
  }

  // ── Desktop layout ───────────────────────────────────────────────────────────
  //
  // Two panes. The left one is the work area and the table inside it takes every
  // pixel left over, because that's what the stockist is actually reading. The
  // right one is a fixed column of settings that scrolls on its own. Stacking
  // them (as this screen used to) squeezed the table to nothing on a laptop.

  static const double _panelWidth = 400;

  Widget _desktopBody() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                children: [
                  _addBar(),
                  const SizedBox(height: 10),
                  Expanded(child: _desktopTable()),
                ],
              ),
            ),
            const SizedBox(width: 16),
            SizedBox(
              width: _panelWidth,
              child: SingleChildScrollView(child: _detailsCard()),
            ),
          ],
        ),
      );

  /// Desktop: the whole line from the keyboard —
  /// `delt ↓ Tab · m ↓ Tab · p ↓ Tab · 40 Enter`.
  ///
  /// It asks the same two questions the touch picker asks (the PRINT, then only
  /// the variants that are genuinely ambiguous, each carrying its box count) —
  /// the stockist just never has to reach for the mouse. And the fields are still
  /// clickable, so the mouse path is the picker, inline. No Browse button needed.
  Widget _addBar() => HoldingEntryBar(
        designs: _designs, // in-stock only
        brands: _brands,
        boxesOf: (d) => d.boxQuantity, // dispatch counts what is on the shelf
        lotsOf: _lotsOf, // batch chosen at entry (loading list)
        onAdd: _addLineFor,
      );

  Widget _desktopTable() {
    final attached = _order != null;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            color: const Color(0xFFF3F5F8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: _tableRow(null, attached),
          ),
          const Divider(height: 1),
          Expanded(
            child: _lines.isEmpty
                ? Center(
                    child: Text(
                        attached
                            ? 'This order has no lines.'
                            : 'No designs added — pick one above and Add.',
                        style: TextStyle(color: Colors.grey.shade500)))
                : ListView.separated(
                    itemCount: _lines.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) => Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      child: _tableRow(i, attached),
                    ),
                  ),
          ),
          const Divider(height: 1),
          Container(
            color: const Color(0xFFF3F5F8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(children: [
              Text(
                  '$_loadedCount line${_loadedCount == 1 ? '' : 's'} · $_totalBoxes boxes',
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w700)),
              if (attached) ...[
                Text(' · ', style: TextStyle(color: Colors.grey.shade500)),
                Text('$_remainingAfter left on order',
                    style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700)),
              ],
            ]),
          ),
        ],
      ),
    );
  }

  /// One table row. [i] null = the header. [attached] adds the ORD / SENT
  /// columns, which mean nothing without an order.
  Widget _tableRow(int? i, bool attached) {
    final header = i == null;
    final l = header ? null : _lines[i];
    final idle = l != null && l.qty == 0;
    final over = l != null && l.qty > l.d.boxQuantity;

    final lab = TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: Colors.grey.shade600,
        letterSpacing: 0.4);
    const cell = TextStyle(fontSize: 13);
    final dim = cell.copyWith(color: Colors.grey.shade700);

    Widget numCell(String s, {double w = 62, Color? color}) => SizedBox(
        width: w,
        child: Text(s,
            style: header
                ? lab
                : cell.copyWith(color: color ?? Colors.grey.shade700)));

    return Row(children: [
      SizedBox(
        width: 22,
        child: header || !l!.onOrder
            ? const SizedBox()
            : Icon(Icons.receipt_long,
                size: 14, color: _navy.withValues(alpha: idle ? 0.35 : 0.8)),
      ),
      Expanded(
          flex: 3,
          child: Text(header ? 'DESIGN' : l!.d.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: header
                  ? lab
                  : cell.copyWith(
                      fontWeight: FontWeight.w600,
                      color: idle ? Colors.grey.shade500 : Colors.black87))),
      Expanded(
        flex: 4,
        child: header
            ? Text('DETAILS', style: lab)
            : Opacity(
                opacity: idle ? 0.55 : 1,
                child: Wrap(
                    spacing: 5,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      ..._attrChips(l!.d),
                      if (l.otherHeld > 0)
                        Text('${l.otherHeld} booked',
                            style: dim.copyWith(fontSize: 11)),
                      if (_batchTag(l) case final tag?) tag,
                    ]),
              ),
      ),
      if (attached) ...[
        numCell(header ? 'ORD' : '${l!.ordered ?? '—'}'),
        numCell(header ? 'SENT' : '${l!.done}'),
      ],
      numCell(header ? 'STOCK' : '${l!.d.boxQuantity}',
          color: over ? _red : null),
      SizedBox(
        width: 84,
        child: header
            ? Text('QTY', style: lab, textAlign: TextAlign.right)
            : Align(
                alignment: Alignment.centerRight,
                child: InkWell(
                  onTap: () => _editQty(l),
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                        color:
                            (idle ? Colors.grey : _red).withValues(alpha: 0.07),
                        borderRadius: BorderRadius.circular(6)),
                    child: Text('${l!.qty}',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: idle ? Colors.grey.shade500 : _red)),
                  ),
                ),
              ),
      ),
      SizedBox(
        width: 40,
        child: header
            ? const SizedBox()
            : IconButton(
                tooltip: l!.onOrder ? 'Take off this truck' : 'Remove',
                icon: Icon(
                    l.onOrder
                        ? Icons.remove_circle_outline
                        : Icons.delete_outline,
                    size: 20,
                    color: idle ? Colors.grey.shade400 : Colors.red.shade400),
                onPressed: idle ? null : () => _removeLine(i),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints()),
      ),
    ]);
  }

  // ── Shared field widgets ─────────────────────────────────────────────────────

  Widget _qtyField() => SizedBox(
        height: 48,
        child: TextField(
          controller: _qtyCtrl,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: 'Boxes',
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      );

  Widget _selectField(String label, String value, IconData icon,
          VoidCallback onTap, bool placeholder) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
              decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade400),
                  borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                Icon(icon, size: 18, color: _navy),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          color: placeholder
                              ? Colors.grey.shade500
                              : Colors.black87)),
                ),
                Icon(Icons.arrow_drop_down, color: Colors.grey.shade600),
              ]),
            ),
          ),
        ],
      );
}
