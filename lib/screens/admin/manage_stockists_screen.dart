import 'package:flutter/material.dart';
import '../../models/stockist.dart';
import '../../models/choice_state.dart';
import '../../services/supabase_data_service.dart';
import '../../widgets/phone_field.dart';
import '../../utils/stockist_tiers.dart';
import '../../utils/business_types.dart';
import 'excel_import_screen.dart';
import 'stockist_brand_lists_screen.dart';

// Admin screen to view existing stockists and add a single new one. The
// sequential ID (A01, A02, … B01) is generated automatically by the backend —
// there is no ID field on the form.
class ManageStockistsScreen extends StatefulWidget {
  const ManageStockistsScreen({super.key});
  @override
  State<ManageStockistsScreen> createState() => _ManageStockistsScreenState();
}

class _ManageStockistsScreenState extends State<ManageStockistsScreen> {
  final _dataSvc = SupabaseDataService();

  List<Stockist> _stockists = [];
  bool _loading = true;
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // Search + listing order (tier → priority → name), so this screen also shows
  // the buyer-facing order (Listing Order is merged in here).
  List<Stockist> get _filtered {
    var list = _stockists;
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      list = list
          .where((s) =>
              s.name.toLowerCase().contains(q) ||
              s.id.toLowerCase().contains(q) ||
              s.email.toLowerCase().contains(q) ||
              s.city.toLowerCase().contains(q) ||
              s.phone.contains(q))
          .toList();
    }
    list = [...list]..sort((a, b) {
        final t = stockistTierRank(b.stockistType)
            .compareTo(stockistTierRank(a.stockistType));
        if (t != 0) return t;
        final p = b.priority.compareTo(a.priority);
        if (p != 0) return p;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return list;
  }

  Future<void> _openEditForm(Stockist s) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _AddStockistSheet(existing: s),
    );
    if (saved == true) _load();
  }

  Future<void> _confirmDelete(Stockist s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete stockist?'),
        content: Text(
            'Permanently delete ${s.name} (${s.id})?\n\nThis removes their login '
            'and ALL their designs & stock. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child:
                  const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _dataSvc.deleteStockist(s.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${s.name} deleted.'), backgroundColor: Colors.red));
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$e'.replaceAll('PostgrestException:', '').trim()),
          backgroundColor: Colors.red));
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await _dataSvc.getAllStockists(activeOnly: false);
    if (!mounted) return;
    setState(() {
      _stockists = list;
      _loading = false;
    });
  }

  Future<void> _toggleActive(Stockist s, bool active) async {
    final ok = await _dataSvc.setStockistActive(s.id, active);
    if (!mounted) return;
    if (ok) {
      _load();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update status.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Stockists'),
        actions: [
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: 'Import from Excel',
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const ExcelImportScreen(role: 'stockist')));
              _load();
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openAddForm,
        backgroundColor: const Color(0xFF1B4F72),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add Stockist'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      hintText: 'Search name, ID, city, phone…',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      isDense: true,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _query = '');
                              }),
                    ),
                  ),
                ),
                Expanded(
                  child: _filtered.isEmpty
                      ? Center(
                          child: Text(
                              _stockists.isEmpty
                                  ? 'No stockists yet. Tap "Add Stockist".'
                                  : 'No matches.',
                              style: const TextStyle(color: Colors.grey)))
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            padding:
                                const EdgeInsets.fromLTRB(12, 8, 12, 90),
                            itemCount: _filtered.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 6),
                            itemBuilder: (_, i) => _stockistTile(_filtered[i]),
                          ),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _stockistTile(Stockist s) => InkWell(
        onTap: () => _openEditForm(s),
        borderRadius: BorderRadius.circular(8),
        child: Opacity(
        opacity: s.isActive ? 1 : 0.55,
        child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: const Color(0xFF1B4F72).withValues(alpha: 0.1),
              child: Text(s.id,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1B4F72))),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(s.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 14),
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (s.stockistType.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFB8860B).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(s.stockistType,
                              style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF8A6D00))),
                        ),
                      ],
                      // Importers (T/W) are flagged; Manufacturer is the default
                      // and left unbadged to avoid clutter.
                      if (s.isImporter) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1B4F72)
                                .withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(businessTypeLabel(s.businessType),
                              style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1B4F72))),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (s.city.isNotEmpty) s.city,
                      if (s.phone.isNotEmpty) s.phone,
                    ].join('  ·  '),
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    overflow: TextOverflow.ellipsis,
                  ),
                  // Login email (the actual login ID — the A01-style code is just
                  // a display id). Shown so admin can tie an ID to a real person.
                  if (s.email.isNotEmpty) ...[
                    const SizedBox(height: 1),
                    Row(
                      children: [
                        Icon(Icons.alternate_email,
                            size: 12, color: Colors.grey.shade500),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(
                            s.email,
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 5),
                  // At-a-glance toggle states + active device count.
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      // Public market + anonymity are hidden until the super
                      // admin flips the go-live switch (private-first runway).
                      if (publicMarketLive) _dot('Market', s.isListed),
                      if (publicMarketLive) _dot('Private', s.canCreatePrivateCatalog),
                      _deviceChip(s.deviceCount, s.deviceLimit),
                      if (s.brandLimit > 1 || s.brandCount > 1)
                        _brandChip(s.brandCount, s.brandLimit),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('Priority ${s.priority.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 10, color: Colors.grey)),
                Switch(
                  value: s.isActive,
                  onChanged: (v) => _toggleActive(s, v),
                  activeThumbColor: const Color(0xFF2E7D32),
                ),
                // Delete is only offered once the stockist is deactivated.
                if (!s.isActive)
                  InkWell(
                    onTap: () => _confirmDelete(s),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.delete_outline,
                              size: 16, color: Colors.red),
                          SizedBox(width: 2),
                          Text('Delete',
                              style:
                                  TextStyle(fontSize: 11, color: Colors.red)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      ),
    );

  // A small on/off status dot + label (● green = on, ○ grey = off).
  Widget _dot(String label, bool on) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(on ? Icons.circle : Icons.circle_outlined,
              size: 9,
              color: on ? const Color(0xFF2E7D32) : Colors.grey.shade400),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: on ? const Color(0xFF2E7D32) : Colors.grey.shade500)),
        ],
      );

  // Active devices / allowed limit (0 limit = unlimited → ∞).
  Widget _deviceChip(int count, int limit) {
    final lim = limit == 0 ? '∞' : '$limit';
    final over = limit > 0 && count > limit;
    final color = over
        ? Colors.red
        : (count > 0 ? const Color(0xFF1565C0) : Colors.grey.shade500);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.devices, size: 11, color: color),
        const SizedBox(width: 4),
        Text('$count/$lim',
            style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w600, color: color)),
      ],
    );
  }

  // Brands created / allowed (shown only for multi-brand stockists).
  Widget _brandChip(int count, int limit) {
    const color = Color(0xFF6A1B9A);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.sell_outlined, size: 11, color: color),
        const SizedBox(width: 4),
        Text('$count/$limit brands',
            style: const TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w600, color: color)),
      ],
    );
  }

  Future<void> _openAddForm() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => const _AddStockistSheet(),
    );
    if (created == true) _load();
  }
}

