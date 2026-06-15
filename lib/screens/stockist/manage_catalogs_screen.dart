import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
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
  int _listLimit = 3; // admin-set stock lists allowed per brand
  Map<String, int> _inq = {}; // catalogId → link-enquiry count
  Map<String, List<CatalogClaimer>> _claimers = {}; // catalogId → dealers joined
  Map<String, List<ShareLink>> _catLinks = {}; // catalogId → its share links
  Map<String, List<TileDesign>> _designsByCat = {}; // catalogId → its designs
  final Map<String, TextEditingController> _daysCtrls = {}; // per-list days box
  final Set<String> _expandedBrands = {}; // collapsible brand boxes (open set)
  final Set<String> _customOpen = {}; // per-list "make custom link" expanded
  final Set<String> _showExpired = {}; // per-list "show expired links" revealed
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
    final limit = await _data.myStockListLimit();
    final inq = await _data.getCatalogInquiryCounts(currentStockistUUID);
    final claimerList = await _data.getMyCatalogClaimers();
    final allDesigns = await _data.getDesignsByStockist(currentStockistUUID);
    final claimers = <String, List<CatalogClaimer>>{};
    for (final c in claimerList) {
      (claimers[c.catalogId] ??= []).add(c);
    }
    final byCat = <String, List<TileDesign>>{};
    for (final d in allDesigns) {
      if (d.catalogId != null) (byCat[d.catalogId!] ??= []).add(d);
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
      _listLimit = limit;
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

  // ── Brand create ────────────────────────────────────────────────────────
  Future<void> _createBrandDialog() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create your brand'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
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
              child: const Text('Create')),
        ],
      ),
    );
    if (ok != true || ctrl.text.trim().isEmpty) return;
    // Server enforces the admin-set brand_limit and throws if exceeded.
    await _run(() async {
      final id = await _data.createBrand(ctrl.text.trim());
      _expandedBrands.add(id); // open the new brand
    });
  }

  // ── Stock list create / rename / delete ──────────────────────────────────
  Future<void> _newListDialog(Brand brand) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('New stock list — ${brand.name}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
              hintText: 'e.g. Clearance, Festival',
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
    if (ok != true || ctrl.text.trim().isEmpty) return;
    await _run(() => _data.createStockList(brand.id, ctrl.text.trim()));
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

  Future<void> _deleteList(StockCatalog c) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete stock list?'),
        content: Text('Delete "${c.name}"? Its share links stop working. '
            'Designs in it are NOT deleted but will need reassigning to '
            'another list.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (yes == true) await _run(() => _data.deleteCatalog(c.id));
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
                        child: Text('Create your first brand to begin.',
                            style: TextStyle(color: Colors.grey))),
                  ),
              ],
            ),
    );
  }

  // The standalone "Create Your Brand" action card — visually separate from the
  // brand boxes (neutral / dashed) so it reads as an action, not a brand.
  Widget _createBrandCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade400, width: 1.2),
      ),
      child: ListTile(
        leading: const Icon(Icons.add_business_outlined, color: _navy),
        title: const Text('Create Your Brand',
            style: TextStyle(fontWeight: FontWeight.bold)),
        subtitle: const Text('Add a new brand to organise stock lists under it',
            style: TextStyle(fontSize: 12)),
        trailing: IconButton(
          tooltip: 'Create brand',
          icon: const Icon(Icons.add_circle, color: _navy, size: 30),
          onPressed: _busy ? null : _createBrandDialog,
        ),
        onTap: _busy ? null : _createBrandDialog,
      ),
    );
  }

  // A collapsible BRAND box (blue family). Header = name + Share-all + chevron;
  // expanded body = list count / add, then each stock-list box.
  Widget _brandBox(Brand b) {
    final lists = _listsFor(b.id);
    final open = _expandedBrands.contains(b.id);
    final atCap = lists.length >= _listLimit;
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
            onTap: () => setState(() {
              if (open) {
                _expandedBrands.remove(b.id);
              } else {
                _expandedBrands.add(b.id);
              }
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
                    tooltip: 'Brand settings (logo, rename, delete)',
                    icon: const Icon(Icons.tune, size: 18, color: _navy),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(6),
                    onPressed: _busy
                        ? null
                        : () async {
                            await context.push('/stockist/brands');
                            if (mounted) _load();
                          },
                  ),
                ],
              ),
            ),
          ),
          if (open) ...[
            // Lists count + add-list control.
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 8, 4),
              child: Row(
                children: [
                  Text('${lists.length}/$_listLimit lists',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade700)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: (_busy || atCap) ? null : () => _newListDialog(b),
                    icon: Icon(Icons.add,
                        size: 18,
                        color: atCap ? Colors.grey.shade400 : _navy),
                    label: Text(atCap ? 'List limit reached' : 'Add list',
                        style: TextStyle(
                            fontSize: 12,
                            color: atCap ? Colors.grey.shade500 : _navy)),
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  ),
                ],
              ),
            ),
            if (lists.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(14, 0, 14, 12),
                child: Text('No lists yet — tap "Add list".',
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
          ],
        ],
      ),
    );
  }

  // A STOCK-LIST box nested inside its brand box. Each list gets its own colour
  // from [_listPalette], cycled by its position in the brand.
  Widget _listBox(StockCatalog c, int index) {
    final pal = _listPalette[index % _listPalette.length];
    final dealers = _claimers[c.id]?.length ?? 0;
    final enq = _inq[c.id] ?? 0;
    final timed = (_catLinks[c.id] ?? const <ShareLink>[])
        .where((l) => l.revocable)
        .toList();
    // Expired timed links are auto-hidden from the main view (they already stop
    // working everywhere); the row is kept in the DB for records and can be
    // peeked via "Show expired".
    final liveLinks = timed.where((l) => !l.expired).toList();
    final expiredLinks = timed.where((l) => l.expired).toList();
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
                  if (!c.isActive)
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
                  _rowIcon(Icons.delete_outline, 'Delete', Colors.red,
                      _busy ? null : () => _deleteList(c)),
                  _rowIcon(
                      c.isActive
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      c.isActive ? 'Hide list' : 'Show list',
                      Colors.grey.shade700,
                      _busy
                          ? null
                          : () => _run(() =>
                              _data.setCatalogActive(c.id, !c.isActive))),
                ],
              ),
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
                            onPressed:
                                _busy ? null : () => _generateDays(c.id, ctrl),
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
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                            'Tip: the days count starts now — generate the link '
                            'just before you send it.',
                            style: TextStyle(
                                fontSize: 10.5,
                                color: Colors.black54,
                                fontStyle: FontStyle.italic)),
                      ),
                    ],
                  ),
                ),
              // Live generated links (with remaining days).
              for (final l in liveLinks) _liveLinkRow(c, l),
              // Expired links: auto-hidden, peekable for records.
              if (expiredLinks.isNotEmpty) _expiredSection(c, expiredLinks),
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
  Widget _expiredSection(StockCatalog c, List<ShareLink> expired) {
    final open = _showExpired.contains(c.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() {
            if (open) {
              _showExpired.remove(c.id);
            } else {
              _showExpired.add(c.id);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.only(top: 6, left: 2),
            child: Row(
              children: [
                Icon(open ? Icons.expand_more : Icons.chevron_right,
                    size: 16, color: Colors.grey.shade600),
                Icon(Icons.history, size: 14, color: Colors.grey.shade600),
                const SizedBox(width: 4),
                Text('Expired links (${expired.length})',
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade600)),
              ],
            ),
          ),
        ),
        if (open) for (final l in expired) _expiredRow(c, l),
      ],
    );
  }

  // A read-only expired link row (kept for records) + one-tap "Generate again".
  Widget _expiredRow(StockCatalog c, ShareLink l) {
    final exp = l.expiresAt;
    final agoDays = exp == null ? 0 : DateTime.now().difference(exp).inDays;
    final when = exp == null ? '' : _fmtDate(exp);
    return Container(
      margin: const EdgeInsets.only(top: 4, left: 14, right: 4),
      padding: const EdgeInsets.fromLTRB(8, 2, 2, 2),
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.link_off, size: 14, color: Colors.grey.shade500),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
                'Expired${when.isEmpty ? '' : ' $when'}'
                '${agoDays > 0 ? ' · ${agoDays}d ago' : ''}',
                style: TextStyle(
                    fontSize: 11, color: Colors.grey.shade600)),
          ),
          _miniBtn(Icons.refresh, 'Generate again',
              _busy ? null : () => _regenerate(c, l)),
        ],
      ),
    );
  }

  // Re-issue a fresh link for the same duration as the expired one. Falls back
  // to opening the custom generator if the duration can't be read from its label.
  Future<void> _regenerate(StockCatalog c, ShareLink l) async {
    final n = int.tryParse(l.label.split(' ').first);
    if (n == null || n < 1) {
      setState(() => _customOpen.add(c.id));
      return;
    }
    setState(() => _busy = true);
    final token = await _data.createCatalogShareLinkDays(c.id, n);
    if (token != null) await _reloadLinks(c.id);
    if (mounted) setState(() => _busy = false);
  }

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
