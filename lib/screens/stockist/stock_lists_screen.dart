import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../config/app_config.dart';
import '../../models/stock_catalog.dart';
import '../../models/library_entry.dart';
import '../../models/share_link.dart';
import '../../models/choice_state.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../widgets/filter_section.dart';

const _navy = Color(0xFF1B4F72);

// Name + description dialog — shown before the picker (new) or via the edit
// action (existing). Returns null on cancel; name is required.
Future<({String name, String description})?> editListDetails(
    BuildContext context,
    {String name = '', String description = ''}) async {
  final nameC = TextEditingController(text: name);
  final descC = TextEditingController(text: description);
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(name.isEmpty ? 'New stock list' : 'List details'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: nameC,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
                labelText: 'List name', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: descC,
            decoration: const InputDecoration(
                labelText: 'Description (optional)',
                hintText: 'Remember what is in this list',
                border: OutlineInputBorder()),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: _navy),
          onPressed: () {
            if (nameC.text.trim().isEmpty) return;
            Navigator.pop(c, true);
          },
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  final res = ok == true
      ? (name: nameC.text.trim(), description: descC.text.trim())
      : null;
  nameC.dispose();
  descC.dispose();
  return res;
}

// "Make Stock List" — list the stockist's lists (brand-free v2 + any existing),
// create a new one, or edit one. Editing opens the design picker/builder.
// (project_fstock_model · stocklists v2)
class StockListsScreen extends StatefulWidget {
  const StockListsScreen({super.key});
  @override
  State<StockListsScreen> createState() => _StockListsScreenState();
}

