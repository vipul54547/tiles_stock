import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../config/app_config.dart';
import '../../models/choice_state.dart';
import '../../models/brand.dart';
import '../../models/stock_catalog.dart';
import '../../models/claimed_catalog.dart';
import '../../models/share_link.dart';
import '../../models/tile_design.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';

/// Stockist's stock lists, grouped by brand. Each brand is a collapsible box
/// (first one open) holding up to the admin-set `stock_list_limit` named lists
/// (default: Premium / Standard / OneTime). A design is assigned to exactly one
/// list at upload time; each list is shared by its own Permanent or Custom link.
class ManageCatalogsScreen extends StatefulWidget {
  const ManageCatalogsScreen({super.key});
  @override
  State<ManageCatalogsScreen> createState() => _State();
}

// ── Colour scheme — nesting is colour-coded so the parts read at a glance ────
const _navy = Color(0xFF1B4F72); // brand accent / primary
const _brandBg = Color(0xFFE8F0FE); // brand box background (blue family)
const _brandBorder = Color(0xFF1B4F72);
const _amberBg = Color(0xFFFFF8E1); // "make custom link" zone (amber)
const _greenBg = Color(0xFFE8F5E9); // a live generated link (green)
const _green = Color(0xFF2E7D32);

// Each stock list gets its OWN background colour (cycled by position) so several
// lists in a brand are easy to tell apart. Hues avoid the amber custom zone +
// green link rows nested inside, so those still stand out.
const _listPalette = <({Color bg, Color border})>[
  (bg: Color(0xFFE0F2F1), border: Color(0xFF00897B)), // teal
  (bg: Color(0xFFF3E5F5), border: Color(0xFF8E24AA)), // purple
  (bg: Color(0xFFFCE4EC), border: Color(0xFFD81B60)), // pink
  (bg: Color(0xFFE8EAF6), border: Color(0xFF3949AB)), // indigo
  (bg: Color(0xFFEFEBE9), border: Color(0xFF6D4C41)), // brown
  (bg: Color(0xFFECEFF1), border: Color(0xFF546E7A)), // blue-grey
];

class _State extends State<ManageCatalogsScreen> {
  final _data = SupabaseDataService();
  List<StockCatalog> _items = [];
  List<Brand> _brands = [];
  Map<String, int> _inq = {}; // catalogId → link-enquiry count
  Map<String, List<CatalogClaimer>> _claimers = {}; // catalogId → dealers joined
  Map<String, List<ShareLink>> _catLinks = {}; // catalogId → its share links
  Map<String, List<TileDesign>> _designsByCat = {}; // catalogId → its designs
  final Map<String, TextEditingController> _daysCtrls = {}; // per-list days box
  final Set<String> _expandedBrands = {}; // collapsible brand boxes (open set)
  final Set<String> _customOpen = {}; // per-list "make custom link" expanded

