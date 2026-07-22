import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:printing/printing.dart';
import '../../models/tile_design.dart';
import '../../models/brand.dart';
import '../../models/inquiry_order.dart';
import '../../services/supabase_data_service.dart';
import '../../models/choice_state.dart';
import '../../widgets/customer_picker.dart';
import '../../utils/dispatch_pdf.dart';

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// Build ONE loading list: the party's booked designs are pre-listed, and the
/// stockist just opens each design's batches and types the boxes to load — the
/// location rides along on each batch. Print it for the supervisor, then proceed
/// to dispatch once the truck is loaded. (docs/LOT_LAYER_PLAN.md · Loading List)
///
/// `extra`: `{id}` reopens a draft · `{inquiry_id}` starts from a booked order.
class LoadingListEditScreen extends StatefulWidget {
  final String? listId;
  final String? inquiryId;
  const LoadingListEditScreen({super.key, this.listId, this.inquiryId});
  @override
  State<LoadingListEditScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);
const _red = Color(0xFFC62828);
const _amber = Color(0xFFB26A00);
const _green = Color(0xFF2E7D32);

/// One design going on the truck, with the boxes chosen per batch (lot).
class _Block {
  final TileDesign d;
  final int? ordered; // estimate from the order; null = added extra
  final Map<String, int> qtyByLot = {}; // lot_id -> boxes
  _Block(this.d, {this.ordered});
  int get loaded => qtyByLot.values.fold(0, (s, v) => s + v);
}

class _State extends State<LoadingListEditScreen> {
  final _svc = SupabaseDataService();
  bool _loading = true;
  bool _saving = false;
  String? _listId;
  bool _dispatched = false;

  // Header.
  String? _custId;
  String _custName = '';
  InquiryOrder? _order;
  final _poCtrl = TextEditingController();
  final _truckCtrl = TextEditingController();
  final _transporterCtrl = TextEditingController();
  DateTime _date = DateTime.now();

  // Data.
  List<TileDesign> _all = [];
  List<Brand> _brands = [];
  Map<String, List<Map<String, dynamic>>> _stockLots = {};
  List<Map<String, dynamic>> _customers = [];
  List<InquiryOrder> _orders = [];
  final _blocks = <_Block>[];

  @override
  void initState() {
    super.initState();
    _listId = widget.listId;
    _load();
  }

  @override
  void dispose() {
    _poCtrl.dispose();
    _truckCtrl.dispose();
    _transporterCtrl.dispose();
    super.dispose();
  }