class _StockListsScreenState extends State<StockListsScreen> {
  final _data = SupabaseDataService();
  final _picker = ImagePicker();
  List<StockCatalog> _lists = [];
  Map<String, int> _counts = {}; // catalogId → member count
  // Accordion: only one list open at a time (first open by default).
  String? _openId;
  final Map<String, List<ShareLink>> _links = {}; // catalogId → its timed links
  final Map<String, TextEditingController> _daysCtrls = {}; // per-list days box
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _daysCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final lists = await _data.getCatalogs(currentStockistUUID);
    final designs = await _data.getDesignsByStockist(currentStockistUUID);
    // member count = unique library masters whose membership includes the list.
    final counts = <String, int>{};
    final seen = <String, Set<String>>{}; // catalogId → libIds counted
    for (final d in designs) {
      for (final cid in d.catalogIds) {
        (seen[cid] ??= <String>{}).add(d.libraryId);
      }
    }
    seen.forEach((cid, libs) => counts[cid] = libs.length);
    if (!mounted) return;
    final active = lists.where((c) => c.isActive && !c.pendingDelete).toList();
    setState(() {
      _lists = active;
      _counts = counts;
      // Keep the open row if it still exists, else open the first by default.
      if (_openId == null || !active.any((c) => c.id == _openId)) {
        _openId = active.isNotEmpty ? active.first.id : null;
      }
      _loading = false;
    });
    if (_openId != null) _ensureLinks(_openId!);
  }

  Future<void> _ensureLinks(String catalogId) async {
    if (_links.containsKey(catalogId)) return;
    final links = await _data.getCatalogShareLinks(catalogId);
    if (!mounted) return;
    setState(() => _links[catalogId] = links);
  }

  void _toggle(String catalogId) {
    setState(() => _openId = _openId == catalogId ? null : catalogId);
    if (_openId != null) _ensureLinks(_openId!);
  }

  // New list: ask name + description FIRST, then open the design picker window.
  Future<void> _newList() async {
    final d = await editListDetails(context);
    if (d == null) return;
    if (!mounted) return;
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => StockListBuilderScreen(
            createName: d.name, createDescription: d.description)));
    if (changed == true) _load();
  }

  Future<void> _open(StockCatalog list) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => StockListBuilderScreen(existing: list)));
    if (changed == true) _load();
  }

  String _permLink(StockCatalog c) => '${AppConfig.shareBaseUrl}/s/${c.shareToken}';

  void _copy(String url) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Link copied')));
  }

  Future<void> _shareWhatsApp(String name, String url) async {
    final text = '$name: $url\n\nPowered by Tiles Stock';
    await launchUrl(
        Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}'),
        mode: LaunchMode.externalApplication);
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  // Create a timed link for [c] from its days box (default 60).
  Future<void> _genDays(StockCatalog c) async {
    final ctrl = _daysCtrls[c.id];
    final days = int.tryParse(ctrl?.text.trim() ?? '');
    if (days == null || days < 1) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enter the number of days (1 or more).')));
      return;
    }
    setState(() => _busy = true);
    final token = await _data.createCatalogShareLinkDays(c.id, days);
    _links.remove(c.id); // force reload
    await _ensureLinks(c.id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (token == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not create link — try again')));
    }
  }

  Future<void> _deleteLink(StockCatalog c, ShareLink l) async {
    if (l.id == null) return;
    setState(() => _busy = true);
    await _data.revokeShareLink(l.id!);
    _links.remove(c.id);
    await _ensureLinks(c.id);
    if (mounted) setState(() => _busy = false);
  }

  // Per-list banner: pick an image (or remove) → saved on the list, shown on the
  // share page. (stocklists v2)
  Future<void> _setBanner(StockCatalog c) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Choose from gallery'),
                onTap: () => Navigator.pop(ctx, 'gallery')),
            ListTile(
                leading: const Icon(Icons.camera_alt_outlined),
                title: const Text('Camera'),
                onTap: () => Navigator.pop(ctx, 'camera')),
            if (c.bannerUrl.isNotEmpty)
              ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.red),
                  title: const Text('Remove banner'),
                  onTap: () => Navigator.pop(ctx, 'remove')),
          ],
        ),
      ),
    );
    if (action == null) return;
    if (action == 'remove') {
      await _data.setListBanner(c.id, '');
      if (mounted) _load();
      return;
    }
    final x = await _picker.pickImage(
        source: action == 'camera' ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 85);
    if (x == null) return;
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Uploading banner…')));
    }
    final url = await CloudinaryService.uploadImage(x.path);
    if (url == null || url.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Upload failed — try again')));
      }
      return;
    }
    await _data.setListBanner(c.id, url);
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Stock lists'),
        backgroundColor: _navy,
        foregroundColor: Colors.white,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newList,
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('New list'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _lists.isEmpty
              ? Center(
                  child: Text('No stock lists yet. Tap "New list".',
                      style: TextStyle(color: Colors.grey.shade600)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 90),
                  children: [for (final c in _lists) _listCard(c)],
                ),
    );
  }

  // Accordion card: header (tap to open/close, only one open) + link panel.
  Widget _listCard(StockCatalog c) {
    final open = _openId == c.id;
    _daysCtrls.putIfAbsent(c.id, () => TextEditingController(text: '60'));
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => _toggle(c.id),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
              child: Row(
                children: [
                  Icon(open ? Icons.expand_more : Icons.chevron_right,
                      color: _navy),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(c.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 14.5)),
                        const SizedBox(height: 2),
                        Text(
                            [
                              '${_counts[c.id] ?? 0} designs',
                              if (c.bannerUrl.isNotEmpty) 'banner ✓',
                              if (c.description.trim().isNotEmpty)
                                c.description.trim(),
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11.5, color: Colors.grey.shade600)),
                      ],
                    ),
                  ),
                  IconButton(
                      tooltip: 'Banner',
                      icon: Icon(Icons.image_outlined,
                          size: 20,
                          color: c.bannerUrl.isNotEmpty
                              ? const Color(0xFF2E7D32)
                              : Colors.grey.shade600),
                      onPressed: () => _setBanner(c)),
                  IconButton(
                      tooltip: 'Edit designs',
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      onPressed: () => _open(c)),
                ],
              ),
            ),
          ),
          if (open) _linkPanel(c),
        ],
      ),
    );
  }

  // The open row's links: permanent (copy + WhatsApp) + create timed (days box)
  // + live links with created date / days left (copy · WhatsApp · delete).
  Widget _linkPanel(StockCatalog c) {
    final perm = _permLink(c);
    final links = _links[c.id];
    final live = (links ?? []).where((l) => l.revocable && !l.expired).toList();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 0, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 8),
          // Permanent link
          Row(
            children: [
              const Icon(Icons.link, size: 16, color: _navy),
              const SizedBox(width: 5),
              const Expanded(
                child: Text('Permanent link',
                    style: TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
              _miniBtn(Icons.copy, 'Copy', () => _copy(perm)),
              _miniBtn(Icons.chat, 'WhatsApp',
                  () => _shareWhatsApp(c.name, perm),
                  color: const Color(0xFF25D366)),
            ],
          ),
          const SizedBox(height: 8),
          // Create timed link
          Container(
            padding: const EdgeInsets.fromLTRB(10, 6, 8, 8),
            decoration: BoxDecoration(
                color: const Color(0xFFFFF8E1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.shade200)),
            child: Row(
              children: [
                const Text('Timed link:', style: TextStyle(fontSize: 12.5)),
                const SizedBox(width: 8),
                SizedBox(
                  width: 54,
                  child: TextField(
                    controller: _daysCtrls[c.id],
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding:
                            EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                        border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 6),
                const Text('days', style: TextStyle(fontSize: 12)),
                const Spacer(),
                ElevatedButton(
                  onPressed: _busy ? null : () => _genDays(c),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange.shade800,
                      foregroundColor: Colors.white,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 14)),
                  child: const Text('Generate', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          if (links == null)
            const Padding(
                padding: EdgeInsets.all(10),
                child: Center(
                    child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))))
          else
            for (final l in live) _liveLinkRow(c, l),
        ],
      ),
    );
  }

  Widget _liveLinkRow(StockCatalog c, ShareLink l) {
    final url = '${AppConfig.shareBaseUrl}/s/${l.token}';
    final exp = l.expiresAt;
    final created = l.createdAt;
    String status;
    if (exp == null) {
      status = 'Never expires';
    } else {
      final d = exp.difference(DateTime.now());
      final left = (d.inHours / 24).ceil();
      status = left <= 0 ? 'expires today' : '$left days left';
    }
    final made = created != null ? 'Made ${_fmtDate(created)} · ' : '';
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(8, 2, 2, 2),
      decoration: BoxDecoration(
          color: const Color(0xFFE8F5E9),
          borderRadius: BorderRadius.circular(8)),
      child: Row(
        children: [
          const Icon(Icons.schedule, size: 15, color: Color(0xFF2E7D32)),
          const SizedBox(width: 6),
          Expanded(
            child: Text('$made$status',
                style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF2E7D32))),
          ),
          _miniBtn(Icons.copy, 'Copy', () => _copy(url)),
          _miniBtn(Icons.chat, 'WhatsApp', () => _shareWhatsApp(c.name, url),
              color: const Color(0xFF25D366)),
          _miniBtn(Icons.delete_outline, 'Delete',
              _busy ? null : () => _deleteLink(c, l),
              color: Colors.red),
        ],
      ),
    );
  }

  Widget _miniBtn(IconData icon, String tip, VoidCallback? onTap,
          {Color color = _navy}) =>
      IconButton(
        tooltip: tip,
        icon: Icon(icon, size: 19, color: onTap == null ? Colors.grey : color),
        visualDensity: VisualDensity.compact,
        onPressed: onTap,
      );
}

