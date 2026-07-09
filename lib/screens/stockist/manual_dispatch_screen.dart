import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/tile_design.dart';
import '../../models/brand.dart';
import '../../models/choice_state.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../utils/india_geo.dart';
import '../../widgets/save_bar.dart';

/// Order-less ("manual"/walk-in) dispatch, in the same batch shape as Add Stock:
/// pick designs → set boxes → Add to a running list, fill dispatch details +
/// customer, then Record. No order/remaining tracking (that's the order-linked
/// dispatch). Over-dispatch is allowed — dispatch is the final truth.
/// Customer is a plain optional name UNLESS the admin turned on "My Customers"
/// (customers_enabled), in which case it's a save-and-reuse picker.
/// (project_unified_dispatch_customers)
class ManualDispatchScreen extends StatefulWidget {
  const ManualDispatchScreen({super.key});
  @override
  State<ManualDispatchScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);
const _red = Color(0xFFC62828);

class _Line {
  final TileDesign d;
  int qty;
  _Line(this.d, this.qty);
}

class _State extends State<ManualDispatchScreen> {
  final _svc = SupabaseDataService();
  bool _loading = true;
  bool _saving = false;

  List<TileDesign> _designs = [];
  List<Brand> _brands = [];
  bool _customersEnabled = false;
  List<Map<String, dynamic>> _customers = [];

  // Entry being built.
  TileDesign? _sel;
  final _qtyCtrl = TextEditingController();