  // Max ACTIVE (non-expired) custom links allowed per stock list. Keeps the
  // links panel from ballooning and nudges the stockist to reuse live links.
  static const int _maxActiveLinks = 4;
  // The stockist's admin-set cap on active stock lists per brand (default 3).
  // Gates the per-brand "Add stock list" action; the server enforces it too.
  int _listLimit = 3;
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
    final items = await _data.getCatalogs(currentStockistUUID);
    final brands = await _data.getMyBrands();
    final listLimit = await _data.myStockListLimit();
    final inq = await _data.getCatalogInquiryCounts(currentStockistUUID);
    final claimerList = await _data.getMyCatalogClaimers();
    final allDesigns = await _data.getDesignsByStockist(currentStockistUUID);
    final claimers = <String, List<CatalogClaimer>>{};
    for (final c in claimerList) {
      (claimers[c.catalogId] ??= []).add(c);
    }
    // A design can be published in several lists now (membership), so bucket it
    // under each list it belongs to. (stocklist-output)
    final byCat = <String, List<TileDesign>>{};
    for (final d in allDesigns) {
      for (final cid in d.catalogIds) {
        (byCat[cid] ??= []).add(d);
      }
    }
    // Each list's share links (permanent + timed), fetched in parallel.
    final linkLists = await Future.wait(
        items.map((it) => _data.getCatalogShareLinks(it.id)));
    final catLinks = <String, List<ShareLink>>{
      for (var i = 0; i < items.length; i++) items[i].id: linkLists[i]
    };
    if (!mounted) return;
    setState(() {
      _items = items;
      _brands = brands;
      _listLimit = listLimit;
      _inq = inq;
      _claimers = claimers;
      _catLinks = catLinks;
      _designsByCat = byCat;
      // Open the first brand by default; keep any the user already toggled open.
      if (_expandedBrands.isEmpty && brands.isNotEmpty) {
        _expandedBrands.add(brands.first.id);
      }
      _loading = false;
    });
  }

  /// Lists belonging to a brand, in display order.
  List<StockCatalog> _listsFor(String brandId) =>
      _items.where((c) => c.brandId == brandId).toList();

  // ── Brand rename ──────────────────────────────────────────────────────────
  // Brands are created by the admin; the stockist can only rename them here.
  Future<void> _renameBrandDialog(Brand b) async {
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
    if (ok != true || name.isEmpty || name == b.name) return;
    await _run(() => _data.renameBrand(b.id, name));
  }

  // ── Stock list create / rename / delete ──────────────────────────────────
  // Stockist creates a new stock list inside a brand (up to [_listLimit] active
  // lists per brand; the server enforces the cap, empty/duplicate names too).
  Future<void> _createListDialog(Brand b) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('New stock list — ${b.name}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
              hintText: 'List name (e.g. Premium, Floor Tiles)',
              border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Create')),
        ],
      ),
    );
    final name = ctrl.text.trim();
    if (ok != true || name.isEmpty) return;
    await _run(() => _data.createStockList(b.id, name));
  }

  Future<void> _renameDialog(StockCatalog c) async {
    final ctrl = TextEditingController(text: c.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename stock list'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
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
    if (ok == true) await _run(() => _data.renameCatalog(c.id, ctrl.text));
  }

  Future<void> _run(Future<void> Function() action) async {
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

  // ── Links ────────────────────────────────────────────────────────────────
  // Path form (NOT hash) so WhatsApp/social crawlers can read the token and the
  // Netlify edge function can serve a branded per-stockist preview card.
  String _urlFor(String token) => '${AppConfig.shareBaseUrl}/s/$token';

  Future<void> _copyToken(String token) async {
    await Clipboard.setData(ClipboardData(text: _urlFor(token)));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Link copied.')));
    }
  }

  Future<void> _shareToken(String name, String token) async {
    final text = '$name: ${_urlFor(token)}\n\nPowered by Tiles Stock';
    await launchUrl(Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}'),
        mode: LaunchMode.externalApplication);
  }

  // Brand-level "Share all links": bundle every list in this brand into one
  // message. First asks Permanent or Custom-days — Custom mints a fresh timed
  // link (same validity) for each list, then shares them all together.
  Future<void> _shareAllForBrand(Brand b) async {
    final lists = _listsFor(b.id);
    if (lists.isEmpty) return;
    final daysCtrl = TextEditingController(text: '60');
    bool permanent = true;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text('Share all — ${b.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Sends the link of all ${lists.length} list'
                  '${lists.length == 1 ? '' : 's'} in this brand.',
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
            ElevatedButton(
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
      for (final c in lists) {
        entries.add('${c.name}: ${_urlFor(c.shareToken)}');
      }
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
      for (final c in lists) {
        final token = await _data.createCatalogShareLinkDays(c.id, days);
        if (token != null) entries.add('${c.name}: ${_urlFor(token)}');
      }
      await _load();
      if (mounted) setState(() => _busy = false);
    }
    if (permanent) daysCtrl.dispose();
    if (entries.isEmpty) return;
    // Anonymity: the default brand is named after the real company, so when the
    // stockist is anonymous show the masked trade name instead — never leak the
    // real name in the outgoing message. Real (non-default) brands still show.
    final header = (currentStockistIsAnonymous &&
            b.isDefault &&
            currentStockistDisplayName.isNotEmpty)
        ? currentStockistDisplayName
        : b.name;
    final text = '$header\n${entries.join('\n')}\n\nPowered by Tiles Stock';
    await launchUrl(Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}'),
        mode: LaunchMode.externalApplication);
  }

  Future<void> _reloadLinks(String catalogId) async {
    final l = await _data.getCatalogShareLinks(catalogId);
    if (!mounted) return;
    setState(() => _catLinks[catalogId] = l);
  }

  // Generate a custom-days link for one list from its days text box.
  Future<void> _generateDays(String catalogId, TextEditingController ctrl) async {
    final days = int.tryParse(ctrl.text.trim());
    if (days == null || days < 1) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enter the number of days (1 or more).')));
      return;
    }
    // Per-list cap of [_maxActiveLinks] active custom links (server enforces too).
    final liveCount = (_catLinks[catalogId] ?? const <ShareLink>[])
        .where((l) => l.revocable && !l.expired)
        .length;
    if (liveCount >= _maxActiveLinks) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('You already have $_maxActiveLinks active links for '
              'this list. Reuse one, or delete one / let it expire first.')));
      return;
    }
    setState(() => _busy = true);
    final token = await _data.createCatalogShareLinkDays(catalogId, days);
    if (token != null) {
      ctrl.text = '60'; // reset to the default
      await _reloadLinks(catalogId);
    }
    if (!mounted) return;
    if (token == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not create link.'),
          backgroundColor: Colors.red));
    }
    setState(() => _busy = false);
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  String _fmtDate(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

  // ── Preview designs in a list (read-only thumbnail grid) ──────────────────
  Future<void> _previewDesigns(StockCatalog c) async {
    final designs = _designsByCat[c.id] ?? const <TileDesign>[];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (ctx, scroll) => Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              Text('${c.name} — ${designs.length} design'
                  '${designs.length == 1 ? '' : 's'}',
                  style:
                      const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              Expanded(
                child: designs.isEmpty
                    ? const Center(
                        child: Text('No designs in this list yet.',
                            style: TextStyle(color: Colors.grey)))
                    : GridView.builder(
                        controller: scroll,
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          childAspectRatio: 0.72,
                        ),
                        itemCount: designs.length,
                        itemBuilder: (_, i) => _previewCard(designs[i]),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _previewCard(TileDesign d) {
    final img = d.faceImageUrls.isNotEmpty ? d.faceImageUrls.first : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: img.isEmpty
                ? Container(
                    color: Colors.grey.shade100,
                    child: Icon(Icons.image_not_supported,
                        color: Colors.grey.shade400))
                : CachedNetworkImage(
                    imageUrl: CloudinaryService.thumbUrl(img, width: 300),
                    fit: BoxFit.cover,
                    width: double.infinity,
                    placeholder: (_, __) =>
                        Container(color: Colors.grey.shade200),
                    errorWidget: (_, __, ___) =>
                        Container(color: Colors.grey.shade200),
                  ),
          ),
        ),
        const SizedBox(height: 3),
        Text(d.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
        Text('${d.boxQuantity} boxes',
            style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
      ],
    );
  }

  // Dealers (buyers) who saved this list into their app, with a revoke action.
  Future<void> _showClaimers(StockCatalog c) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final list = _claimers[c.id] ?? const <CatalogClaimer>[];
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Text('Dealers in "${c.name}"',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 2),
                  Text('${list.length} dealer${list.length == 1 ? '' : 's'} saved this list',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  const SizedBox(height: 10),
                  if (list.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(child: Text('No dealers yet.')),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: list.length,
                        separatorBuilder: (_, __) =>
                            Divider(height: 1, color: Colors.grey.shade200),
                        itemBuilder: (_, i) {
                          final d = list[i];
                          final sub = [
                            if (d.contact.isNotEmpty) d.contact,
                            if (d.city.isNotEmpty) d.city,
                          ].join(' · ');
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                                d.company.isEmpty ? d.contact : d.company,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 14)),
                            subtitle: sub.isEmpty
                                ? null
                                : Text(sub,
                                    style: const TextStyle(fontSize: 12)),
                            trailing: TextButton(
                              onPressed: () async {
                                final yes = await showDialog<bool>(
                                  context: ctx,
                                  builder: (dctx) => AlertDialog(
                                    title: const Text('Remove dealer?'),
                                    content: Text(
                                        'Remove ${d.company.isEmpty ? d.contact : d.company} from "${c.name}"? '
                                        'They will lose access to this list in their app.'),
                                    actions: [
                                      TextButton(
                                          onPressed: () =>
                                              Navigator.pop(dctx, false),
                                          child: const Text('Cancel')),
                                      TextButton(
                                          onPressed: () =>
                                              Navigator.pop(dctx, true),
                                          child: const Text('Remove',
                                              style: TextStyle(
                                                  color: Colors.red))),
                                    ],
                                  ),
                                );
                                if (yes != true) return;
                                try {
                                  await _data.revokeCatalogAccess(
                                      c.id, d.endUserId);
                                  _claimers[c.id]?.removeWhere(
                                      (x) => x.endUserId == d.endUserId);
                                  setSheet(() {});
                                  if (mounted) setState(() {});
                                } catch (e) {
                                  if (ctx.mounted) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                        SnackBar(
                                            content: Text('$e'),
                                            backgroundColor: Colors.red));
                                  }
                                }
                              },
                              child: const Text('Remove',
                                  style: TextStyle(color: Colors.red)),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Stock Lists')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(
                  12, 10, 12, 24 + MediaQuery.viewPaddingOf(context).bottom),
              children: [
                _createBrandCard(),
                const SizedBox(height: 12),
                for (final b in _brands) ...[
                  _brandBox(b),
                  const SizedBox(height: 12),
                ],
                if (_brands.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                        child: Text('No brand yet — contact the admin to enable one.',
                            style: TextStyle(color: Colors.grey))),
                  ),
              ],
            ),
    );
  }

  // Brands are created by the admin (who sets how many you may have); a new brand
  // appears here automatically. So this is just a note, not an action.
  Widget _createBrandCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: const ListTile(
        leading: Icon(Icons.info_outline, color: _navy),
        title: Text('You want to create a new brand? Contact admin.',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        subtitle: Text(
            'When the admin allows another brand, it appears here automatically — '
            'just rename it with the pencil.',
            style: TextStyle(fontSize: 12)),
      ),
    );
  }

  // A collapsible BRAND box (blue family). Header = name + Share-all + chevron;
  // expanded body = list count / add, then each stock-list box.
  Widget _brandBox(Brand b) {
    final lists = _listsFor(b.id);
    final open = _expandedBrands.contains(b.id);
    final activeLinks = lists.fold<int>(
        0,
        (n, c) =>
            n +
            (_catLinks[c.id] ?? const <ShareLink>[])
                .where((l) => l.revocable && !l.expired)
                .length);

    return Container(
      decoration: BoxDecoration(
        color: _brandBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _brandBorder, width: 1.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Collapsible header.
          InkWell(
            borderRadius: BorderRadius.circular(14),
            // Accordion: only one brand open at a time — opening one closes the rest.
            onTap: () => setState(() {
              _expandedBrands.clear();
              if (!open) _expandedBrands.add(b.id);
            }),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
              child: Row(
                children: [
                  Icon(open ? Icons.expand_more : Icons.chevron_right,
                      color: _navy),
                  const Icon(Icons.sell, size: 18, color: _navy),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(b.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                color: _navy)),
                        if (b.inCorrection)
                          Container(
                            margin: const EdgeInsets.only(top: 2),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFF3E0),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: const Color(0xFFFFB74D)),
                            ),
                            child: const Text(
                                '⚠ In correction — hidden from buyers. Fix the '
                                'design images.',
                                style: TextStyle(
                                    fontSize: 10.5,
                                    color: Color(0xFFE65100),
                                    fontWeight: FontWeight.w600)),
                          ),
                        if (b.pendingDelete)
                          _miniBadge('⏳ Deletes in ${_deleteCountdown(b.deleteScheduledAt!)}',
                              const Color(0xFFFFEBEE), Colors.red)
                        else if (b.hiddenByStockist)
                          _miniBadge('🚫 Hidden from buyers',
                              const Color(0xFFEEEEEE), Colors.black54),
                        if (!open)
                          Text(
                              '${lists.length} list${lists.length == 1 ? '' : 's'}'
                              '${activeLinks > 0 ? ' · $activeLinks active link${activeLinks == 1 ? '' : 's'}' : ''}',
                              style: TextStyle(
                                  fontSize: 11.5, color: Colors.grey.shade700)),
                      ],
                    ),
                  ),
                  if (lists.isNotEmpty)
                    TextButton.icon(
                      onPressed: _busy ? null : () => _shareAllForBrand(b),
                      icon: const Icon(Icons.share, size: 16),
                      label: const Text('Share all links',
                          style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(
                          foregroundColor: _navy,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 34),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    ),
                  IconButton(
                    tooltip: 'Rename brand',
                    icon: const Icon(Icons.edit_outlined, size: 18, color: _navy),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(6),
                    onPressed: _busy ? null : () => _renameBrandDialog(b),
                  ),
                ],
              ),
            ),
          ),
          if (open) ...[
            // List count + "Add stock list". A stockist may create up to
            // [_listLimit] ACTIVE lists per brand (server-enforced); past that the
            // Add button is disabled with an "ask admin" hint. The default brand
            // also gets the action — only deletion/hide stays default-brand-gated.
            _brandListHeader(b, lists),
            if (lists.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(14, 0, 14, 12),
                child: Text(
                    'No stock lists yet — tap “Add stock list” to create one.',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Column(
                  children: [
                    for (final e in lists.asMap().entries)
                      _listBox(e.value, e.key)
                  ],
                ),
              ),
            // Stockist-side brand visibility + deletion (non-default only).
            if (!b.isDefault) _brandAdminControls(b),
          ],
        ],
      ),
    );
  }

  // Header row inside an open brand box: "<active> of <limit> lists" + the
  // "Add stock list" action. Disabled (with an ask-admin hint) at the cap, or
  // while a brand deletion is pending.
  Widget _brandListHeader(Brand b, List<StockCatalog> lists) {
    final activeCount = lists.where((c) => c.isActive).length;
    final atCap = activeCount >= _listLimit;
    final canAdd = !atCap && !b.pendingDelete && !_busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
                '$activeCount of $_listLimit stock list'
                '${_listLimit == 1 ? '' : 's'}'
                '${atCap ? ' · limit reached — ask admin for more' : ''}',
                style: TextStyle(
                    fontSize: 12,
                    color: atCap ? Colors.orange.shade800 : Colors.grey.shade700)),
          ),
          TextButton.icon(
            onPressed: canAdd ? () => _createListDialog(b) : null,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add stock list', style: TextStyle(fontSize: 12.5)),
            style: TextButton.styleFrom(
                foregroundColor: _navy,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 34),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          ),
        ],
      ),
    );
  }

  // A tiny coloured status pill used in the brand header.
  Widget _miniBadge(String text, Color bg, Color fg) => Container(
        margin: const EdgeInsets.only(top: 2),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
        child: Text(text,
            style: TextStyle(
                fontSize: 10.5, color: fg, fontWeight: FontWeight.w600)),
      );

  // Hide/show toggle, the Delete button (only once hidden), and the 24h deletion
  // countdown with a "Keep brand" stop. Default brand never reaches here.
  Widget _brandAdminControls(Brand b) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                onChanged: _busy ? null : (_) => _toggleBrandHidden(b),
              ),
            ],
          ),
          if (b.hiddenByStockist && !b.pendingDelete)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _busy ? null : () => _confirmScheduleDelete(b),
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
                      'Last chance — stop now to keep this brand and all its '
                      'lists. After the timer it cannot be recovered.',
                      style: TextStyle(fontSize: 11, color: Colors.black54)),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed:
                          _busy ? null : () => _cancelScheduledDelete(b),
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
      ),
    );
  }

  // Brand hide/show + scheduled-delete handlers.
  Future<void> _toggleBrandHidden(Brand b) =>
      _run(() => _data.setBrandHidden(b.id, !b.hiddenByStockist));

  Future<void> _confirmScheduleDelete(Brand b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this brand?'),
        content: Text(
            'Deleting "${b.name}" removes the brand, its stock lists and all '
            'their share links. This CANNOT be undone.\n\n'
            'For safety it happens after a 24-hour wait — you can stop it any '
            'time within that window.'),
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
    await _run(() async {
      await _data.scheduleBrandDelete(b.id);
    });
  }

  Future<void> _cancelScheduledDelete(Brand b) =>
      _run(() => _data.cancelBrandDelete(b.id));

  // Time left before a scheduled brand/list deletion fires (24h after it was set).
  String _deleteCountdown(DateTime scheduledAt) {
    final left =
        scheduledAt.add(const Duration(hours: 24)).difference(DateTime.now());
    if (left.isNegative) return 'deleting now…';
    final h = left.inHours;
    final m = left.inMinutes % 60;
    return h > 0 ? '${h}h ${m}m left' : '${m}m left';
  }

  // ── Stock-list hide / scheduled-delete (same provision as brands) ──────────
  Future<void> _toggleListHidden(StockCatalog c) =>
      _run(() => _data.setListHidden(c.id, !c.hiddenByStockist));

  Future<void> _confirmScheduleListDelete(StockCatalog c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this stock list?'),
        content: Text(
            'Deleting "${c.name}" removes the list, its designs/stock and its '
            'share links. This CANNOT be undone.\n\n'
            'For safety it happens after a 24-hour wait — you can stop it any '
            'time within that window. A fresh empty list takes its place.'),
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
    await _run(() async {
      await _data.scheduleListDelete(c.id);
    });
  }

  Future<void> _cancelListDelete(StockCatalog c) =>
      _run(() => _data.cancelListDelete(c.id));

  // The red "scheduled for deletion · Nh left + Keep list" banner inside a list.
  Widget _listDeleteCountdown(StockCatalog c) => Container(
        margin: const EdgeInsets.fromLTRB(0, 6, 6, 2),
        padding: const EdgeInsets.all(8),
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
                const Icon(Icons.timer_outlined, size: 15, color: Colors.red),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                      'Deletes in ${_deleteCountdown(c.deleteScheduledAt!)} — last chance to stop.',
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.bold,
                          color: Colors.red)),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _busy ? null : () => _cancelListDelete(c),
                icon: const Icon(Icons.undo, size: 15),
                label: const Text('Keep list'),
                style: FilledButton.styleFrom(
                    backgroundColor: _navy,
                    visualDensity: VisualDensity.compact),
              ),
            ),
          ],
        ),
      );

  // A STOCK-LIST box nested inside its brand box. Each list gets its own colour
  // from [_listPalette], cycled by its position in the brand.
  Widget _listBox(StockCatalog c, int index) {
    final pal = _listPalette[index % _listPalette.length];
    final dealers = _claimers[c.id]?.length ?? 0;
    final enq = _inq[c.id] ?? 0;
    // Only ACTIVE (non-expired) custom links are shown — expired links are
    // auto-hidden (they already stop working everywhere; the row stays in the DB
    // for records). Capped at [_maxActiveLinks] so the panel can't balloon.
    final liveLinks = (_catLinks[c.id] ?? const <ShareLink>[])
        .where((l) => l.revocable && !l.expired)
        .toList();
    final atLinkCap = liveLinks.length >= _maxActiveLinks;
    final customOpen = _customOpen.contains(c.id);
    final ctrl =
        _daysCtrls.putIfAbsent(c.id, () => TextEditingController(text: '60'));

    return Opacity(
      opacity: c.isActive ? 1 : 0.55,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: pal.bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: pal.border, width: 1.1),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Name + 4 actions: grid preview / edit / delete / hide-show.
              Row(
                children: [
                  Expanded(
                    child: Text(c.name,
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14.5,
                            color: pal.border)),
                  ),
                  if (c.hiddenByStockist && !c.pendingDelete)
                    Container(
                      margin: const EdgeInsets.only(right: 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.grey.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: const Text('HIDDEN',
                          style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey)),
                    ),
                  _rowIcon(Icons.grid_view_rounded, 'Preview designs', pal.border,
                      () => _previewDesigns(c)),
                  _rowIcon(Icons.edit_outlined, 'Rename', _navy,
                      _busy ? null : () => _renameDialog(c)),
                  _rowIcon(
                      c.hiddenByStockist
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      c.hiddenByStockist ? 'Show list' : 'Hide list',
                      Colors.grey.shade700,
                      _busy ? null : () => _toggleListHidden(c)),
                  // Delete appears only once the list is hidden (parallel to brands).
                  if (c.hiddenByStockist && !c.pendingDelete)
                    _rowIcon(Icons.delete_outline, 'Delete list', Colors.red,
                        _busy ? null : () => _confirmScheduleListDelete(c)),
                ],
              ),
              if (c.pendingDelete) _listDeleteCountdown(c),
              // Info line: enquiries + dealers (dealers tappable).
              if (enq > 0 || dealers > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 6, bottom: 2),
                  child: Row(
                    children: [
                      if (enq > 0)
                        Text('$enq enquir${enq == 1 ? 'y' : 'ies'} via link',
                            style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: _navy)),
                      if (enq > 0 && dealers > 0)
                        Text('  ·  ',
                            style: TextStyle(color: Colors.grey.shade500)),
                      if (dealers > 0)
                        InkWell(
                          onTap: () => _showClaimers(c),
                          child: Text('Dealers ($dealers)',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: pal.border,
                                  decoration: TextDecoration.underline)),
                        ),
                    ],
                  ),
                ),
              // "Show in Discover" — per-list public-market visibility. Only
              // appears once the super admin has taken the public market live;
              // default off, so nothing is public without intent. (Phase 2 #8 —
              // project_two_mode_marketplace.) Same stock, no second upload.
              if (publicMarketLive)
                Container(
                  margin: const EdgeInsets.only(top: 6, right: 4),
                  padding: const EdgeInsets.fromLTRB(8, 0, 4, 0),
                  decoration: BoxDecoration(
                    color: c.showInMarketplace
                        ? _greenBg
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                          c.showInMarketplace
                              ? Icons.travel_explore
                              : Icons.lock_outline,
                          size: 16,
                          color: c.showInMarketplace
                              ? _green
                              : Colors.grey.shade600),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                            c.showInMarketplace
                                ? 'Shown in Discover (public market)'
                                : 'Private — link only',
                            style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: c.showInMarketplace
                                    ? _green
                                    : Colors.grey.shade700)),
                      ),
                      Switch(
                        value: c.showInMarketplace,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        activeThumbColor: _green,
                        onChanged: _busy
                            ? null
                            : (v) => _run(
                                () => _data.setCatalogMarketplace(c.id, v)),
                      ),
                    ],
                  ),
                ),
              // Per-list anonymity. Only for admin-eligible stockists, and only
              // on Discover lists (a private/link-only list always shows the real
              // name — the buyer reached it directly). Lets a stockist keep one
              // public list under their real brand while dumping another publicly
              // under the masked identity. (project_anonymity_market_gate)
              if (publicMarketLive &&
                  currentStockistAnonymityEligible &&
                  c.showInMarketplace)
                Container(
                  margin: const EdgeInsets.only(top: 6, right: 4),
                  padding: const EdgeInsets.fromLTRB(8, 0, 4, 0),
                  decoration: BoxDecoration(
                    color: c.isAnonymous
                        ? const Color(0xFFEDE7F6)
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                          c.isAnonymous
                              ? Icons.theater_comedy
                              : Icons.badge_outlined,
                          size: 16,
                          color: c.isAnonymous
                              ? const Color(0xFF673AB7)
                              : Colors.grey.shade600),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                            c.isAnonymous
                                ? 'Anonymous — shown as "$currentStockistDisplayName"'
                                : 'Shown under your real name',
                            style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: c.isAnonymous
                                    ? const Color(0xFF673AB7)
                                    : Colors.grey.shade700)),
                      ),
                      Switch(
                        value: c.isAnonymous,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        activeThumbColor: const Color(0xFF673AB7),
                        onChanged: _busy
                            ? null
                            : (v) => _run(
                                () => _data.setCatalogAnonymous(c.id, v)),
                      ),
                    ],
                  ),
                ),
              const Divider(height: 12),
              // Permanent link row.
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Row(
                  children: [
                    const Icon(Icons.link, size: 16, color: _navy),
                    const SizedBox(width: 5),
                    const Expanded(
                      child: Text('Permanent Link',
                          style: TextStyle(
                              fontSize: 12.5, fontWeight: FontWeight.w600)),
                    ),
                    _miniBtn(Icons.copy, 'Copy', _busy ? null : () => _copyToken(c.shareToken)),
                    _miniBtn(Icons.share, 'Share',
                        _busy ? null : () => _shareToken(c.name, c.shareToken)),
                  ],
                ),
              ),
              // Make your Custom Link (amber zone, expandable).
              const SizedBox(height: 6),
              InkWell(
                onTap: () => setState(() {
                  if (customOpen) {
                    _customOpen.remove(c.id);
                  } else {
                    _customOpen.add(c.id);
                  }
                }),
                child: Row(
                  children: [
                    Icon(customOpen ? Icons.expand_more : Icons.chevron_right,
                        size: 18, color: Colors.orange.shade800),
                    Icon(Icons.more_time, size: 15, color: Colors.orange.shade800),
                    const SizedBox(width: 4),
                    Text('Make your Custom Link',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.orange.shade900)),
                  ],
                ),
              ),
              if (customOpen)
                Container(
                  margin: const EdgeInsets.only(top: 6, right: 4),
                  padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                  decoration: BoxDecoration(
                    color: _amberBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.shade200),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Text('Custom',
                              style: TextStyle(
                                  fontSize: 12.5, fontWeight: FontWeight.w500)),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 54,
                            child: TextField(
                              controller: ctrl,
                              keyboardType: TextInputType.number,
                              textAlign: TextAlign.center,
                              decoration: const InputDecoration(
                                  isDense: true,
                                  filled: true,
                                  fillColor: Colors.white,
                                  contentPadding: EdgeInsets.symmetric(
                                      vertical: 6, horizontal: 4),
                                  border: OutlineInputBorder()),
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Text('days', style: TextStyle(fontSize: 12)),
                          const Spacer(),
                          ElevatedButton(
                            onPressed: (_busy || atLinkCap)
                                ? null
                                : () => _generateDays(c.id, ctrl),
                            style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.orange.shade800,
                                foregroundColor: Colors.white,
                                visualDensity: VisualDensity.compact,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 14)),
                            child: const Text('Generate',
                                style: TextStyle(fontSize: 12)),
                          ),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                            atLinkCap
                                ? 'You have $_maxActiveLinks active links (the '
                                    'max). Reuse one above, or delete one / let '
                                    'it expire before making a new one.'
                                : 'Tip: the days count starts now — generate the '
                                    'link just before you send it.',
                            style: TextStyle(
                                fontSize: 10.5,
                                color: atLinkCap
                                    ? Colors.red.shade700
                                    : Colors.black54,
                                fontStyle: FontStyle.italic)),
                      ),
                    ],
                  ),
                ),
              // Live generated links (with remaining days). Expired links are
              // auto-hidden (kept in the DB, just not shown).
              for (final l in liveLinks) _liveLinkRow(c, l),
            ],
          ),
        ),
      ),
    );
  }

  // A live generated link (green): expiry + remaining days + Share/Copy/Delete.
  // Delete here is a deliberate early-revoke; expiry handles the rest on its own.
  Widget _liveLinkRow(StockCatalog c, ShareLink l) {
    final exp = l.expiresAt;
    String status;
    if (exp == null) {
      status = 'Never expires';
    } else {
      final diff = exp.difference(DateTime.now());
      if (diff.inHours < 24) {
        status = 'Expires ${_fmtDate(exp)} · expires today';
      } else {
        final d = (diff.inHours / 24).ceil();
        status = 'Expires ${_fmtDate(exp)} · $d days left';
      }
    }
    return Container(
      margin: const EdgeInsets.only(top: 6, right: 4),
      padding: const EdgeInsets.fromLTRB(8, 2, 2, 2),
      decoration: BoxDecoration(
        color: _greenBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.schedule, size: 15, color: _green),
          const SizedBox(width: 6),
          Expanded(
            child: Text(status,
                style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: _green)),
          ),
          _miniBtn(Icons.share, 'Share', () => _shareToken(c.name, l.token)),
          _miniBtn(Icons.copy, 'Copy', () => _copyToken(l.token)),
          _miniBtn(Icons.delete_outline, 'Delete',
              _busy ? null : () => _deleteLink(c, l), color: Colors.red),
        ],
      ),
    );
  }

  // Collapsed "Show expired (N)" peek — expired links are kept for records only.
  Future<void> _deleteLink(StockCatalog c, ShareLink l) async {
    if (l.id == null) return;
    final ok = await _data.revokeShareLink(l.id!);
    if (ok) await _reloadLinks(c.id);
  }

  // Compact action icon used in the stock-list name row.
  Widget _rowIcon(
          IconData icon, String tip, Color color, VoidCallback? onTap) =>
      IconButton(
        tooltip: tip,
        icon: Icon(icon, size: 20, color: onTap == null ? Colors.grey.shade400 : color),
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(),
        padding: const EdgeInsets.all(6),
        onPressed: onTap,
      );

  // Compact text-ish button used in link rows.
  Widget _miniBtn(IconData icon, String label, VoidCallback? onTap,
          {Color color = _navy}) =>
      TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 11.5)),
        style: TextButton.styleFrom(
            foregroundColor: color,
            padding: const EdgeInsets.symmetric(horizontal: 5),
            minimumSize: const Size(0, 30),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      );
}