// ── Builder ──────────────────────────────────────────────────────────────────
// New or edit one stock list: name + description + two-section design picker
// (in-list on top with Remove · available below with Add) + search + bulk add.
// Operates on LIBRARY MASTERS (membership is by library_id). F shown per design.
class StockListBuilderScreen extends StatefulWidget {
  final StockCatalog? existing;
  final String? createName; // when creating: name/description from the dialog
  final String? createDescription;
  const StockListBuilderScreen(
      {super.key, this.existing, this.createName, this.createDescription});
  @override
  State<StockListBuilderScreen> createState() => _StockListBuilderScreenState();
}

class _DesignEntry {
  final String libId;
  final String name; // master (M) or own (T/W) name
  final String image;
  final int fStock; // summed across this master's holdings
  final String sizeLabel;
  // Filter attributes (aggregated across this master's holdings).
  final String size;
  final String colour;
  final String tileType;
  final Set<String> qualities;
  final Set<String> surfaces;
  _DesignEntry(this.libId, this.name, this.image, this.fStock, this.sizeLabel,
      {this.size = '',
      this.colour = '',
      this.tileType = '',
      this.qualities = const {},
      this.surfaces = const {}});
}

class _StockListBuilderScreenState extends State<StockListBuilderScreen> {
  final _data = SupabaseDataService();
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();

  final List<_DesignEntry> _all = [];
  final Map<String, Set<String>> _aliasByLib = {}; // libId → alias names (lower)
  final Set<String> _selected = {}; // libIds in the list
  String _search = '';
  // Rich filter (same facets as the Stock/Control page) for "Add designs".
  final Set<String> _fSizes = {};
  final Set<String> _fQualities = {};
  final Set<String> _fSurfaces = {};
  final Set<String> _fColours = {};
  final Set<String> _fTypes = {};
  final _minFCtrl = TextEditingController();
  final _maxFCtrl = TextEditingController();
  bool _loading = true;
  bool _saving = false;