  TileDesign? _designById(String id) {
    for (final d in _all) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// The holding's brand — resolved from its brandId, since the design row's own
  /// brandName is blank (brand lives on the box, not the piece).
  String _brandName(String? id) {
    if (id == null || id.isEmpty) return '';
    for (final b in _brands) {
      if (b.id == id) return b.name;
    }
    return '';
  }

  /// Brand · size · quality · surface as the app's coloured chips — blue brand,
  /// amber Premium — so a stockist reads identity at a glance. (matches dispatch)
  List<Widget> _attrChips(TileDesign d) {
    final brand = _brandName(d.brandId);
    final surface = d.hasSurface ? d.surfaceCardLabel : '';
    return [
      if (brand.isNotEmpty)
        _chip(brand,
            bg: const Color(0xFFE3F2FD),
            fg: const Color(0xFF1565C0),
            icon: Icons.business_outlined),
      _chip(d.size.replaceAll(' mm', ''),
          bg: Colors.grey.shade100, fg: Colors.grey.shade700,
          icon: Icons.straighten),
      _qualityChip(d.quality),
      if (surface.isNotEmpty)
        _chip(surface, bg: Colors.grey.shade100, fg: Colors.grey.shade700),
    ];
  }

  static Widget _chip(String text,
      {required Color bg, required Color fg, IconData? icon}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: 10, color: fg),
            const SizedBox(width: 3),
          ],
          Text(text,
              style:
                  TextStyle(fontSize: 10, color: fg, fontWeight: FontWeight.w600)),
        ]),
      );

  static Widget _qualityChip(String q) {
    switch (q.toLowerCase()) {
      case 'premium':
        return _chip(q,
            bg: const Color(0xFFFFF8E1),
            fg: const Color(0xFFF9A825),
            icon: Icons.star_rounded);
      case 'both':
        return _chip(q,
            bg: const Color(0xFFE8F5E9),
            fg: const Color(0xFF2E7D32),
            icon: Icons.layers_outlined);
      default:
        return _chip(q,
            bg: const Color(0xFFE3F2FD),
            fg: const Color(0xFF1565C0),
            icon: Icons.verified_outlined);
    }
  }

  Future<void> _load() async {
    final all = await _svc.getDesignsByStockist(currentStockistUUID);
    final lots = await _svc.myStockLots();
    final customers = await _svc.listCustomers();
    final orders = await _svc.getMyInquiries();
    final brands = await _svc.getMyBrands();
    if (!mounted) return;
    _all = all;
    _brands = brands;
    _stockLots = lots;
    _customers = customers;
    _orders = orders.where((o) => !o.isCompleted && !o.isRejected).toList();

    if (_listId != null) {
      await _loadExisting(_listId!);
    } else if (widget.inquiryId != null) {
      final o = orders.where((x) => x.id == widget.inquiryId).firstOrNull;
      if (o != null) await _attachOrder(o, prefill: true);
    }
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _loadExisting(String id) async {
    final data = await _svc.loadingListGet(id);
    if (data == null) return;
    _dispatched = (data['status'] ?? '').toString() == 'dispatched';
    _custId = (data['customer_id'])?.toString();
    _poCtrl.text = (data['party_order_no'] ?? '').toString();
    _truckCtrl.text = (data['truck_no'] ?? '').toString();
    _transporterCtrl.text = (data['transporter'] ?? '').toString();
    final ds = (data['loading_date'] ?? '').toString();
    _date = DateTime.tryParse(ds) ?? DateTime.now();
    final inqId = (data['inquiry_id'])?.toString();
    if (inqId != null) {
      _order = _orders.where((o) => o.id == inqId).firstOrNull;
    }
    if (_custId != null) {
      final c = _customers.where((c) => (c['id']).toString() == _custId).firstOrNull;
      _custName = (c?['name'] ?? '').toString();
    }
    // Rebuild blocks from the saved items, grouping the per-batch lines by design.
    final items = (data['items'] as List?) ?? const [];
    // First seed ordered estimates from the attached order, if any.
    final ordered = <String, int>{};
    if (_order != null) {
      final detail = await _svc.getInquiryDetail(_order!.id);
      for (final raw in (detail?['lines'] as List?) ?? const []) {
        final m = Map<String, dynamic>.from(raw as Map);
        ordered[(m['design_id']).toString()] = (m['quantity'] as num?)?.toInt() ?? 0;
      }
    }
    for (final raw in items) {
      final m = Map<String, dynamic>.from(raw as Map);
      final did = (m['design_id']).toString();
      final d = _designById(did);
      if (d == null) continue;
      var b = _blocks.where((x) => x.d.id == did).firstOrNull;
      if (b == null) {
        b = _Block(d, ordered: ordered[did]);
        _blocks.add(b);
      }
      final lot = (m['lot_id'])?.toString();
      if (lot != null) b.qtyByLot[lot] = (m['boxes'] as num?)?.toInt() ?? 0;
    }
  }

  // ── Header pickers ───────────────────────────────────────────────────────────

  Future<void> _pickCustomer() async {
    final picked =
        await CustomerPicker.show(context, customers: _customers, svc: _svc);
    if (picked == null) return;
    setState(() {
      _custId = (picked['id']).toString();
      _custName = (picked['name'] ?? '').toString();
      if (!_customers.any((c) => (c['id']).toString() == _custId)) {
        _customers = [..._customers, picked];
      }
    });
  }

  Future<void> _pickOrder() async {
    if (_orders.isEmpty) {
      _snack('No open orders.', _red);
      return;
    }
    final chosen = await showModalBottomSheet<InquiryOrder>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.6,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              const Text('Attach a booked order',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              for (final o in _orders)
                ListTile(
                  leading: const Icon(Icons.receipt_long, color: _navy),
                  title: Text(o.token,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text([
                    if (o.company.isNotEmpty) o.company
                    else if (o.customerHint.isNotEmpty) o.customerHint,
                  ].join()),
                  onTap: () => Navigator.pop(ctx, o),
                ),
            ],
          ),
        ),
      ),
    );
    if (chosen != null) await _attachOrder(chosen, prefill: true);
  }

  Future<void> _attachOrder(InquiryOrder o, {bool prefill = false}) async {
    setState(() => _order = o);
    if (!prefill) return;
    final detail = await _svc.getInquiryDetail(o.id);
    if (!mounted) return;
    setState(() {
      for (final raw in (detail?['lines'] as List?) ?? const []) {
        final m = Map<String, dynamic>.from(raw as Map);
        final did = (m['design_id']).toString();
        if (_blocks.any((b) => b.d.id == did)) continue;
        final d = _designById(did);
        if (d == null) continue;
        _blocks.add(_Block(d, ordered: (m['quantity'] as num?)?.toInt()));
      }
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2024),
      lastDate: DateTime(2030),
    );
    if (picked != null) setState(() => _date = picked);
  }

  // ── Designs ──────────────────────────────────────────────────────────────────

  Future<void> _addDesign() async {
    final taken = _blocks.map((b) => b.d.id).toSet();
    final pool = _all
        .where((d) => d.boxQuantity > 0 && !taken.contains(d.id))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final chosen = await showModalBottomSheet<TileDesign>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        String q = '';
        return StatefulBuilder(builder: (ctx, setSheet) {
          final ql = q.trim().toLowerCase();
          final res = ql.isEmpty
              ? pool
              : pool.where((d) => d.name.toLowerCase().contains(ql)).toList();
          return SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.7,
            child: Column(children: [
              const SizedBox(height: 12),
              const Text('Add a design',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                      hintText: 'Search design',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder()),
                  onChanged: (v) => setSheet(() => q = v),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: res.length,
                  itemBuilder: (_, i) {
                    final d = res[i];
                    return ListTile(
                      title: Text(d.name,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text([
                        d.size.replaceAll(' mm', ''),
                        if (d.brandName.isNotEmpty) d.brandName,
                        d.quality,
                        '${d.boxQuantity} in stock',
                      ].join('  ·  ')),
                      onTap: () => Navigator.pop(ctx, d),
                    );
                  },
                ),
              ),
            ]),
          );
        });
      },
    );
    if (chosen != null) {
      setState(() => _blocks.insert(0, _Block(chosen)));
    }
  }

  /// The batch popup: every batch of this design with an empty box each — type
  /// the boxes to load, from as many batches as needed, in one go.
  Future<void> _setBatches(_Block b) async {
    final lots = _stockLots[b.d.id] ?? const [];
    if (lots.isEmpty) {
      _snack('No stock lots for this design.', _red);
      return;
    }
    final ctrls = {
      for (final l in lots)
        (l['lot_id']).toString(): TextEditingController(
            text: (b.qtyByLot[(l['lot_id']).toString()] ?? 0) == 0
                ? ''
                : '${b.qtyByLot[(l['lot_id']).toString()]}')
    };
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Batches — ${b.d.name}'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('Type boxes to load from each batch',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              ),
              const SizedBox(height: 8),
              for (final l in lots) _lotRow(l, ctrls[(l['lot_id']).toString()]!),
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
            child: const Text('Done'),
          ),
        ],
      ),
    );
    if (saved == true) {
      setState(() {
        b.qtyByLot.clear();
        for (final l in lots) {
          final id = (l['lot_id']).toString();
          final q = int.tryParse(ctrls[id]!.text.trim()) ?? 0;
          if (q > 0) b.qtyByLot[id] = q;
        }
      });
    }
    for (final c in ctrls.values) {
      c.dispose();
    }
  }

  Widget _lotRow(Map<String, dynamic> l, TextEditingController ctrl) {
    final batch = (l['batch'] ?? '').toString();
    final loc = (l['location'] ?? '').toString();
    final avail = (l['box_quantity'] as num?)?.toInt() ?? 0;
    final bits = <String>[];
    if (batch.isNotEmpty) bits.add('Batch $batch');
    if (loc.isNotEmpty) bits.add('📍 $loc');
    final label = bits.isEmpty ? 'No batch' : bits.join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              Text('$avail avail',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            ],
          ),
        ),
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

  // ── Save / print / dispatch ──────────────────────────────────────────────────

  List<Map<String, dynamic>> _items() {
    final out = <Map<String, dynamic>>[];
    for (final b in _blocks) {
      final lots = _stockLots[b.d.id] ?? const [];
      for (final e in b.qtyByLot.entries) {
        if (e.value <= 0) continue;
        final lot = lots.where((l) => (l['lot_id']).toString() == e.key).firstOrNull;
        out.add({
          'design_id': b.d.id,
          'lot_id': e.key,
          'batch': (lot?['batch'] ?? '').toString(),
          'location': (lot?['location'] ?? '').toString(),
          'boxes': e.value,
        });
      }
    }
    return out;
  }

  int get _totalBoxes => _blocks.fold(0, (s, b) => s + b.loaded);

  Future<String?> _save({bool silent = false}) async {
    final items = _items();
    if (items.isEmpty) {
      if (!silent) _snack('Add at least one design with boxes.', _red);
      return null;
    }
    setState(() => _saving = true);
    try {
      final id = await _svc.loadingListUpsert(
        id: _listId,
        customerId: _custId,
        inquiryId: _order?.id,
        partyOrderNo: _poCtrl.text.trim(),
        truck: _truckCtrl.text.trim(),
        transporter: _transporterCtrl.text.trim(),
        date: _date,
        note: '',
        items: items,
      );
      _listId = id;
      if (!silent && mounted) _snack('Loading list saved.', _green);
      return id;
    } catch (e) {
      if (mounted) _snack('$e', _red);
      return null;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _print() async {
    final lines = <DispatchPdfLine>[];
    for (final b in _blocks) {
      final lots = _stockLots[b.d.id] ?? const [];
      for (final e in b.qtyByLot.entries) {
        if (e.value <= 0) continue;
        final lot = lots.where((l) => (l['lot_id']).toString() == e.key).firstOrNull;
        lines.add(DispatchPdfLine(
          name: b.d.name,
          size: b.d.size,
          surface: b.d.hasSurface ? b.d.surfaceCardLabel : '',
          quality: b.d.quality,
          boxes: e.value,
          brand: _brandName(b.d.brandId),
          batch: (lot?['batch'] ?? '').toString(),
          location: (lot?['location'] ?? '').toString(),
        ));
      }
    }
    if (lines.isEmpty) {
      _snack('Nothing to print yet.', _red);
      return;
    }
    final who = _custName.isNotEmpty
        ? _custName
        : (_order != null ? 'Order ${_order!.token}' : '');
    final bytes = await buildDispatchPdf(DispatchPdfData(
      stockistName: '',
      who: who,
      dispatchNo: '',
      date: _fmtDate(_date),
      invoice: _poCtrl.text.trim().isEmpty ? '' : 'PO ${_poCtrl.text.trim()}',
      vehicle: _truckCtrl.text.trim(),
      transporter: _transporterCtrl.text.trim(),
      note: '',
      lines: lines,
      total: _totalBoxes,
      balanceLine: '',
      title: 'LOADING LIST',
      totalLabel: 'Total to load',
    ));
    await Printing.layoutPdf(onLayout: (_) async => Uint8List.fromList(bytes));
  }

  Future<void> _proceed() async {
    final id = await _save(silent: true);
    if (id == null) {
      _snack('Add designs and boxes before dispatch.', _red);
      return;
    }
    if (!mounted) return;
    // Hand the list to the dispatch screen; it records from these exact lots and
    // marks the list dispatched. (LL3)
    final changed = await context.push<bool>('/stockist/dispatch/manual',
        extra: {'loading_list_id': id, 'id': _order?.id});
    if (changed == true && mounted) Navigator.pop(context, true);
  }

  void _snack(String m, [Color c = _navy]) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m), backgroundColor: c));

  static const _months = [
    'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'
  ];
  String _fmtDate(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        title: Text(_listId == null ? 'New Loading List' : 'Loading List'),
      ),
      bottomNavigationBar: _dispatched ? null : _bottomBar(),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
              children: [
                _header(),
                const SizedBox(height: 14),
                _designsCard(),
              ],
            ),
    );
  }

  Widget _bottomBar() => Container(
        color: Colors.white,
        padding: EdgeInsets.fromLTRB(
            14, 10, 14, 10 + MediaQuery.viewPaddingOf(context).bottom),
        child: Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _saving ? null : () => _save(),
              icon: const Icon(Icons.save_outlined, size: 18),
              label: const Text('Save'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: _navy,
                  padding: const EdgeInsets.symmetric(vertical: 13)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _saving ? null : _print,
              icon: const Icon(Icons.print_outlined, size: 18),
              label: const Text('Print'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: _navy,
                  padding: const EdgeInsets.symmetric(vertical: 13)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: ElevatedButton.icon(
              onPressed: _saving ? null : _proceed,
              icon: const Icon(Icons.local_shipping_outlined, size: 18),
              label: const Text('Proceed to dispatch'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: _red,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13)),
            ),
          ),
        ]),
      );

  Widget _header() => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Who & which truck',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 10),
              _selectRow(Icons.person_outline, 'Party (customer)',
                  _custName.isEmpty ? 'Select customer' : _custName,
                  _custName.isEmpty, _pickCustomer),
              const SizedBox(height: 8),
              _selectRow(Icons.receipt_long, 'Booked order',
                  _order == null ? 'Attach an order (optional)' : _order!.token,
                  _order == null, _pickOrder),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: _text(_poCtrl, 'Party order no')),
                const SizedBox(width: 8),
                Expanded(child: _text(_truckCtrl, 'Truck number')),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: _text(_transporterCtrl, 'Transporter')),
                const SizedBox(width: 8),
                Expanded(
                  child: InkWell(
                    onTap: _pickDate,
                    child: InputDecorator(
                      decoration: const InputDecoration(
                          labelText: 'Loading date',
                          isDense: true,
                          border: OutlineInputBorder()),
                      child: Text(_fmtDate(_date)),
                    ),
                  ),
                ),
              ]),
            ],
          ),
        ),
      );

  Widget _text(TextEditingController c, String label) => TextField(
        controller: c,
        decoration: InputDecoration(
            labelText: label, isDense: true, border: const OutlineInputBorder()),
      );

  Widget _selectRow(IconData icon, String label, String value, bool placeholder,
          VoidCallback onTap) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade400),
              borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            Icon(icon, size: 18, color: _navy),
            const SizedBox(width: 10),
            Expanded(
              child: Text(value,
                  style: TextStyle(
                      fontSize: 14,
                      color: placeholder ? Colors.grey.shade500 : Colors.black87,
                      fontWeight:
                          placeholder ? FontWeight.normal : FontWeight.w600)),
            ),
            Icon(Icons.arrow_drop_down, color: Colors.grey.shade600),
          ]),
        ),
      );

  Widget _designsCard() => Card(
        margin: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Text('Designs to load — open batches, type boxes',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            ),
            if (_blocks.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Text(
                    _order == null
                        ? 'Attach an order to pull its designs, or add designs below.'
                        : 'This order has no designs.',
                    style: TextStyle(color: Colors.grey.shade500)),
              )
            else
              for (var i = 0; i < _blocks.length; i++) _blockRow(i),
            Padding(
              padding: const EdgeInsets.all(10),
              child: OutlinedButton.icon(
                onPressed: _addDesign,
                icon: const Icon(Icons.add, size: 18),
                label: const Text("Add a design that isn't on the order"),
                style: OutlinedButton.styleFrom(
                    foregroundColor: _navy,
                    side: BorderSide(color: Colors.grey.shade400)),
              ),
            ),
          ],
        ),
      );

  Widget _blockRow(int i) {
    final b = _blocks[i];
    final est = b.ordered;
    final loaded = b.loaded;
    final over = est != null && loaded > est;
    final under = est != null && loaded > 0 && loaded < est;
    return Container(
      decoration: BoxDecoration(
          border: Border(top: BorderSide(color: Colors.grey.shade200))),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text('${b.d.name} · ${b.d.size.replaceAll(' mm', '')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 14)),
            ),
            IconButton(
              tooltip: 'Remove',
              icon: Icon(Icons.close, size: 18, color: Colors.grey.shade500),
              onPressed: () => setState(() => _blocks.removeAt(i)),
            ),
          ]),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Wrap(
                    spacing: 5,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: _attrChips(b.d)),
              ),
              const SizedBox(width: 8),
              // Numbers, then the batch control right beside them.
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (est != null)
                    Text('est. $est',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade600)),
                  Text(loaded == 0 ? 'not set' : 'loaded $loaded',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: loaded == 0
                              ? Colors.grey.shade500
                              : (over || under) ? _amber : _green)),
                ],
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => _setBatches(b),
                icon: const Icon(Icons.inventory_2_outlined, size: 16),
                label: Text(b.qtyByLot.isEmpty ? 'Set batches' : 'Edit batches'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: _navy,
                    side: BorderSide(color: _navy.withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    visualDensity: VisualDensity.compact),
              ),
            ],
          ),
          // The loaded batch lines.
          if (b.qtyByLot.isNotEmpty) const SizedBox(height: 8),
          for (final e in b.qtyByLot.entries)
            if (e.value > 0) _loadedLine(b, e.key, e.value),
        ],
      ),
    );
  }

  Widget _loadedLine(_Block b, String lotId, int qty) {
    final lots = _stockLots[b.d.id] ?? const [];
    final lot = lots.where((l) => (l['lot_id']).toString() == lotId).firstOrNull;
    final batch = (lot?['batch'] ?? '').toString();
    final loc = (lot?['location'] ?? '').toString();
    final label = [
      if (batch.isNotEmpty) 'Batch $batch',
      if (loc.isNotEmpty) '📍 $loc',
    ].join('  ·  ');
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Row(children: [
        Expanded(
          child: Text(label.isEmpty ? 'No batch' : label,
              style: const TextStyle(fontSize: 12.5)),
        ),
        Text('$qty',
            style: const TextStyle(
                fontWeight: FontWeight.w800, color: _red, fontSize: 13)),
      ]),
    );
  }
}