  final _lines = <_Line>[];

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
    if (!mounted) return;
    setState(() {
      _designs = all.where((d) => d.boxQuantity > 0).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      _brands = brands;
      _customersEnabled = enabled;
      _customers = customers;
      _loading = false;
    });
  }

  int get _totalBoxes => _lines.fold(0, (s, l) => s + l.qty);

  String _brandName(String? id) {
    if (id == null) return '';
    final m = _brands.where((b) => b.id == id).toList();
    return m.isEmpty ? '' : m.first.name;
  }

  /// The glaze this holding was made on, or '' when it has none. No brand-mode
  /// lookup needed: every holding stores the surface it was stocked with —
  /// attribute picks it per run; in_name inherits the design's saved surface
  /// (the map-once value). 'None' shows nothing. (project_per_brand_surface_mode)
  String _surfaceOf(TileDesign d) => d.displaySurface;

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

  Future<void> _pickDesign() async {
    final chosen = await showModalBottomSheet<TileDesign>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        String q = '';
        return StatefulBuilder(builder: (ctx, setSheet) {
          final ql = q.trim().toLowerCase();
          final res = _designs.where((d) {
            if (ql.isEmpty) return true;
            return d.name.toLowerCase().contains(ql) ||
                _brandName(d.brandId).toLowerCase().contains(ql) ||
                d.size.toLowerCase().contains(ql) ||
                _surfaceOf(d).toLowerCase().contains(ql);
          }).toList();
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.75,
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  const Text('Select design',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                    child: TextField(
                      autofocus: true,
                      onChanged: (v) => setSheet(() => q = v),
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: const Icon(Icons.search),
                        hintText: 'Search design, size, brand…',
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  Expanded(
                    child: res.isEmpty
                        ? const Center(child: Text('No in-stock designs match.'))
                        : ListView.separated(
                            itemCount: res.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final d = res[i];
                              final img = d.faceImageUrls.isNotEmpty
                                  ? d.faceImageUrls.first
                                  : '';
                              return ListTile(
                                leading: ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: img.isEmpty
                                      ? Container(
                                          width: 44,
                                          height: 44,
                                          color: Colors.grey.shade100,
                                          child: const Icon(
                                              Icons.image_not_supported,
                                              size: 18,
                                              color: Colors.grey))
                                      : CachedNetworkImage(
                                          imageUrl: CloudinaryService.thumbUrl(
                                              img,
                                              width: 120),
                                          width: 44,
                                          height: 44,
                                          fit: BoxFit.cover,
                                          placeholder: (_, __) => Container(
                                              color: Colors.grey.shade200),
                                          errorWidget: (_, __, ___) => Container(
                                              color: Colors.grey.shade200)),
                                ),
                                title: Text(d.name),
                                subtitle: Text(_holdingLabel(d)),
                                trailing: Text('${d.boxQuantity} in stock',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade600)),
                                onTap: () => Navigator.pop(ctx, d),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        });
      },
    );
    if (chosen != null) setState(() => _sel = chosen);
  }

  void _resetRow() {
    _sel = null;
    _qtyCtrl.clear();
  }

  void _addLine() {
    if (_sel == null) {
      _snack('Pick a design first.', _red);
      return;
    }
    final qty = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
    if (qty <= 0) {
      _snack('Enter a quantity.', _red);
      return;
    }
    final idx = _lines.indexWhere((l) => l.d.id == _sel!.id);
    if (idx >= 0) {
      _resolveDuplicate(idx, qty);
      return;
    }
    setState(() {
      _lines.add(_Line(_sel!, qty));
      _resetRow();
    });
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
            Text('${l.d.name} · ${_holdingLabel(l.d)}',
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

  // ── Customer (opt-in) ────────────────────────────────────────────────────────

  Future<void> _pickCustomer() async {
    final action = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        String q = '';
        return StatefulBuilder(builder: (ctx, setSheet) {
          final ql = q.trim().toLowerCase();
          final res = _customers
              .where((c) => (c['name'] ?? '').toString().toLowerCase().contains(ql))
              .toList();
          return SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.7,
            child: Column(
              children: [
                const SizedBox(height: 12),
                const Text('Customer',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                  child: TextField(
                    onChanged: (v) => setSheet(() => q = v),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search saved customers…',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                ListTile(
                  leading: const CircleAvatar(
                      backgroundColor: Color(0xFF2E7D32),
                      child: Icon(Icons.person_add_alt, color: Colors.white)),
                  title: const Text('New customer'),
                  subtitle: const Text('Save name + location for next time'),
                  onTap: () => Navigator.pop(ctx, {'_new': true}),
                ),
                const Divider(height: 1),
                Expanded(
                  child: res.isEmpty
                      ? const Center(child: Text('No saved customers yet.'))
                      : ListView(
                          children: [
                            for (final c in res)
                              ListTile(
                                leading: const Icon(Icons.person_outline),
                                title: Text((c['name'] ?? '').toString()),
                                subtitle: Text([
                                  (c['city'] ?? '').toString(),
                                  (c['district'] ?? '').toString(),
                                ].where((x) => x.isNotEmpty).join(', ')),
                                trailing: (c['phone'] ?? '').toString().isNotEmpty
                                    ? const Icon(Icons.call, size: 16)
                                    : null,
                                onTap: () => Navigator.pop(ctx, c),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          );
        });
      },
    );
    if (action == null) return;
    if (action['_new'] == true) {
      await _newCustomerForm();
    } else {
      setState(() {
        _custId = (action['id'] ?? '').toString();
        _custNameCtrl.text = (action['name'] ?? '').toString();
      });
    }
  }

  Future<void> _newCustomerForm() async {
    final nameCtl = TextEditingController();
    final phoneCtl = TextEditingController();
    final pinCtl = TextEditingController();
    final cityCtl = TextEditingController();
    String state = '';
    String district = '';
    bool looking = false;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        Future<void> lookup() async {
          final pin = pinCtl.text.trim();
          if (pin.length != 6) return;
          setSheet(() => looking = true);
          final r = await IndiaGeo.lookupPincode(pin);
          setSheet(() {
            looking = false;
            if (r != null) {
              state = r.state;
              district = r.district;
              if (cityCtl.text.trim().isEmpty) cityCtl.text = r.city;
            }
          });
        }

        InputDecoration dec(String l) => InputDecoration(
            labelText: l,
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)));
        return Padding(
          padding: EdgeInsets.fromLTRB(
              16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('New customer',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 12),
              TextField(controller: nameCtl, decoration: dec('Name *')),
              const SizedBox(height: 10),
              TextField(
                  controller: phoneCtl,
                  keyboardType: TextInputType.phone,
                  decoration: dec('Phone (optional)')),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: TextField(
                      controller: pinCtl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(6),
                      ],
                      decoration: dec('Pincode')),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: looking ? null : lookup,
                  child: looking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Find'),
                ),
              ]),
              if (state.isNotEmpty || district.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('$district, $state',
                      style: TextStyle(
                          fontSize: 12.5, color: Colors.grey.shade700)),
                ),
              const SizedBox(height: 10),
              TextField(controller: cityCtl, decoration: dec('City')),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      if (nameCtl.text.trim().isEmpty) return;
                      try {
                        final id = await _svc.upsertCustomer(
                          name: nameCtl.text.trim(),
                          phone: phoneCtl.text.trim().isEmpty
                              ? null
                              : phoneCtl.text.trim(),
                          state: state.isEmpty ? null : state,
                          district: district.isEmpty ? null : district,
                          pincode: pinCtl.text.trim().isEmpty
                              ? null
                              : pinCtl.text.trim(),
                          city: cityCtl.text.trim().isEmpty
                              ? null
                              : cityCtl.text.trim(),
                        );
                        if (!ctx.mounted) return;
                        if (id != null) {
                          _custId = id;
                          _custNameCtrl.text = nameCtl.text.trim();
                        }
                        Navigator.pop(ctx, true);
                      } catch (e) {
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(content: Text('$e'), backgroundColor: _red));
                        }
                      }
                    },
                    style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2E7D32),
                        foregroundColor: Colors.white),
                    child: const Text('Save'),
                  ),
                ),
              ]),
            ],
          ),
        );
      }),
    );
    if (saved == true) {
      await _load(); // refresh customer list
      setState(() {});
    }
  }

  // ── Record ───────────────────────────────────────────────────────────────────

  Future<void> _record() async {
    if (_lines.isEmpty) {
      _snack('Add at least one design.', _red);
      return;
    }
    final over = _lines.where((l) => l.qty > l.d.boxQuantity).toList();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  'Dispatch ${_lines.length} design${_lines.length == 1 ? '' : 's'} · '
                  '$_totalBoxes boxes'
                  '${_custNameCtrl.text.trim().isNotEmpty ? ' to ${_custNameCtrl.text.trim()}' : ''}?',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
              if (over.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                    '${over.length} line${over.length == 1 ? '' : 's'} exceed current stock — '
                    'allowed (stock will floor at 0).',
                    style: TextStyle(fontSize: 12, color: Colors.orange.shade800)),
              ],
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Back'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: _red, foregroundColor: Colors.white),
                    child: const Text('Record Dispatch'),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;

    setState(() => _saving = true);
    try {
      final lines = _lines
          .map((l) => {'design_id': l.d.id, 'dispatch': l.qty})
          .toList();
      final res = await _svc.dispatchWalkin(
        lines,
        customerId: _customersEnabled ? _custId : null,
        customerName: _custNameCtrl.text.trim(),
        invoice: _invoiceCtrl.text.trim(),
        vehicle: _vehicleCtrl.text.trim(),
        transporter: _transporterCtrl.text.trim(),
        note: _noteCtrl.text.trim(),
        date: _date,
      );
      if (!mounted) return;
      final no = (res['dispatch_no'] ?? '').toString();
      _snack('Dispatch recorded${no.isNotEmpty ? ' ($no)' : ''} · $_totalBoxes boxes.');
      if (Navigator.of(context).canPop()) {
        Navigator.pop(context, true);
      } else {
        setState(() {
          _lines.clear();
          _saving = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('$e', _red);
    }
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
      bottomNavigationBar: SaveBar(
        label: _lines.isEmpty
            ? 'Record Dispatch'
            : 'Record Dispatch ($_totalBoxes boxes)',
        icon: Icons.local_shipping_outlined,
        color: _red,
        onPressed: _record,
        saving: _saving,
        dirty: _lines.isNotEmpty,
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
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Customer & dispatch details',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 10),
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
          ],
        ),
      ),
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
              child: Text('${_lines.length} to dispatch · $_totalBoxes boxes',
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

  Widget _lineTile(int i) {
    final l = _lines[i];
    final over = l.qty > l.d.boxQuantity;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.d.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 2),
                Text(
                    '${_holdingLabel(l.d)} · ${l.d.boxQuantity} stock'
                    '${over ? ' · over!' : ''}',
                    style: TextStyle(
                        fontSize: 11.5,
                        color: over ? _red : Colors.grey.shade600)),
              ],
            ),
          ),
          InkWell(
            onTap: () => _editQty(l),
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                  color: _red.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(6)),
              child: Text('${l.qty}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15, color: _red)),
            ),
          ),
          IconButton(
            icon: Icon(Icons.delete_outline, size: 20, color: Colors.red.shade400),
            onPressed: () => setState(() => _lines.removeAt(i)),
          ),
        ]),
      ),
    );
  }

  // ── Desktop layout ───────────────────────────────────────────────────────────

  Widget _desktopBody() => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: _detailsCard(),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: _hField(
                          'Design',
                          _hSelect(
                              _sel == null
                                  ? 'Search & select design'
                                  : '${_sel!.name}  ·  ${_holdingLabel(_sel!)}  ·  ${_sel!.boxQuantity} stock',
                              _pickDesign,
                              _sel == null)),
                    ),
                    const SizedBox(width: 12),
                    _hField('Qty (boxes)', _qtyField(), width: 120),
                    const SizedBox(width: 12),
                    SizedBox(
                      height: 44,
                      child: ElevatedButton.icon(
                        onPressed: _addLine,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add'),
                        style: ElevatedButton.styleFrom(
                            backgroundColor: _navy,
                            foregroundColor: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: _desktopTable(),
            ),
          ),
        ],
      );

  Widget _desktopTable() => Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Container(
              color: const Color(0xFFF3F5F8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: _row('DESIGN', 'DETAILS', 'STOCK', 'QTY', header: true),
            ),
            const Divider(height: 1),
            Expanded(
              child: _lines.isEmpty
                  ? Center(
                      child: Text('No designs added — pick one above and Add.',
                          style: TextStyle(color: Colors.grey.shade500)))
                  : ListView.separated(
                      itemCount: _lines.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final l = _lines[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          child: _row(l.d.name, _holdingLabel(l.d),
                              '${l.d.boxQuantity}', '${l.qty}',
                              over: l.qty > l.d.boxQuantity,
                              onQty: () => _editQty(l),
                              onRemove: () =>
                                  setState(() => _lines.removeAt(i))),
                        );
                      },
                    ),
            ),
          ],
        ),
      );

  Widget _row(String design, String details, String stock, String qty,
      {bool header = false, bool over = false, VoidCallback? onQty, VoidCallback? onRemove}) {
    final lab = TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: Colors.grey.shade600,
        letterSpacing: 0.4);
    const cell = TextStyle(fontSize: 13);
    return Row(children: [
      Expanded(
          flex: 3,
          child: Text(design,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: header ? lab : cell.copyWith(fontWeight: FontWeight.w600))),
      Expanded(
          flex: 3,
          child: Text(details,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: header ? lab : cell.copyWith(color: Colors.grey.shade700))),
      SizedBox(
          width: 70,
          child: Text(stock,
              style: header
                  ? lab
                  : cell.copyWith(color: over ? _red : Colors.grey.shade700))),
      SizedBox(
        width: 90,
        child: header
            ? Text(qty, style: lab, textAlign: TextAlign.right)
            : Align(
                alignment: Alignment.centerRight,
                child: InkWell(
                  onTap: onQty,
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                        color: _red.withValues(alpha: 0.07),
                        borderRadius: BorderRadius.circular(6)),
                    child: Text(qty,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: _red)),
                  ),
                ),
              ),
      ),
      SizedBox(
        width: 40,
        child: header
            ? const SizedBox()
            : IconButton(
                icon: Icon(Icons.delete_outline,
                    size: 20, color: Colors.red.shade400),
                onPressed: onRemove,
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

  Widget _hField(String label, Widget child, {double? width}) {
    final col = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade600)),
        const SizedBox(height: 5),
        child,
      ],
    );
    return width == null ? col : SizedBox(width: width, child: col);
  }

  Widget _hSelect(String value, VoidCallback onTap, bool placeholder) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade400),
              borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            Expanded(
              child: Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      color:
                          placeholder ? Colors.grey.shade500 : Colors.black87)),
            ),
            Icon(Icons.arrow_drop_down, color: Colors.grey.shade600),
          ]),
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
