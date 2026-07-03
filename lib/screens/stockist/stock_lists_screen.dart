import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../config/app_config.dart';
import '../../models/stock_catalog.dart';
import '../../models/brand.dart';
import 'list_banner_editor.dart';
import '../../models/library_entry.dart';
import '../../models/share_link.dart';
import '../../models/choice_state.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../widgets/filter_section.dart';

const _navy = Color(0xFF1B4F72);
const _blue = Color(0xFF1565C0);   // permanent list
const _orange = Color(0xFFE65100); // temporary list

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
  List<StockCatalog> _lists = [];
  List<Brand> _brands = []; // for the Brands manager (rename / hide / delete)
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
    final brands = await _data.getMyBrands();
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
    // This is the MANAGEMENT screen, so show the stockist ALL their own lists:
    // active ones, plus hidden ones and pending-delete ones. Otherwise hiding a
    // list (which deactivates it) makes it vanish here — and with it the unhide
    // toggle + Delete button + 24h "Keep list" cancel become unreachable.
    final active = lists
        .where((c) => c.isActive || c.hiddenByStockist || c.pendingDelete)
        .toList();
    setState(() {
      _lists = active;
      _brands = brands;
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

  // Type picker: permanent (blue) or temporary (orange).
  Future<String?> _pickListType() => showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Choose list type'),
          contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _typeCard(
                ctx, 'permanent', _blue, Icons.auto_awesome,
                'Permanent',
                'Condition-based · auto-updates when new stock arrives',
              ),
              const SizedBox(height: 10),
              _typeCard(
                ctx, 'temporary', _orange, Icons.touch_app_outlined,
                'Temporary',
                'Pick specific designs manually · fixed selection',
              ),
              const SizedBox(height: 4),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
          ],
        ),
      );

  Widget _typeCard(BuildContext ctx, String type, Color color, IconData icon,
      String title, String subtitle) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => Navigator.pop(ctx, type),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 1.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: color,
                          fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(
                          fontSize: 11.5, color: Colors.black54)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: color.withValues(alpha: 0.6)),
          ],
        ),
      ),
    );
  }

  Future<void> _newList() async {
    final type = await _pickListType();
    if (type == null || !mounted) return;
    if (type == 'permanent') {
      final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
          builder: (_) => PermanentListEditorScreen(brands: _brands)));
      if (changed == true) _load();
    } else {
      final d = await editListDetails(context);
      if (d == null || !mounted) return;
      final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
          builder: (_) => StockListBuilderScreen(
              createName: d.name, createDescription: d.description)));
      if (changed == true) _load();
    }
  }

  Future<void> _open(StockCatalog list) async {
    if (list.isPermanent) {
      final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
          builder: (_) =>
              PermanentListEditorScreen(existing: list, brands: _brands)));
      if (changed == true) _load();
    } else {
      final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
          builder: (_) => StockListBuilderScreen(existing: list)));
      if (changed == true) _load();
    }
  }

  String _conditionSummary(StockCatalog c) {
    final parts = <String>[];
    if (c.filterBrandIds.isNotEmpty) {
      final names = c.filterBrandIds
          .map((id) => _brands.where((b) => b.id == id))
          .where((m) => m.isNotEmpty)
          .map((m) => m.first.name);
      if (names.isNotEmpty) parts.add(names.join('/'));
    }
    if (c.filterQualities.isNotEmpty) parts.add(c.filterQualities.join('/'));
    if (c.filterSurfaces.isNotEmpty) parts.add(c.filterSurfaces.join('/'));
    if (c.filterTileTypes.isNotEmpty) parts.add(c.filterTileTypes.join('/'));
    if (c.filterStockTypes.isNotEmpty) parts.add(c.filterStockTypes.join('/'));
    if (c.filterSizes.isNotEmpty) {
      parts.add(c.filterSizes.map((s) => s.replaceAll(' mm', '')).join('/'));
    }
    if (c.filterBoxMin != null || c.filterBoxMax != null) {
      final mn = c.filterBoxMin?.toString() ?? '0';
      final mx = c.filterBoxMax?.toString() ?? '∞';
      parts.add('Boxes $mn–$mx');
    }
    return parts.isEmpty ? 'All designs' : parts.join(' · ');
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

  // Per-list banner: open the full layout editor (source / logo·name / position),
  // shown on the share page. Falls back to the brand banner when unset.
  // (project_session_resume #6)
  Future<void> _setBanner(StockCatalog c) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => ListBannerEditorScreen(catalog: c)),
    );
    if (changed == true && mounted) _load();
  }

  // ── Share all ──────────────────────────────────────────────────────────────
  // Bundle every stock list into one WhatsApp message. First asks Permanent or
  // Custom-days — Custom mints a fresh timed link (same validity) per list.
  // Lists are brand-free now, so this covers all of them in one go.
  Future<void> _shareAll() async {
    if (_lists.isEmpty) return;
    final daysCtrl = TextEditingController(text: '60');
    bool permanent = true;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Share all lists'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Sends the link of all ${_lists.length} list'
                  '${_lists.length == 1 ? '' : 's'} in one message.',
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              Row(
                children: [
                  ChoiceChip(
                    label: const Text('Permanent'),
                    selected: permanent,
                    onSelected: (_) => setS(() => permanent = true),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('Custom days'),
                    selected: !permanent,
                    onSelected: (_) => setS(() => permanent = false),
                  ),
                ],
              ),
              if (!permanent)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 60,
                        child: TextField(
                          controller: daysCtrl,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          decoration: const InputDecoration(
                              isDense: true, border: OutlineInputBorder()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text('days'),
                    ],
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _navy),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Share')),
          ],
        ),
      ),
    );
    if (go != true) {
      daysCtrl.dispose();
      return;
    }

    final entries = <String>[];
    if (permanent) {
      for (final c in _lists) {
        entries.add('${c.name}: ${_permLink(c)}');
      }
      daysCtrl.dispose();
    } else {
      final days = int.tryParse(daysCtrl.text.trim());
      daysCtrl.dispose();
      if (days == null || days < 1) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Enter the number of days (1 or more).')));
        }
        return;
      }
      setState(() => _busy = true);
      for (final c in _lists) {
        final token = await _data.createCatalogShareLinkDays(c.id, days);
        if (token != null) {
          entries.add('${c.name}: ${AppConfig.shareBaseUrl}/s/$token');
        }
        _links.remove(c.id); // force reload of that list's links
      }
      if (_openId != null) await _ensureLinks(_openId!);
      if (mounted) setState(() => _busy = false);
    }
    if (entries.isEmpty) return;
    // Header: the masked trade name when anonymous, else the real company name.
    final header = currentStockistIsAnonymous &&
            currentStockistDisplayName.isNotEmpty
        ? currentStockistDisplayName
        : '';
    final body = entries.join('\n');
    final text =
        '${header.isEmpty ? '' : '$header\n'}$body\n\nPowered by Tiles Stock';
    await launchUrl(
        Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}'),
        mode: LaunchMode.externalApplication);
  }

  // ── Brands manager ──────────────────────────────────────────────────────────
  // Stockist-side brand controls: rename (all brands), and for non-default
  // brands hide-from-buyers + 24h soft-delete (with a cancel within the window).
  // Brands are created by the admin; lists are brand-free, so this is identity
  // + visibility only. (project_multi_brand · brand banner retired)
  String _deleteCountdown(DateTime scheduledAt) {
    final left =
        scheduledAt.add(const Duration(hours: 24)).difference(DateTime.now());
    if (left.isNegative) return 'deleting now…';
    final h = left.inHours;
    final m = left.inMinutes % 60;
    return h > 0 ? '${h}h ${m}m left' : '${m}m left';
  }

  Future<void> _runBrand(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      final brands = await _data.getMyBrands();
      if (mounted) setState(() => _brands = brands);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$e'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _renameBrand(Brand b) async {
    final ctrl = TextEditingController(text: b.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename brand'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
              hintText: 'Brand name (e.g. Bianco Tera)',
              border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );
    final name = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || name.isEmpty || name == b.name) return;
    await _runBrand(() => _data.renameBrand(b.id, name));
  }

  Future<void> _confirmScheduleBrandDelete(Brand b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this brand?'),
        content: Text(
            'Deleting "${b.name}" removes the brand and its stock lists. This '
            'CANNOT be undone.\n\nFor safety it happens after a 24-hour wait — '
            'you can stop it any time within that window.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Start 24h deletion')),
        ],
      ),
    );
    if (ok != true) return;
    await _runBrand(() => _data.scheduleBrandDelete(b.id));
  }

  // ── Stock-list hide + 24h soft-delete (mirrors the brand flow above) ─────────
  // Runs an action, then reloads the whole screen (lists + counts + links).
  Future<void> _runList(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$e'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmScheduleListDelete(StockCatalog c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this stock list?'),
        content: Text(
            'Deleting "${c.name}" removes the list and its share links. This '
            'CANNOT be undone.\n\nFor safety it happens after a 24-hour wait — '
            'you can stop it any time within that window.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Start 24h deletion')),
        ],
      ),
    );
    if (ok != true) return;
    await _runList(() => _data.scheduleListDelete(c.id));
  }

  Future<void> _openBrandManager() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        // _runBrand updates _brands in the parent; setSheet rebuilds this sheet.
        builder: (ctx, setSheet) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.55,
          maxChildSize: 0.9,
          builder: (_, scroll) => Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 6),
                child: Row(
                  children: [
                    Icon(Icons.sell, color: _navy),
                    SizedBox(width: 8),
                    Text('Brands',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 17)),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                      'Rename a brand, or hide / delete an extra brand. New '
                      'brands are enabled by the admin.',
                      style: TextStyle(fontSize: 12, color: Colors.black54)),
                ),
              ),
              Divider(height: 1, color: Colors.grey.shade200),
              Expanded(
                child: ListView(
                  controller: scroll,
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
                  children: [
                    for (final b in _brands)
                      _brandManagerCard(b, () => setSheet(() {}))
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _brandManagerCard(Brand b, VoidCallback refresh) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sell, size: 18, color: _navy),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(b.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: _navy)),
                ),
                if (b.isDefault)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text('default',
                        style: TextStyle(fontSize: 11, color: Colors.black54)),
                  ),
                IconButton(
                  tooltip: 'Rename brand',
                  icon: const Icon(Icons.edit_outlined, size: 19, color: _navy),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(6),
                  onPressed: _busy
                      ? null
                      : () async {
                          await _renameBrand(b);
                          refresh();
                        },
                ),
              ],
            ),
            // Non-default brands: hide-from-buyers + 24h soft-delete.
            if (!b.isDefault) ...[
              const Divider(height: 14),
              Row(
                children: [
                  Icon(
                      b.hiddenByStockist
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 18,
                      color: _navy),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        b.hiddenByStockist
                            ? 'Hidden from buyers'
                            : 'Visible to buyers',
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                  Switch(
                    value: !b.hiddenByStockist,
                    onChanged: _busy
                        ? null
                        : (_) async {
                            await _runBrand(() => _data.setBrandHidden(
                                b.id, !b.hiddenByStockist));
                            refresh();
                          },
                  ),
                ],
              ),
              if (b.hiddenByStockist && !b.pendingDelete)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () async {
                            await _confirmScheduleBrandDelete(b);
                            refresh();
                          },
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Delete brand'),
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                  ),
                ),
              if (b.pendingDelete)
                Container(
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFEBEE),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.timer_outlined,
                              size: 16, color: Colors.red),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                                'Scheduled for deletion · ${_deleteCountdown(b.deleteScheduledAt!)}',
                                style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.red)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      const Text(
                          'Last chance — stop now to keep this brand and all '
                          'its lists. After the timer it cannot be recovered.',
                          style:
                              TextStyle(fontSize: 11, color: Colors.black54)),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.icon(
                          onPressed: _busy
                              ? null
                              : () async {
                                  await _runBrand(
                                      () => _data.cancelBrandDelete(b.id));
                                  refresh();
                                },
                          icon: const Icon(Icons.undo, size: 16),
                          label: const Text('Keep brand'),
                          style: FilledButton.styleFrom(
                              backgroundColor: _navy,
                              visualDensity: VisualDensity.compact),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Stock lists'),
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        actions: [
          if (_lists.isNotEmpty)
            IconButton(
              tooltip: 'Share all lists',
              icon: const Icon(Icons.share),
              onPressed: _busy ? null : _shareAll,
            ),
          if (_brands.isNotEmpty)
            IconButton(
              tooltip: 'Brands',
              icon: const Icon(Icons.sell_outlined),
              onPressed: _busy ? null : _openBrandManager,
            ),
        ],
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

  // Accordion card: colored left border by type + header + link panel.
  Widget _listCard(StockCatalog c) {
    final open = _openId == c.id;
    final typeColor = c.isPermanent ? _blue : _orange;
    _daysCtrls.putIfAbsent(c.id, () => TextEditingController(text: '60'));
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.hardEdge,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Colored left border
            Container(width: 4, color: typeColor),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: () => _toggle(c.id),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
                      child: Row(
                        children: [
                          Icon(open ? Icons.expand_more : Icons.chevron_right,
                              color: _navy),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(c.name,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 14.5)),
                                    ),
                                    if (c.hiddenByStockist)
                                      Container(
                                        margin:
                                            const EdgeInsets.only(left: 6),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 7, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.grey.shade200,
                                          borderRadius:
                                              BorderRadius.circular(8),
                                          border: Border.all(
                                              color: Colors.grey.shade400,
                                              width: 0.8),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.visibility_off_outlined,
                                                size: 11,
                                                color: Colors.grey.shade700),
                                            const SizedBox(width: 3),
                                            Text('HIDDEN',
                                                style: TextStyle(
                                                    fontSize: 9.5,
                                                    fontWeight: FontWeight.bold,
                                                    color: Colors.grey.shade700,
                                                    letterSpacing: 0.3)),
                                          ],
                                        ),
                                      ),
                                    Container(
                                      margin: const EdgeInsets.only(left: 6),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 7, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: typeColor.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                            color: typeColor.withValues(alpha: 0.4),
                                            width: 0.8),
                                      ),
                                      child: Text(
                                        c.isPermanent ? 'PERMANENT' : 'TEMPORARY',
                                        style: TextStyle(
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.bold,
                                            color: typeColor,
                                            letterSpacing: 0.3),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  c.isPermanent
                                      ? [
                                          _conditionSummary(c),
                                          if (c.hasOwnBanner) 'banner ✓',
                                        ].join(' · ')
                                      : [
                                          '${_counts[c.id] ?? 0} designs',
                                          if (c.hasOwnBanner) 'banner ✓',
                                          if (c.description.trim().isNotEmpty)
                                            c.description.trim(),
                                        ].join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      color: Colors.grey.shade600),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                              tooltip: 'Banner',
                              icon: Icon(Icons.image_outlined,
                                  size: 20,
                                  color: c.hasOwnBanner
                                      ? const Color(0xFF2E7D32)
                                      : Colors.grey.shade600),
                              onPressed: () => _setBanner(c)),
                          IconButton(
                              tooltip: c.isPermanent
                                  ? 'Edit conditions'
                                  : 'Edit designs',
                              icon: Icon(
                                  c.isPermanent
                                      ? Icons.tune
                                      : Icons.edit_outlined,
                                  size: 20),
                              onPressed: () => _open(c)),
                        ],
                      ),
                    ),
                  ),
                  if (open) _linkPanel(c),
                ],
              ),
            ),
          ],
        ),
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
          _dangerZone(c),
        ],
      ),
    );
  }

  // Hide-from-buyers + 24h soft-delete for this list. Shown at the bottom of the
  // expanded panel. Deletion requires the list to be hidden first (server rule).
  Widget _dangerZone(StockCatalog c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 18),
        Row(
          children: [
            Icon(
                c.hiddenByStockist
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 18,
                color: _navy),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  c.hiddenByStockist
                      ? 'Hidden from buyers'
                      : 'Visible to buyers',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            Switch(
              value: !c.hiddenByStockist,
              onChanged: _busy || c.pendingDelete
                  ? null
                  : (_) => _runList(
                      () => _data.setListHidden(c.id, !c.hiddenByStockist)),
            ),
          ],
        ),
        if (!c.hiddenByStockist)
          Text('Hide this list first to delete it.',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        if (c.hiddenByStockist && !c.pendingDelete)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : () => _confirmScheduleListDelete(c),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Delete list'),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
            ),
          ),
        if (c.pendingDelete)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFEBEE),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.timer_outlined,
                        size: 16, color: Colors.red),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                          'Scheduled for deletion · ${_deleteCountdown(c.deleteScheduledAt!)}',
                          style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.bold,
                              color: Colors.red)),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                const Text(
                    'Last chance — stop now to keep this list and its links. '
                    'After the timer it cannot be recovered.',
                    style: TextStyle(fontSize: 11, color: Colors.black54)),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _runList(() => _data.cancelListDelete(c.id)),
                    icon: const Icon(Icons.undo, size: 16),
                    label: const Text('Keep list'),
                    style: FilledButton.styleFrom(
                        backgroundColor: _navy,
                        visualDensity: VisualDensity.compact),
                  ),
                ),
              ],
            ),
          ),
      ],
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
          description: _descCtrl.text.trim(),
          listType: 'temporary');
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