// ── Add / edit-stockist bottom sheet ─────────────────────────────────────────
class _AddStockistSheet extends StatefulWidget {
  /// When non-null the sheet edits this stockist instead of creating one.
  final Stockist? existing;
  const _AddStockistSheet({this.existing});
  @override
  State<_AddStockistSheet> createState() => _AddStockistSheetState();
}

class _AddStockistSheetState extends State<_AddStockistSheet> {
  final _dataSvc = SupabaseDataService();
  final _formKey = GlobalKey<FormState>();

  final _name     = TextEditingController();
  final _email    = TextEditingController();
  final _password = TextEditingController();
  final _phone    = TextEditingController();
  final _code     = TextEditingController(text: '+91');
  final _city     = TextEditingController();
  final _state    = TextEditingController();
  final _address  = TextEditingController();
  final _priority = TextEditingController(text: '0.00');
  final _gst      = TextEditingController();
  String _tier = ''; // '' = no tier; else Platinum/Gold/Silver
  String _businessType = 'M'; // M = Manufacturer/Author, T/W = importer
  bool _listed = true; // shown in the public market (false = link-only)
  bool _canPrivate = false; // may create private (Most Exclusive) catalogs
  bool _tdShow = false; // show the TilesDesign mark on this stockist's banners
  bool _customersEnabled = false; // may save customers on dispatch (opt-in)
  String _surfaceMode = 'in_name'; // M only: company-wide surface convention
  final _deviceLimit = TextEditingController(text: '1'); // concurrent devices
  int _deviceCount = 0; // devices currently registered for this user
  // Per-stockist cap on brand-free stock lists (v2 — lists are no longer under a
  // brand). Admin-set; default 3.
  final _stockLists = TextEditingController(text: '3');