  int get _activeFilterCount =>
      _fSizes.length +
      _fQualities.length +
      _fSurfaces.length +
      _fColours.length +
      _fTypes.length +
      (_minFCtrl.text.trim().isNotEmpty ? 1 : 0) +
      (_maxFCtrl.text.trim().isNotEmpty ? 1 : 0);

  bool get _isM => currentStockistBusinessType == 'M';
  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _nameCtrl.text = widget.existing?.name ?? widget.createName ?? '';
    _descCtrl.text =
        widget.existing?.description ?? widget.createDescription ?? '';
    _searchCtrl.addListener(
        () => setState(() => _search = _searchCtrl.text.trim().toLowerCase()));
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _searchCtrl.dispose();
    _minFCtrl.dispose();
    _maxFCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final designs = await _data.getDesignsByStockist(currentStockistUUID);
    final lib = await _data.getMyLibrary();
    _aliasByLib.clear();
    for (final LibraryEntry e in lib) {
      final names = <String>{e.masterName.toLowerCase()};
      names.addAll(e.aliases.values.map((v) => v.toLowerCase()));
      _aliasByLib[e.id] = names;
    }
    // Dedupe holdings → one entry per library master; aggregate F + facets; seed
    // selection. A master spans qualities/surfaces, so those are collected as sets.
    final byLib = <String, _DesignEntry>{};
    final fSum = <String, int>{};
    final quals = <String, Set<String>>{};
    final surfs = <String, Set<String>>{};
    for (final d in designs) {
      if (d.libraryId.isEmpty) continue;
      fSum[d.libraryId] = (fSum[d.libraryId] ?? 0) + d.fStock;
      (quals[d.libraryId] ??= <String>{}).add(d.quality);
      if (d.surfaceType.trim().isNotEmpty && d.surfaceType != 'None') {
        (surfs[d.libraryId] ??= <String>{}).add(d.surfaceType);
      }
      byLib.putIfAbsent(
          d.libraryId,
          () => _DesignEntry(
                d.libraryId,
                _isM && d.masterDesignName.trim().isNotEmpty
                    ? d.masterDesignName
                    : d.name,
                d.faceImageUrls.isNotEmpty ? d.faceImageUrls.first : '',
                0,
                d.size.replaceAll(' mm', ''),
                size: d.size,
                colour: d.colour,
                tileType: d.tileType,
              ));
      if (_isEdit && d.catalogIds.contains(widget.existing!.id)) {
        _selected.add(d.libraryId);
      }
    }
    _all
      ..clear()
      ..addAll(byLib.values.map((e) => _DesignEntry(
            e.libId, e.name, e.image, fSum[e.libId] ?? 0, e.sizeLabel,
            size: e.size,
            colour: e.colour,
            tileType: e.tileType,
            qualities: quals[e.libId] ?? const {},
            surfaces: surfs[e.libId] ?? const {},
          )));
    _all.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (!mounted) return;
    setState(() => _loading = false);
  }

  bool _matchesSearch(_DesignEntry e) {
    if (_search.isEmpty) return true;
    if (e.name.toLowerCase().contains(_search)) return true;
    if (_isM) {
      final a = _aliasByLib[e.libId];
      if (a != null && a.any((x) => x.contains(_search))) return true;
    }
    return false;
  }

  bool _matches(_DesignEntry e) {
    if (!_matchesSearch(e)) return false;
    if (_fSizes.isNotEmpty && !_fSizes.contains(e.size)) return false;
    if (_fColours.isNotEmpty && !_fColours.contains(e.colour)) return false;
    if (_fTypes.isNotEmpty && !_fTypes.contains(e.tileType)) return false;
    if (_fQualities.isNotEmpty && !e.qualities.any(_fQualities.contains)) {
      return false;
    }
    if (_fSurfaces.isNotEmpty && !e.surfaces.any(_fSurfaces.contains)) {
      return false;
    }
    final minF = int.tryParse(_minFCtrl.text.trim());
    final maxF = int.tryParse(_maxFCtrl.text.trim());
    if (minF != null && e.fStock < minF) return false;
    if (maxF != null && e.fStock > maxF) return false;
    return true;
  }

  Future<void> _openFilterSheet() async {
    final sizes = _all.map((e) => e.size).toSet().toList()..sort();
    final colours = _all
        .map((e) => e.colour)
        .where((c) => c.trim().isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final types = _all
        .map((e) => e.tileType)
        .where((t) => t.trim().isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final qualities = _all.expand((e) => e.qualities).toSet().toList()..sort();
    final surfaces = _all.expand((e) => e.surfaces).toSet().toList()..sort();

    final lSizes = Set<String>.from(_fSizes);
    final lQual = Set<String>.from(_fQualities);
    final lSurf = Set<String>.from(_fSurfaces);
    final lCol = Set<String>.from(_fColours);
    final lType = Set<String>.from(_fTypes);
    final minCtrl = TextEditingController(text: _minFCtrl.text);
    final maxCtrl = TextEditingController(text: _maxFCtrl.text);

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget chipWrap(List<String> opts, Set<String> sel) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final o in opts)
                    FilterChip(
                      label: Text(o.replaceAll(' mm', ''),
                          style: const TextStyle(fontSize: 12)),
                      selected: sel.contains(o),
                      onSelected: (_) => setSheet(() =>
                          sel.contains(o) ? sel.remove(o) : sel.add(o)),
                      selectedColor: _navy.withValues(alpha: 0.15),
                      checkmarkColor: _navy,
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              );
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.7,
            maxChildSize: 0.92,
            builder: (_, scroll) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Row(
                    children: [
                      const Text('Filters',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16)),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setSheet(() {
                          lSizes.clear();
                          lQual.clear();
                          lSurf.clear();
                          lCol.clear();
                          lType.clear();
                          minCtrl.clear();
                          maxCtrl.clear();
                        }),
                        child: const Text('Reset all',
                            style: TextStyle(color: Colors.red, fontSize: 13)),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: Colors.grey.shade200),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(
                    children: [
                      const Text('Shown qty (F)',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 13)),
                      const SizedBox(width: 12),
                      Expanded(child: _rangeBox(minCtrl, 'Min')),
                      const SizedBox(width: 8),
                      Expanded(child: _rangeBox(maxCtrl, 'Max')),
                    ],
                  ),
                ),
                Divider(height: 1, color: Colors.grey.shade200),
                Expanded(
                  child: ListView(
                    controller: scroll,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      if (sizes.isNotEmpty)
                        FilterSection(
                            title: 'Size',
                            summary: filterSummary(lSizes),
                            child: chipWrap(sizes, lSizes)),
                      if (qualities.isNotEmpty)
                        FilterSection(
                            title: 'Quality',
                            summary: filterSummary(lQual),
                            child: chipWrap(qualities, lQual)),
                      if (surfaces.isNotEmpty)
                        FilterSection(
                            title: 'Finish',
                            summary: filterSummary(lSurf),
                            child: chipWrap(surfaces, lSurf)),
                      if (types.isNotEmpty)
                        FilterSection(
                            title: 'Tile Type',
                            summary: filterSummary(lType),
                            child: chipWrap(types, lType)),
                      if (colours.isNotEmpty)
                        FilterSection(
                            title: 'Colour',
                            summary: filterSummary(lCol),
                            child: chipWrap(colours, lCol)),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: ElevatedButton.styleFrom(
                            backgroundColor: _navy,
                            foregroundColor: Colors.white),
                        child: const Text('Apply'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (ok == true) {
      setState(() {
        _fSizes
          ..clear()
          ..addAll(lSizes);
        _fQualities
          ..clear()
          ..addAll(lQual);
        _fSurfaces
          ..clear()
          ..addAll(lSurf);
        _fColours
          ..clear()
          ..addAll(lCol);
        _fTypes
          ..clear()
          ..addAll(lType);
        _minFCtrl.text = minCtrl.text.trim();
        _maxFCtrl.text = maxCtrl.text.trim();
      });
    }
    minCtrl.dispose();
    maxCtrl.dispose();
  }

  Widget _rangeBox(TextEditingController c, String hint) => TextField(
        controller: c,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          hintText: hint,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Give the list a name.')));
      return;
    }
    setState(() => _saving = true);
    try {
      final id = await _data.saveStockList(
          id: widget.existing?.id,
          name: name,
          description: _descCtrl.text.trim());
      await _data.setListDesigns(id, _selected.toList());
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save — $e')));
    }
  }

  Future<void> _editDetails() async {
    final d = await editListDetails(context,
        name: _nameCtrl.text, description: _descCtrl.text);
    if (d == null) return;
    setState(() {
      _nameCtrl.text = d.name;
      _descCtrl.text = d.description;
    });
  }

  @override
  Widget build(BuildContext context) {
    final inList = _all.where((e) => _selected.contains(e.libId)).toList();
    final available =
        _all.where((e) => !_selected.contains(e.libId) && _matches(e)).toList();
    final title = _nameCtrl.text.trim().isEmpty
        ? (_isEdit ? 'Edit list' : 'New list')
        : _nameCtrl.text.trim();
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(title, overflow: TextOverflow.ellipsis),
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
              tooltip: 'Edit name / description',
              onPressed: _editDetails,
              icon: const Icon(Icons.edit_outlined)),
          _saving
              ? const Padding(
                  padding: EdgeInsets.only(right: 16),
                  child: Center(
                      child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))))
              : TextButton(
                  onPressed: _save,
                  child: const Text('Save',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold))),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Pinned controls — search + Filters, then count + Select all.
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _searchCtrl,
                              decoration: InputDecoration(
                                hintText: 'Search design name…',
                                prefixIcon: const Icon(Icons.search, size: 20),
                                suffixIcon: _search.isNotEmpty
                                    ? IconButton(
                                        icon: const Icon(Icons.clear, size: 18),
                                        onPressed: () => _searchCtrl.clear())
                                    : null,
                                isDense: true,
                                filled: true,
                                fillColor: const Color(0xFFF5F5F5),
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide.none),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: _openFilterSheet,
                            icon: const Icon(Icons.tune, size: 18),
                            label: Text(_activeFilterCount > 0
                                ? 'Filters ($_activeFilterCount)'
                                : 'Filters'),
                            style: OutlinedButton.styleFrom(
                                foregroundColor: _navy,
                                side: BorderSide(
                                    color: _activeFilterCount > 0
                                        ? _navy
                                        : Colors.grey.shade400)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text('In list: ${inList.length}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, color: _navy)),
                          const Spacer(),
                          if (available.isNotEmpty)
                            TextButton.icon(
                              onPressed: () => setState(() => _selected
                                  .addAll(available.map((e) => e.libId))),
                              icon: const Icon(Icons.done_all, size: 18),
                              label: Text('Select all (${available.length})'),
                            ),
                          if (inList.isNotEmpty)
                            TextButton(
                              onPressed: () =>
                                  setState(() => _selected.clear()),
                              child: const Text('Clear',
                                  style: TextStyle(color: Colors.red)),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                    children: [
                      _sectionHeader('In this list', inList.length),
                      if (inList.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('No designs yet — add some below.',
                              style: TextStyle(
                                  fontSize: 12.5, color: Colors.black54)),
                        ),
                      for (final e in inList) _row(e, inList: true),
                      const SizedBox(height: 8),
                      _sectionHeader('Add designs', available.length),
                      if (available.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                              _search.isEmpty && _activeFilterCount == 0
                                  ? 'All designs are in this list.'
                                  : 'No matches.',
                              style: const TextStyle(
                                  fontSize: 12.5, color: Colors.black54)),
                        ),
                      for (final e in available) _row(e, inList: false),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _sectionHeader(String label, int count) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
        child: Text('$label ($count)',
            style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 13.5, color: _navy)),
      );

  Widget _row(_DesignEntry e, {required bool inList}) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 42,
                height: 42,
                child: e.image.isEmpty
                    ? Container(
                        color: Colors.grey.shade200,
                        child: Icon(Icons.image_outlined,
                            size: 18, color: Colors.grey.shade400))
                    : CachedNetworkImage(
                        imageUrl: CloudinaryService.thumbUrl(e.image, width: 120),
                        fit: BoxFit.cover,
                        placeholder: (_, __) =>
                            Container(color: Colors.grey.shade100),
                        errorWidget: (_, __, ___) =>
                            Container(color: Colors.grey.shade200),
                      ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text('${e.sizeLabel} · F ${e.fStock}',
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                ],
              ),
            ),
            inList
                ? TextButton.icon(
                    onPressed: () =>
                        setState(() => _selected.remove(e.libId)),
                    icon: const Icon(Icons.remove_circle_outline, size: 18),
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                    label: const Text('Remove'),
                  )
                : FilledButton.icon(
                    onPressed: () => setState(() => _selected.add(e.libId)),
                    icon: const Icon(Icons.add, size: 18),
                    style: FilledButton.styleFrom(backgroundColor: _navy),
                    label: const Text('Add'),
                  ),
          ],
        ),
      ),
    );
  }
}