// ── Permanent list editor ─────────────────────────────────────────────────────
// Create or edit a permanent (condition-based) stock list.
// Conditions: brand (single) · quality/surface/tile_type/stock_type/size (multi) · box range.
// Empty selection = no filter (show everything for that dimension).
class PermanentListEditorScreen extends StatefulWidget {
  final StockCatalog? existing;
  final List<Brand> brands;
  const PermanentListEditorScreen(
      {super.key, this.existing, required this.brands});
  @override
  State<PermanentListEditorScreen> createState() =>
      _PermanentListEditorScreenState();
}

class _PermanentListEditorScreenState
    extends State<PermanentListEditorScreen> {
  final _data = SupabaseDataService();
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _boxMinCtrl = TextEditingController();
  final _boxMaxCtrl = TextEditingController();

  final Set<String> _filterBrandIds = {};
  final Set<String> _filterQualities = {};
  final Set<String> _filterSurfaces = {};
  final Set<String> _filterSizes = {};
  final Set<String> _filterTileTypes = {};
  final Set<String> _filterStockTypes = {};

  List<String> _sizes = [];
  bool _loadingSizes = true;
  bool _saving = false;

  static const _qualities = ['Standard', 'Premium'];
  static const _surfaces = ['Glossy', 'Matt', 'Rustic', 'P.Glossy', 'Sugar', 'Carving'];
  static const _tileTypes = ['Ceramic', 'PGVT & GVT', 'Porcelain'];
  static const _stockTypeOptions = ['Uncertain', 'One Time'];

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    _nameCtrl.text = ex?.name ?? '';
    _descCtrl.text = ex?.description ?? '';
    if (ex != null) {
      _filterBrandIds.addAll(ex.filterBrandIds);
      _filterQualities.addAll(ex.filterQualities);
      _filterSurfaces.addAll(ex.filterSurfaces);
      _filterSizes.addAll(ex.filterSizes);
      _filterTileTypes.addAll(ex.filterTileTypes);
      _filterStockTypes.addAll(ex.filterStockTypes);
      if (ex.filterBoxMin != null) _boxMinCtrl.text = ex.filterBoxMin.toString();
      if (ex.filterBoxMax != null) _boxMaxCtrl.text = ex.filterBoxMax.toString();
    }
    _loadSizes();
  }

  Future<void> _loadSizes() async {
    final designs = await _data.getDesignsByStockist(currentStockistUUID);
    final sizes = designs.map((d) => d.size).toSet().toList()..sort();
    if (!mounted) return;
    setState(() {
      _sizes = sizes;
      _loadingSizes = false;
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _boxMinCtrl.dispose();
    _boxMaxCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Give the list a name.')));
      return;
    }
    setState(() => _saving = true);
    try {
      await _data.saveStockList(
        id: widget.existing?.id,
        name: name,
        description: _descCtrl.text.trim(),
        listType: 'permanent',
        filterBrandIds: _filterBrandIds.toList(),
        filterQualities: _filterQualities.toList(),
        filterSurfaces: _filterSurfaces.toList(),
        filterSizes: _filterSizes.toList(),
        filterTileTypes: _filterTileTypes.toList(),
        filterStockTypes: _filterStockTypes.toList(),
        filterBoxMin: int.tryParse(_boxMinCtrl.text.trim()),
        filterBoxMax: int.tryParse(_boxMaxCtrl.text.trim()),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save — $e')));
    }
  }

  // Multi-select FilterChip (no "All" chip; empty = show all).
  Widget _multiChipGroup(
    String title,
    List<String> options,
    Set<String> selected,
    String Function(String) label,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: options
              .map((o) => FilterChip(
                    label: Text(label(o),
                        style: TextStyle(
                            fontSize: 12,
                            color:
                                selected.contains(o) ? _blue : Colors.black87)),
                    selected: selected.contains(o),
                    onSelected: (v) => setState(
                        () => v ? selected.add(o) : selected.remove(o)),
                    selectedColor: _blue.withValues(alpha: 0.15),
                    checkmarkColor: _blue,
                    visualDensity: VisualDensity.compact,
                  ))
              .toList(),
        ),
      ],
    );
  }

  Widget _boxRangeRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Box range (F stock)',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _boxMinCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Min boxes',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('–', style: TextStyle(fontSize: 18)),
            ),
            Expanded(
              child: TextField(
                controller: _boxMaxCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Max boxes',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(isEdit ? 'Edit conditions' : 'New permanent list'),
        backgroundColor: _blue,
        foregroundColor: Colors.white,
        actions: [
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
                          color: Colors.white,
                          fontWeight: FontWeight.bold))),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          // Name + description
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                children: [
                  TextField(
                    controller: _nameCtrl,
                    autofocus: !isEdit,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                        labelText: 'List name',
                        border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _descCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Description (optional)',
                        border: OutlineInputBorder()),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 4, 4, 6),
            child: Row(
              children: [
                Icon(Icons.auto_awesome, size: 15, color: _blue),
                SizedBox(width: 6),
                Text('Auto-filter conditions',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13.5)),
                SizedBox(width: 8),
                Text('leave empty to include everything',
                    style: TextStyle(fontSize: 11, color: Colors.black45)),
              ],
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.brands.isNotEmpty) ...[
                    _multiChipGroup(
                      'Brand',
                      widget.brands.map((b) => b.id).toList(),
                      _filterBrandIds,
                      (id) =>
                          widget.brands.firstWhere((b) => b.id == id).name,
                    ),
                    const Divider(height: 22),
                  ],
                  _multiChipGroup('Quality', _qualities, _filterQualities,
                      (q) => q),
                  const Divider(height: 22),
                  _multiChipGroup('Surface', _surfaces, _filterSurfaces,
                      (s) => s),
                  const Divider(height: 22),
                  _multiChipGroup('Tile type', _tileTypes, _filterTileTypes,
                      (t) => t),
                  const Divider(height: 22),
                  _multiChipGroup('Stock type', _stockTypeOptions,
                      _filterStockTypes, (t) => t),
                  const Divider(height: 22),
                  if (_loadingSizes)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Center(
                          child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2))),
                    )
                  else
                    _multiChipGroup('Size', _sizes, _filterSizes,
                        (s) => s.replaceAll(' mm', '')),
                  const Divider(height: 22),
                  _boxRangeRow(),
                ],
              ),
            ),
          ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }
}
