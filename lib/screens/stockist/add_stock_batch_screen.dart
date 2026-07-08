import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/library_entry.dart';
import '../../models/brand.dart';
import '../../models/choice_state.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../widgets/save_bar.dart';

/// Batch manual stock entry. The stockist builds a list of rows — each a
/// Design + (M:) Brand + Quality + Quantity — and commits them together. Only
/// the QUANTITY is typed; everything else is a searchable selection. Adding
/// stock only touches P_Stock (no stock list — that's a separate concern), so
/// there is no list picker here. Replaces the old one-design-at-a-time form.
class AddStockBatchScreen extends StatefulWidget {
  final String? initialBrandId;
  const AddStockBatchScreen({super.key, this.initialBrandId});
  @override
  State<AddStockBatchScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);
const _green = Color(0xFF2E7D32);

/// One built-up entry (before commit).
class _Entry {
  final LibraryEntry master;
  final String? brandId;   // M only; null → the master's own brand
  final String? brandName;
  final String quality;
  int qty;
  _Entry({
    required this.master,
    required this.brandId,
    required this.brandName,
    required this.quality,
    required this.qty,
  });
  // Same design + brand + quality = the same holding.
  String get key => '${master.id}|${brandId ?? ''}|$quality';
}

class _State extends State<AddStockBatchScreen> {
  final _svc = SupabaseDataService();
  bool _loading = true;
  bool _saving = false;

  List<LibraryEntry> _masters = [];
  List<Brand> _brands = [];
  bool get _isM => currentStockistBusinessType == 'M';

  // The entry currently being built.
  LibraryEntry? _selMaster;
  String? _selBrandId;
  String _selQuality = 'Premium';
  final _qtyCtrl = TextEditingController();

  // Top brand filter — narrows the Design picker (M).
  String? _brandFilter;

  final _entries = <_Entry>[];

  @override
  void initState() {
    super.initState();
    final b = widget.initialBrandId;
    if (b != null && b != 'all' && b.isNotEmpty) {
      _brandFilter = b;
      _selBrandId = b;
    }
    _load();
  }

  @override
  void dispose() {
    _qtyCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final masters = await _svc.getMyLibrary();
    final brands = await _svc.getMyBrands();
    if (!mounted) return;
    setState(() {
      _masters = masters;
      _brands = brands;
      _loading = false;
    });
  }

  String _brandNameOf(String? id) {
    if (id == null) return '';
    final m = _brands.where((b) => b.id == id).toList();
    return m.isEmpty ? '' : m.first.name;
  }

  // A master's name under a brand (alias) when present, else its master name.
  String _displayName(LibraryEntry m, String? brandId) {
    final alias = brandId == null ? null : m.aliases[brandId];
    return (alias != null && alias.trim().isNotEmpty) ? alias.trim() : m.masterName;
  }

  List<LibraryEntry> _filteredMasters(String query, String? brandFilter) {
    final q = query.trim().toLowerCase();
    return _masters.where((m) {
      if (brandFilter != null &&
          m.brandId != brandFilter &&
          !m.aliases.containsKey(brandFilter)) {
        return false;
      }
      if (q.isEmpty) return true;
      final names = [m.masterName, ...m.aliases.values];
      return names.any((n) => n.toLowerCase().contains(q));
    }).toList()
      ..sort((a, b) => a.masterName.compareTo(b.masterName));
  }

  int get _totalBoxes => _entries.fold(0, (s, e) => s + e.qty);

