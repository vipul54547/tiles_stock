import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../config/app_config.dart';
import '../../models/choice_state.dart';
import '../../models/brand.dart';
import '../../models/stock_catalog.dart';
import '../../models/claimed_catalog.dart';
import '../../models/share_link.dart';
import '../../services/supabase_data_service.dart';

/// Stockist's stock lists, grouped by brand. Each brand holds up to the
/// admin-set `stock_list_limit` named lists (default: Premium / Standard /
/// OneTime). A design is assigned to exactly one list at upload time, and each
/// list is shared via its own link.
class ManageCatalogsScreen extends StatefulWidget {
  const ManageCatalogsScreen({super.key});
  @override
  State<ManageCatalogsScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);

class _State extends State<ManageCatalogsScreen> {
  final _data = SupabaseDataService();
  List<StockCatalog> _items = [];
  List<Brand> _brands = [];
  int _listLimit = 3; // admin-set stock lists allowed per brand
  Map<String, int> _inq = {}; // catalogId → link-enquiry count
  Map<String, List<CatalogClaimer>> _claimers = {}; // catalogId → dealers joined
  Map<String, List<ShareLink>> _catLinks = {}; // catalogId → its share links
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
    final items = await _data.getCatalogs(currentStockistUUID);
    final brands = await _data.getMyBrands();
    final limit = await _data.myStockListLimit();
    final inq = await _data.getCatalogInquiryCounts(currentStockistUUID);
    final claimerList = await _data.getMyCatalogClaimers();
    final claimers = <String, List<CatalogClaimer>>{};
    for (final c in claimerList) {
      (claimers[c.catalogId] ??= []).add(c);
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
      _loading = false;
    });
  }

  /// Lists belonging to a brand, in display order.
  List<StockCatalog> _listsFor(String brandId) =>
      _items.where((c) => c.brandId == brandId).toList();

  // Create a new stock list under a brand (server enforces the per-brand cap).
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
              child: const Text('Delete',
                  style: TextStyle(color: Colors.red))),
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

  // Path form (NOT hash) so WhatsApp/social crawlers can read the token and the
  // Netlify edge function can serve a branded per-stockist preview card. The
  // edge function redirects real browsers on to the hash-routed app.
  String _urlFor(String token) => '${AppConfig.shareBaseUrl}/s/$token';

  Future<void> _copy(StockCatalog c) async {
    await Clipboard.setData(ClipboardData(text: _urlFor(c.shareToken)));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Link copied.')));
    }
  }

  Future<void> _whatsapp(StockCatalog c) async {
    final text = '${c.name}: ${_urlFor(c.shareToken)}\n\n'
        'Powered by Tiles Stock';
    final uri =
        Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  String _fmtDate(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

  // ── Per-list share links ──────────────────────────────────────────────────
  // Each stock list has an expandable Links panel: a Permanent (always-on) link
  // plus a Custom-days generator, then every timed link already created for it.
  Future<void> _reloadLinks(String catalogId) async {
    final l = await _data.getCatalogShareLinks(catalogId);
    if (!mounted) return;
    setState(() => _catLinks[catalogId] = l);
  }

  Future<void> _copyToken(String token) async {
    await Clipboard.setData(ClipboardData(text: _urlFor(token)));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Link copied.')));
    }
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
      ctrl.clear();
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

  // A single timed link row: status + copy + delete.
  Widget _timedLinkRow(StockCatalog c, ShareLink l) {
    final status = l.expired
        ? 'Expired'
        : (l.expiresAt == null
            ? 'Never expires'
            : 'Expires ${_fmtDate(l.expiresAt!)}');
    return Padding(
      padding: const EdgeInsets.only(left: 12, top: 1, bottom: 1),
      child: Row(
        children: [
          Icon(Icons.schedule, size: 16, color: l.expired ? Colors.grey : _navy),
          const SizedBox(width: 6),
          Expanded(
            child: Text(status,
                style: TextStyle(
                    fontSize: 12,
                    color: l.expired ? Colors.red : Colors.grey.shade700)),
          ),
          IconButton(
            tooltip: 'Copy link',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.all(6),
            icon: const Icon(Icons.copy, size: 18),
            onPressed: l.expired ? null : () => _copyToken(l.token),
          ),
          if (l.revocable)
            IconButton(
              tooltip: 'Delete link',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.all(6),
              icon:
                  const Icon(Icons.delete_outline, size: 18, color: Colors.red),
              onPressed: _busy
                  ? null
                  : () async {
                      final ok = await _data.revokeShareLink(l.id!);
                      if (ok) await _reloadLinks(c.id);
                    },
            ),
        ],
      ),
    );
  }

  // The expandable Links panel: Permanent link + a Custom-days generator, then
  // every timed link already created for this list.
  Widget _linksPanel(StockCatalog c) {
    final timed = (_catLinks[c.id] ?? const <ShareLink>[])
        .where((l) => l.revocable)
        .toList();
    final activeCount = timed.where((l) => !l.expired).length;
    final ctrl = _daysCtrls.putIfAbsent(c.id, () => TextEditingController());
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 4),
        leading: const Icon(Icons.link, size: 20, color: _navy),
        title: Text(
            activeCount == 0 ? 'Share links' : 'Share links ($activeCount active)',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        children: [
          // Permanent (always-on) link.
          Row(
            children: [
              const SizedBox(
                  width: 86,
                  child: Text('Permanent',
                      style: TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w500))),
              const Spacer(),
              TextButton.icon(
                onPressed: _busy ? null : () => _whatsapp(c),
                icon: const Icon(Icons.share, size: 16),
                label: const Text('Share', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              ),
              IconButton(
                tooltip: 'Copy permanent link',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy, size: 18),
                onPressed: _busy ? null : () => _copy(c),
              ),
            ],
          ),
          // Custom-days generator.
          Row(
            children: [
              const SizedBox(
                  width: 86,
                  child: Text('Custom',
                      style: TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w500))),
              SizedBox(
                width: 54,
                child: TextField(
                  controller: ctrl,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                      border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 6),
              const Text('days', style: TextStyle(fontSize: 12)),
              const Spacer(),
              ElevatedButton(
                onPressed: _busy ? null : () => _generateDays(c.id, ctrl),
                style: ElevatedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12)),
                child: const Text('Generate', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          for (final l in timed) _timedLinkRow(c, l),
        ],
      ),
    );
  }

  // Multi-list generate: tick several lists + one validity → make all links at
  // once (e.g. a builder who wants every list for 15 days). Permanent uses each
  // list's own always-on token; Custom-days mints a fresh timed link per list.
  Future<void> _multiGenerateSheet() async {
    final selected = <String>{};
    bool permanent = true;
    final daysCtrl = TextEditingController(text: '15');
    List<({String name, String url})>? results;
    bool busy = false;

    String allText() =>
        '${results!.map((r) => '${r.name}: ${r.url}').join('\n')}'
        '\n\nPowered by Tiles Stock';

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Future<void> generate() async {
            if (selected.isEmpty) return;
            int days = 0;
            if (!permanent) {
              final d = int.tryParse(daysCtrl.text.trim());
              if (d == null || d < 1) {
                ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                    content: Text('Enter the number of days (1 or more).')));
                return;
              }
              days = d;
            }
            setSheet(() => busy = true);
            final out = <({String name, String url})>[];
            for (final id in selected) {
              final c = _items.firstWhere((x) => x.id == id);
              if (permanent) {
                out.add((name: c.name, url: _urlFor(c.shareToken)));
              } else {
                final token = await _data.createCatalogShareLinkDays(id, days);
                if (token != null) out.add((name: c.name, url: _urlFor(token)));
              }
            }
            await _load();
            if (!ctx.mounted) return;
            setSheet(() {
              results = out;
              busy = false;
            });
          }

          return SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                  16, 10, 16, 14 + MediaQuery.of(ctx).viewInsets.bottom),
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
                          borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  const Text('Send several lists at once',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 8),
                  if (results == null) ...[
                    // Validity: Permanent or Custom days.
                    Row(
                      children: [
                        ChoiceChip(
                          label: const Text('Permanent'),
                          selected: permanent,
                          onSelected: (_) => setSheet(() => permanent = true),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('Custom days'),
                          selected: !permanent,
                          onSelected: (_) => setSheet(() => permanent = false),
                        ),
                        const SizedBox(width: 10),
                        if (!permanent)
                          SizedBox(
                            width: 60,
                            child: TextField(
                              controller: daysCtrl,
                              keyboardType: TextInputType.number,
                              textAlign: TextAlign.center,
                              decoration: const InputDecoration(
                                  isDense: true,
                                  suffixText: 'd',
                                  border: OutlineInputBorder()),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final b in _brands) ...[
                            Padding(
                              padding: const EdgeInsets.only(top: 6, bottom: 2),
                              child: Text(b.name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: _navy)),
                            ),
                            for (final c in _listsFor(b.id))
                              CheckboxListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title: Text(c.name,
                                    style: const TextStyle(fontSize: 13)),
                                value: selected.contains(c.id),
                                onChanged: (v) => setSheet(() {
                                  if (v == true) {
                                    selected.add(c.id);
                                  } else {
                                    selected.remove(c.id);
                                  }
                                }),
                              ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed:
                            (busy || selected.isEmpty) ? null : generate,
                        child: Text(busy
                            ? 'Generating…'
                            : 'Generate ${selected.length} link'
                                '${selected.length == 1 ? '' : 's'}'),
                      ),
                    ),
                  ] else ...[
                    Text('${results!.length} link'
                        '${results!.length == 1 ? '' : 's'} ready',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade600)),
                    const SizedBox(height: 6),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final r in results!)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(r.name,
                                  style: const TextStyle(fontSize: 13)),
                              subtitle: Text(r.url,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 11)),
                              trailing: IconButton(
                                icon: const Icon(Icons.copy, size: 18),
                                onPressed: () async {
                                  await Clipboard.setData(
                                      ClipboardData(text: r.url));
                                  if (ctx.mounted) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                        const SnackBar(
                                            content: Text('Link copied.')));
                                  }
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.share, size: 18),
                            label: const Text('Share all'),
                            onPressed: () async {
                              final uri = Uri.parse(
                                  'https://wa.me/?text=${Uri.encodeComponent(allText())}');
                              await launchUrl(uri,
                                  mode: LaunchMode.externalApplication);
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.copy_all, size: 18),
                            label: const Text('Copy all'),
                            onPressed: () async {
                              await Clipboard.setData(
                                  ClipboardData(text: allText()));
                              if (ctx.mounted) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                    const SnackBar(
                                        content: Text('All links copied.')));
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
    daysCtrl.dispose();
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

  // Dealers (buyers) who have saved this catalog into their app, with a revoke
  // action that removes the catalog from that dealer's Private tab.
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
                  Text('${list.length} dealer${list.length == 1 ? '' : 's'} saved this stock catalogue',
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
                                        'They will lose access to this stock catalogue in their app.'),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Stock Lists'),
        actions: [
          IconButton(
            icon: const Icon(Icons.playlist_add_check),
            tooltip: 'Send several lists at once',
            onPressed:
                (_loading || _items.isEmpty) ? null : _multiGenerateSheet,
          ),
          IconButton(
            icon: const Icon(Icons.sell_outlined),
            tooltip: 'Manage brands',
            onPressed: () async {
              await context.push('/stockist/brands');
              if (mounted) _load();
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 90),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(4, 4, 4, 6),
                  child: Text(
                    'Organise your stock into lists and share each by its own link. '
                    'A design lives in one list — send a customer the list(s) you '
                    'want them to see.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                for (final b in _brands) ..._brandSection(b),
              ],
            ),
    );
  }

  // A brand header (name + lists count/limit + add button) followed by its
  // stock-list cards.
  List<Widget> _brandSection(Brand b) {
    final lists = _listsFor(b.id);
    final atCap = lists.length >= _listLimit;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
        child: Row(
          children: [
            const Icon(Icons.sell_outlined, size: 18, color: _navy),
            const SizedBox(width: 6),
            Expanded(
              child: Text(b.name,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: _navy)),
            ),
            Text('${lists.length}/$_listLimit lists',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            const SizedBox(width: 2),
            IconButton(
              tooltip: atCap
                  ? 'List limit reached — ask the admin for more'
                  : 'New stock list',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.add_circle,
                  color: atCap ? Colors.grey.shade400 : _navy),
              onPressed: (_busy || atCap) ? null : () => _newListDialog(b),
            ),
          ],
        ),
      ),
      if (lists.isEmpty)
        const Padding(
          padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Text('No lists yet — tap + to add one.',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        )
      else
        for (final c in lists) _tile(c),
    ];
  }

  Widget _tile(StockCatalog c) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Opacity(
        opacity: c.isActive ? 1 : 0.5,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(c.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 15)),
                  ),
                  if (!c.isActive)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.grey.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text('HIDDEN',
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey)),
                    ),
                ],
              ),
              if ((_inq[c.id] ?? 0) > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('${_inq[c.id]} enquiries via this link',
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: _navy)),
                ),
              const Divider(height: 12),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _busy ? null : () => _copy(c),
                    icon: const Icon(Icons.link, size: 18),
                    label: const Text('Copy link'),
                    style: TextButton.styleFrom(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: const Size(0, 36),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : () => _whatsapp(c),
                    icon: const Icon(Icons.share, size: 18),
                    label: const Text('Share'),
                    style: TextButton.styleFrom(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: const Size(0, 36),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  ),
                  if ((_claimers[c.id]?.length ?? 0) > 0)
                    TextButton.icon(
                      onPressed: _busy ? null : () => _showClaimers(c),
                      icon: const Icon(Icons.people_outline, size: 18),
                      label: Text('Dealers (${_claimers[c.id]!.length})'),
                      style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          minimumSize: const Size(0, 36),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    ),
                  const Spacer(),
                  IconButton(
                    tooltip: c.isActive ? 'Hide' : 'Show',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(6),
                    icon: Icon(
                        c.isActive
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        size: 20),
                    onPressed: _busy
                        ? null
                        : () => _run(
                            () => _data.setCatalogActive(c.id, !c.isActive)),
                  ),
                  IconButton(
                    tooltip: 'Rename',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(6),
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: _busy ? null : () => _renameDialog(c),
                  ),
                  IconButton(
                    tooltip: 'Delete',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(6),
                    icon: const Icon(Icons.delete_outline,
                        size: 20, color: Colors.red),
                    onPressed: _busy ? null : () => _deleteList(c),
                  ),
                ],
              ),
              _linksPanel(c),
            ],
          ),
        ),
      ),
    );
  }
}