  // Catalogue accent + location shown on the share-link page. Logo/banner/
  // tagline editing was retired — the share-link banner is now fully admin-
  // controlled via the Catalog Banners screen (project_admin_banner_system).
  String _brandColor = ''; // hex like #1B4F72 ('' = default theme colour)
  final _mapUrl = TextEditingController();

  // Preset brand-colour swatches (admin picks one; '' clears to the default).
  static const _brandSwatches = <String>[
    '#1B4F72', '#2E7D32', '#B71C1C', '#6A1B9A',
    '#E65100', '#00695C', '#37474F', '#AD1457',
  ];

  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final s = widget.existing;
    if (s != null) {
      _name.text     = s.name;
      _phone.text    = s.phone;
      _code.text     = s.countryCode.isEmpty ? '+91' : s.countryCode;
      _city.text     = s.city;
      _state.text    = s.state;
      _address.text  = s.address;
      _gst.text      = s.gstNumber;
      _priority.text = s.priority.toStringAsFixed(2);
      _tier = kStockistTiers.contains(s.stockistType) ? s.stockistType : '';
      _businessType =
          kBusinessTypes.contains(s.businessType) ? s.businessType : 'M';
      _listed = s.isListed;
      _canPrivate = s.canCreatePrivateCatalog;
      _tdShow = s.tdShow;
      _customersEnabled = s.customersEnabled;
      _surfaceMode = s.surfaceMode;
      _deviceLimit.text = '${s.deviceLimit}';
      _stockLists.text = '${s.stockListLimit}';
      _brandColor = s.brandColor;
      _mapUrl.text = s.mapUrl;
      _loadDeviceCount();
    }
  }

  Future<void> _loadDeviceCount() async {
    final n = await _dataSvc.userDeviceCount('stockist', widget.existing!.id);
    if (mounted) setState(() => _deviceCount = n);
  }

  @override
  void dispose() {
    for (final c in [
      _name, _email, _password, _phone, _code, _city, _state, _address,
      _priority, _gst, _deviceLimit, _stockLists,
      _mapUrl
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _clearDevices() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear registered devices?'),
        content: const Text(
            'This logs the stockist out of all their devices on next app open '
            'and frees every slot, so they can sign in fresh. Use this when '
            'they changed/reinstalled their phone and are locked out.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true) return;
    final n = await _dataSvc.clearUserDevices('stockist', widget.existing!.id);
    if (!mounted) return;
    setState(() => _deviceCount = 0);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Cleared $n device${n == 1 ? '' : 's'}.'),
      backgroundColor: const Color(0xFF2E7D32),
    ));
  }

  Widget _deviceSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 24),
        const Text('Device Limit',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 2),
        Text(
            'How many devices this login can be active on at once. 0 = unlimited. '
            'Currently $_deviceCount registered.',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        const SizedBox(height: 8),
        Row(
          children: [
            SizedBox(
              width: 90,
              child: TextFormField(
                controller: _deviceLimit,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Devices',
                    isDense: true,
                    border: OutlineInputBorder()),
                validator: (v) {
                  final t = (v ?? '').trim();
                  if (t.isEmpty) return null;
                  final n = int.tryParse(t);
                  if (n == null || n < 0) return 'Invalid';
                  return null;
                },
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _deviceCount == 0 ? null : _clearDevices,
              icon: const Icon(Icons.phonelink_erase, size: 16),
              label: Text('Clear devices ($_deviceCount)'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // Per-stockist cap on stock lists (v2: lists are brand-free now).
        const Text('Stock Lists',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 2),
        Text('How many stock lists this stockist can create in total.',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        const SizedBox(height: 8),
        SizedBox(
          width: 90,
          child: TextFormField(
            controller: _stockLists,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
                labelText: 'Lists', isDense: true, border: OutlineInputBorder()),
            validator: (v) {
              final t = (v ?? '').trim();
              if (t.isEmpty) return null;
              final n = int.tryParse(t);
              if (n == null || n < 1) return 'Invalid';
              return null;
            },
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  // Admin-set cap on how many brands this (manufacturer) stockist may create.
  Widget _brandSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 24),
        const Text('Brands, Lists & Banners',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 2),
        Text(
            'Add/rename brands, set each brand\'s stock-list count, banner and '
            'visibility — all in one place. ${widget.existing!.brandCount} brand'
            '${widget.existing!.brandCount == 1 ? '' : 's'} now.',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: ListTile(
            leading: const Icon(Icons.tune, color: Color(0xFF1B4F72)),
            title: const Text('Manage brands & lists',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            subtitle: const Text('Add brands, rename, banner, lists, visibility',
                style: TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => StockistBrandListsScreen(
                    seq: widget.existing!.id,
                    stockistName: widget.existing!.name,
                    businessType: _businessType))),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  // M only. The library stores the PRINT ("Satva White"); the surface is chosen
  // when stock is added. This decides whether Add Stock asks for the surface.
  // (project_per_brand_surface_mode)
  Widget _surfaceModeControl() {
    var mode = ['attribute', 'in_name'].contains(_surfaceMode)
        ? _surfaceMode
        : 'in_name';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.texture, size: 16, color: Colors.grey.shade600),
              const SizedBox(width: 6),
              Text('Surface convention',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade800)),
            ],
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle:
                    WidgetStateProperty.all(const TextStyle(fontSize: 12)),
              ),
              segments: const [
                ButtonSegment(
                    value: 'attribute',
                    label: Text('Attribute'),
                    icon: Icon(Icons.tune, size: 15)),
                ButtonSegment(
                    value: 'in_name',
                    label: Text('In name'),
                    icon: Icon(Icons.text_fields, size: 15)),
              ],
              selected: {mode},
              onSelectionChanged: (sel) =>
                  setState(() => _surfaceMode = sel.first),
            ),
          ),
          const SizedBox(height: 4),
          Text(
              'Attribute: the design name is the print ("Satva White") and the '
              'surface (Glossy / Matt / Carving) is picked when stock is added.\n'
              'In name: the surface is already written into the design name '
              '("m.satva white") — stock never asks for it.\n'
              'Applies to all of this manufacturer\'s brands — they are just '
              'different names for the same print.',
              style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500)),
        ],
      ),
    );
  }

  Widget _brandingSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 24),
        const Text('Catalogue Accent & Location',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 2),
        Text(
            'Accent colour & map link for the share-link stock catalogue page. '
            'The banner (logo/branding) is managed centrally on the Catalog '
            'Banners screen.',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        const SizedBox(height: 12),
        // Brand colour swatches.
        const Text('Brand colour',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            // "None" / default.
            GestureDetector(
              onTap: () => setState(() => _brandColor = ''),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: _brandColor.isEmpty
                          ? const Color(0xFF1B4F72)
                          : Colors.grey.shade300,
                      width: _brandColor.isEmpty ? 3 : 1),
                ),
                child: Icon(Icons.format_color_reset,
                    size: 16, color: Colors.grey.shade500),
              ),
            ),
            ..._brandSwatches.map((hex) {
              final c = _hexToColor(hex);
              final on = _brandColor.toUpperCase() == hex.toUpperCase();
              return GestureDetector(
                onTap: () => setState(() => _brandColor = hex),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: c,
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: on ? Colors.black : Colors.grey.shade300,
                        width: on ? 3 : 1),
                  ),
                  child: on
                      ? const Icon(Icons.check, size: 16, color: Colors.white)
                      : null,
                ),
              );
            }),
          ],
        ),
        const SizedBox(height: 12),
        _field(_mapUrl, 'Google Maps link (optional)',
            keyboard: TextInputType.url),
      ],
    );
  }

  // Parse '#RRGGBB' to a Color; falls back to the theme blue on bad input.
  static Color _hexToColor(String hex) {
    final h = hex.replaceAll('#', '').trim();
    final v = int.tryParse(h, radix: 16);
    if (v == null || h.length != 6) return const Color(0xFF1B4F72);
    return Color(0xFF000000 | v);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _saving = true; _error = null; });
    try {
      final String msg;
      if (_isEdit) {
        await _dataSvc.updateStockist(
          sequentialId: widget.existing!.id,
          name:     _name.text.trim(),
          phone:    _phone.text.trim(),
          countryCode: _code.text.trim().isEmpty ? '+91' : _code.text.trim(),
          city:     _city.text.trim(),
          state:    _state.text.trim(),
          address:  _address.text.trim(),
          priority: double.tryParse(_priority.text.trim()) ?? 0,
          gstNumber: _gst.text.trim(),
          stockistType: _tier,
        );
        await _dataSvc.setStockistBusinessType(
            widget.existing!.id, _businessType);
        await _dataSvc.setStockistListed(widget.existing!.id, _listed);
        await _dataSvc.setStockistPrivateCatalog(
            widget.existing!.id, _canPrivate);
        await _dataSvc.setDeviceLimit('stockist', widget.existing!.id,
            int.tryParse(_deviceLimit.text.trim()) ?? 1);
        await _dataSvc.setStockListLimit(widget.existing!.id,
            int.tryParse(_stockLists.text.trim()) ?? 3);
        await _dataSvc.setStockistBranding(
          widget.existing!.id,
          brandColor: _brandColor.trim(),
          mapUrl: _mapUrl.text.trim(),
        );
        await _dataSvc.setStockistTd(widget.existing!.id, _tdShow);
        await _dataSvc.setStockistCustomers(
            widget.existing!.id, _customersEnabled);
        if (_businessType == 'M') {
          await _dataSvc.setStockistSurfaceMode(widget.existing!.id, _surfaceMode);
        }
        msg = 'Stockist updated.';
      } else {
        final seqId = await _dataSvc.addStockist(
          name:     _name.text.trim(),
          email:    _email.text.trim(),
          password: _password.text,
          phone:    _phone.text.trim(),
          countryCode: _code.text.trim().isEmpty ? '+91' : _code.text.trim(),
          city:     _city.text.trim(),
          state:    _state.text.trim(),
          address:  _address.text.trim(),
          priority: double.tryParse(_priority.text.trim()) ?? 0,
          gstNumber: _gst.text.trim(),
          stockistType: _tier,
        );
        // New stockists default to 'M' in the DB; only call the setter when the
        // admin picked an importer type at creation.
        if (seqId.isNotEmpty && _businessType != 'M') {
          await _dataSvc.setStockistBusinessType(seqId, _businessType);
        }
        msg = 'Stockist created${seqId.isNotEmpty ? ' · ID $seqId' : ''}.';
      }
      if (!mounted) return;
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: const Color(0xFF2E7D32),
      ));
    } catch (e) {
      setState(() {
        _saving = false;
        _error = e.toString().replaceAll('PostgrestException:', '').trim();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // Keyboard inset + the system navigation-bar inset, so the Save button
    // clears the on-screen nav buttons (and the keyboard when open).
    final bottom = mq.viewInsets.bottom + mq.viewPadding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + bottom),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              Text(_isEdit ? 'Edit Stockist' : 'Add Stockist',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              const SizedBox(height: 2),
              Text(
                  _isEdit
                      ? 'ID ${widget.existing!.id} · login email/password unchanged here.'
                      : 'The stockist ID is generated automatically (e.g. A01).',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              const SizedBox(height: 14),

              // When editing, surface the login email read-only so the admin can
              // see which person/login owns this ID (it can't be changed here).
              if (_isEdit && widget.existing!.email.isNotEmpty) ...[
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.alternate_email,
                          size: 16, color: Colors.grey.shade600),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Login email',
                                style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.grey.shade500)),
                            Text(widget.existing!.email,
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              _field(_name, 'Name *', required: true),
              if (!_isEdit) ...[
                _field(_email, 'Email *',
                    keyboard: TextInputType.emailAddress,
                    validator: (v) {
                      final t = (v ?? '').trim();
                      if (t.isEmpty) return 'Email is required';
                      if (!t.contains('@')) return 'Invalid email';
                      return null;
                    }),
                _field(_password, 'Password *',
                    validator: (v) =>
                        (v ?? '').length < 6 ? 'Min 6 characters' : null),
              ],
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: PhoneField(
                    codeController: _code,
                    phoneController: _phone,
                    label: 'WhatsApp Number'),
              ),
              _field(_city, 'City'),
              _field(_state, 'State'),
              _field(_address, 'Address'),
              _field(_gst, 'GST number (optional)'),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: DropdownButtonFormField<String>(
                  initialValue: _tier,
                  decoration: const InputDecoration(
                      labelText: 'Tier (controls listing order)',
                      border: OutlineInputBorder()),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('None')),
                    ...kStockistTiers.map(
                        (t) => DropdownMenuItem(value: t, child: Text(t))),
                  ],
                  onChanged: (v) => setState(() => _tier = v ?? ''),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: DropdownButtonFormField<String>(
                  initialValue: _businessType,
                  decoration: const InputDecoration(
                      labelText: 'Business type',
                      border: OutlineInputBorder()),
                  items: kBusinessTypes
                      .map((t) => DropdownMenuItem(
                          value: t, child: Text(businessTypeLabel(t))))
                      .toList(),
                  onChanged: (v) =>
                      setState(() => _businessType = v ?? 'M'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 12, left: 2),
                child: Text(businessTypeHint(_businessType),
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              ),
              if (_isEdit && publicMarketLive)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _listed,
                    activeThumbColor: const Color(0xFF1B4F72),
                    title: const Text('Show in market'),
                    subtitle: Text(
                        _listed
                            ? 'Visible to all buyers in the app.'
                            : 'Private — hidden from the app, reachable only by share link.',
                        style: const TextStyle(fontSize: 11)),
                    onChanged: (v) => setState(() => _listed = v),
                  ),
                ),
              // Hidden during the private-first runway — it only makes sense once
              // the public market is live (the public/private-catalogue split is
              // a public-market concept). Reappears with the go-live switch.
              if (_isEdit && publicMarketLive)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _canPrivate,
                    activeThumbColor: Colors.deepPurple,
                    title: const Text('Allow private stock catalogues'),
                    subtitle: Text(
                        _canPrivate
                            ? 'Can create private ("Most Exclusive") stock catalogues — link-only stock.'
                            : 'Public stock catalogues only. Turn on for premium/trusted stockists.',
                        style: const TextStyle(fontSize: 11)),
                    onChanged: (v) => setState(() => _canPrivate = v),
                  ),
                ),
              if (_isEdit)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _tdShow,
                    activeThumbColor: const Color(0xFF1B4F72),
                    title: const Text('Show TilesDesign mark on banners'),
                    subtitle: Text(
                        _tdShow
                            ? 'The TilesDesign mark shows on this stockist\'s banners, at the position they choose.'
                            : 'Off — no TilesDesign mark on this stockist\'s banners.',
                        style: const TextStyle(fontSize: 11)),
                    onChanged: (v) => setState(() => _tdShow = v),
                  ),
                ),
              // An M stockist IS the factory, so the surface convention is
              // company-wide: one setting, not one per brand (its brands are
              // just alternate names for the same print). T/W sets it per brand
              // on the Brands screen. (project_per_brand_surface_mode)
              if (_isEdit && _businessType == 'M') _surfaceModeControl(),
              // Opt-in, trust-first: the platform never depends on customer
              // contact data. (project_unified_dispatch_customers)
              if (_isEdit)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _customersEnabled,
                    activeThumbColor: const Color(0xFF2E7D32),
                    title: const Text('Save customers on dispatch'),
                    subtitle: Text(
                        _customersEnabled
                            ? 'Dispatch shows a pick-or-add Customer field; saved customers (name, optional phone, place) can be reused.'
                            : 'Off — the Customer field on dispatch is plain optional text and nothing is stored.',
                        style: const TextStyle(fontSize: 11)),
                    onChanged: (v) => setState(() => _customersEnabled = v),
                  ),
                ),
              if (_isEdit) _brandingSection(),
              if (_isEdit) _deviceSection(),
              if (_isEdit) _brandSection(),
              _field(_priority, 'Priority (0.00)',
                  keyboard: const TextInputType.numberWithOptions(decimal: true),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return null; // defaults to 0
                    return double.tryParse(t) == null ? 'Enter a number' : null;
                  }),

              if (_error != null) ...[
                const SizedBox(height: 6),
                Text(_error!,
                    style: const TextStyle(color: Colors.red, fontSize: 12)),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1B4F72),
                      foregroundColor: Colors.white),
                  child: _saving
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : Text(_isEdit ? 'Save Changes' : 'Create Stockist',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController c,
    String label, {
    bool required = false,
    TextInputType? keyboard,
    String? hint,
    String? Function(String?)? validator,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextFormField(
          controller: c,
          keyboardType: keyboard,
          obscureText: label.startsWith('Password'),
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            isDense: true,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
          validator: validator ??
              (required
                  ? (v) => (v ?? '').trim().isEmpty ? '$label required' : null
                  : null),
        ),
      );
}