  void _snack(String m, [Color c = _green]) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m), backgroundColor: c));

  // ── Pickers ─────────────────────────────────────────────────────────────

  Future<void> _pickDesign() async {
    final chosen = await showModalBottomSheet<LibraryEntry>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        String query = '';
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final results = _filteredMasters(query, _brandFilter);
            return Padding(
              padding: EdgeInsets.only(
                  bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.75,
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    const Text('Select design',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                      child: TextField(
                        autofocus: true,
                        onChanged: (v) => setSheet(() => query = v),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(Icons.search),
                          hintText: 'Search design name…',
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                    Expanded(
                      child: results.isEmpty
                          ? const Center(child: Text('No designs match.'))
                          : ListView.separated(
                              itemCount: results.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (_, i) {
                                final m = results[i];
                                return ListTile(
                                  leading: ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: m.imageUrl.isEmpty
                                        ? Container(
                                            width: 44, height: 44,
                                            color: Colors.grey.shade100,
                                            child: const Icon(
                                                Icons.image_not_supported,
                                                size: 18, color: Colors.grey))
                                        : CachedNetworkImage(
                                            imageUrl: CloudinaryService.thumbUrl(
                                                m.imageUrl, width: 120),
                                            width: 44, height: 44,
                                            fit: BoxFit.cover,
                                            placeholder: (_, __) => Container(
                                                color: Colors.grey.shade200),
                                            errorWidget: (_, __, ___) =>
                                                Container(
                                                    color:
                                                        Colors.grey.shade200)),
                                  ),
                                  title: Text(m.masterName),
                                  subtitle: Text(m.size.replaceAll(' mm', '')),
                                  onTap: () => Navigator.pop(ctx, m),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (chosen != null) {
      setState(() {
        _selMaster = chosen;
        // For M, default the brand to the master's own brand if none picked.
        if (_isM && _selBrandId == null && chosen.brandId.isNotEmpty) {
          _selBrandId = chosen.brandId;
        }
      });
    }
  }

  Future<void> _pickBrand() async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        String query = '';
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final results = _brands
                .where((b) =>
                    b.name.toLowerCase().contains(query.trim().toLowerCase()))
                .toList()
              ..sort((a, b) => a.name.compareTo(b.name));
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.6,
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    const Text('Select brand',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                      child: TextField(
                        onChanged: (v) => setSheet(() => query = v),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(Icons.search),
                          hintText: 'Search brand…',
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        children: [
                          for (final b in results)
                            ListTile(
                              title: Text(b.name),
                              onTap: () => Navigator.pop(ctx, b.id),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (chosen != null) setState(() => _selBrandId = chosen);
  }

  // ── Add / duplicate ───────────────────────────────────────────────────────

  void _resetRow() {
    _selMaster = null;
    _qtyCtrl.clear();
    // brand + quality kept for faster repeated entry.
  }

  void _addEntry() {
    if (_selMaster == null) {
      _snack('Pick a design first.', Colors.red);
      return;
    }
    if (_isM && _selBrandId == null) {
      _snack('Pick a brand.', Colors.red);
      return;
    }
    final qty = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
    if (qty <= 0) {
      _snack('Enter a quantity.', Colors.red);
      return;
    }
    final e = _Entry(
      master: _selMaster!,
      brandId: _isM ? _selBrandId : null,
      brandName: _isM ? _brandNameOf(_selBrandId) : null,
      quality: _selQuality,
      qty: qty,
    );
    final idx = _entries.indexWhere((x) => x.key == e.key);
    if (idx >= 0) {
      _resolveDuplicate(idx, e);
      return;
    }
    setState(() {
      _entries.add(e);
      _resetRow();
    });
  }

  // Same design+brand+quality already in the list: show BOTH quantities and let
  // the stockist Remove one (discard the new) or Add both (sum into one row).
  Future<void> _resolveDuplicate(int existingIdx, _Entry incoming) async {
    final existing = _entries[existingIdx];
    final label =
        '${_displayName(existing.master, existing.brandId)} · '
        '${existing.brandName?.isNotEmpty == true ? '${existing.brandName} · ' : ''}'
        '${existing.quality}';
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Already added'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Text('Existing:  ${existing.qty} boxes'),
            Text('New:        ${incoming.qty} boxes'),
            const SizedBox(height: 8),
            Text('Add both = ${existing.qty + incoming.qty} boxes',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, color: _green)),
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
        existing.qty += incoming.qty;
        _resetRow();
      });
    } else if (choice == 'one') {
      // Keep the existing single row, discard the new one.
      setState(_resetRow);
    }
  }

  Future<void> _editQty(_Entry e) async {
    final ctrl = TextEditingController(text: '${e.qty}');
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
          onSubmitted: (s) =>
              Navigator.pop(ctx, int.tryParse(s.trim()) ?? e.qty),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () =>
                  Navigator.pop(ctx, int.tryParse(ctrl.text.trim()) ?? e.qty),
              child: const Text('Set')),
        ],
      ),
    );
    if (v != null && v > 0) setState(() => e.qty = v);
  }

  Future<void> _addNewDesign() async {
    await context.push('/stockist/library');
    await _load(); // the new design is now selectable
  }

  // ── Save ───────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (_entries.isEmpty) {
      _snack('Add at least one design.', Colors.red);
      return;
    }
    final action = await _confirmSheet();
    if (action != 'save') return; // 'edit' or dismissed → stay on the page

    setState(() => _saving = true);
    try {
      final payload = _entries
          .map((e) => {
                'library_id': e.master.id,
                'quality': e.quality,
                'quantity': e.qty,
                'brand_id': e.brandId,
                'surface': e.master.surfaceType,
              })
          .toList();
      final res = await _svc.addInventoryBatch(payload);
      if (!mounted) return;
      final count = (res['count'] as num?)?.toInt() ?? _entries.length;
      final boxes = (res['boxes'] as num?)?.toInt() ?? _totalBoxes;
      _snack('Added $count design${count == 1 ? '' : 's'} · $boxes boxes.');
      context.pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('$e', Colors.red);
    }
  }

  // Confirm-or-edit sheet. Only Save + Edit are active; Edit just collapses the
  // sheet and returns to the page for more changes.
  Future<String?> _confirmSheet() {
    return showModalBottomSheet<String>(
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
              Text('Save ${_entries.length} '
                  'design${_entries.length == 1 ? '' : 's'} · $_totalBoxes boxes?',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final e in _entries)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${_displayName(e.master, e.brandId)}'
                                  '${e.brandName?.isNotEmpty == true ? ' · ${e.brandName}' : ''}'
                                  ' · ${e.quality}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              Text('${e.qty}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, 'edit'),
                      style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 13)),
                      child: const Text('Edit'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(ctx, 'save'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: _green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 13)),
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add Stock')),
      bottomNavigationBar: SaveBar(
        label: 'Save ($_totalBoxes boxes)',
        icon: Icons.check,
        color: _green,
        onPressed: _save,
        saving: _saving,
        dirty: _entries.isNotEmpty,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              children: [
                _entryBuilder(),
                const SizedBox(height: 14),
                if (_entries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: Text('No entries yet — add designs above.',
                          style: TextStyle(color: Colors.grey.shade500)),
                    ),
                  )
                else ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                        '${_entries.length} to add · $_totalBoxes boxes',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Colors.grey.shade700)),
                  ),
                  const SizedBox(height: 8),
                  ..._entries.asMap().entries.map((me) => _entryTile(me.key)),
                ],
              ],
            ),
    );
  }

  Widget _entryBuilder() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // M brand filter (narrows the design list).
            if (_isM) ...[
              _selectField(
                label: 'Brand',
                value: _selBrandId == null
                    ? 'Select brand'
                    : _brandNameOf(_selBrandId),
                icon: Icons.storefront_outlined,
                onTap: _pickBrand,
                placeholder: _selBrandId == null,
              ),
              const SizedBox(height: 10),
            ],
            _selectField(
              label: 'Design',
              value: _selMaster == null
                  ? 'Search & select design'
                  : _displayName(_selMaster!, _isM ? _selBrandId : null),
              icon: Icons.grid_view_rounded,
              onTap: _pickDesign,
              placeholder: _selMaster == null,
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Quality',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      SegmentedButton<String>(
                        showSelectedIcon: false,
                        style: ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          textStyle: WidgetStateProperty.all(
                              const TextStyle(fontSize: 12)),
                        ),
                        segments: const [
                          ButtonSegment(value: 'Premium', label: Text('Premium')),
                          ButtonSegment(value: 'Standard', label: Text('Standard')),
                        ],
                        selected: {_selQuality},
                        onSelectionChanged: (s) =>
                            setState(() => _selQuality = s.first),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Quantity',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      TextField(
                        controller: _qtyCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly
                        ],
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Boxes',
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 12),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _addEntry,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add'),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: _navy,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12)),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: _addNewDesign,
                  icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                  label: const Text('New design'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: _navy,
                      padding: const EdgeInsets.symmetric(
                          vertical: 12, horizontal: 10)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _selectField({
    required String label,
    required String value,
    required IconData icon,
    required VoidCallback onTap,
    required bool placeholder,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade400),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
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
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _entryTile(int i) {
    final e = _entries[i];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_displayName(e.master, e.brandId),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(
                    [
                      e.master.size.replaceAll(' mm', ''),
                      if (e.brandName?.isNotEmpty == true) e.brandName!,
                      e.quality,
                    ].join(' · '),
                    style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
            InkWell(
              onTap: () => _editQty(e),
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: _navy.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('${e.qty}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: _navy)),
              ),
            ),
            IconButton(
              icon: Icon(Icons.delete_outline,
                  size: 20, color: Colors.red.shade400),
              onPressed: () => setState(() => _entries.removeAt(i)),
            ),
          ],
        ),
      ),
    );
  }
}
