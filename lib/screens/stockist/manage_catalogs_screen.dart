import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../config/app_config.dart';
import '../../models/choice_state.dart';
import '../../models/stock_catalog.dart';
import '../../models/claimed_catalog.dart';
import '../../models/share_link.dart';
import '../../services/supabase_data_service.dart';

/// Stockist's stock catalogs (Father & Child): a default **public** catalog
/// (shown in the marketplace) plus, when the admin has granted it, **private**
/// catalogs shared only via their own link. Designs are assigned to a catalog at
/// upload time.
class ManageCatalogsScreen extends StatefulWidget {
  const ManageCatalogsScreen({super.key});
  @override
  State<ManageCatalogsScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);

class _State extends State<ManageCatalogsScreen> {
  final _data = SupabaseDataService();
  List<StockCatalog> _items = [];
  Map<String, int> _inq = {}; // catalogId → link-enquiry count
  Map<String, List<CatalogClaimer>> _claimers = {}; // catalogId → dealers joined
  Map<String, List<ShareLink>> _catLinks = {}; // catalogId → its share links
  bool _canPrivate = false;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final items = await _data.getCatalogs(currentStockistUUID);
    final canPriv = await _data.canCreatePrivate(currentStockistUUID);
    final inq = await _data.getCatalogInquiryCounts(currentStockistUUID);
    final claimerList = await _data.getMyCatalogClaimers();
    final claimers = <String, List<CatalogClaimer>>{};
    for (final c in claimerList) {
      (claimers[c.catalogId] ??= []).add(c);
    }
    // Each catalog's share links (permanent + timed), fetched in parallel.
    final linkLists = await Future.wait(
        items.map((it) => _data.getCatalogShareLinks(it.id)));
    final catLinks = <String, List<ShareLink>>{
      for (var i = 0; i < items.length; i++) items[i].id: linkLists[i]
    };
    if (!mounted) return;
    setState(() {
      _items = items;
      _canPrivate = canPriv;
      _inq = inq;
      _claimers = claimers;
      _catLinks = catLinks;
      _loading = false;
    });
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

  // ── Per-catalog share links (Father & Child) ──────────────────────────────
  // Every catalog (public OR private) has an expandable Links panel with 6 rows:
  // Permanent + 1 week / 1 month / 3 / 6 months / 1 year. Permanent is the
  // always-on catalog link (view/copy only); each timed row can create multiple
  // links (+) and view/copy/delete them (eye).
  static const _linkRows = <({String value, String label})>[
    (value: 'permanent', label: 'Permanent'),
    (value: '1week', label: '1 week'),
    (value: '1month', label: '1 month'),
    (value: '3month', label: '3 months'),
    (value: '6month', label: '6 months'),
    (value: '1year', label: '1 year'),
  ];

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

  Future<void> _createLink(String catalogId, String duration) async {
    setState(() => _busy = true);
    final ok = await _data.createCatalogShareLink(catalogId, duration);
    if (ok) await _reloadLinks(catalogId);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not create link.'),
          backgroundColor: Colors.red));
    }
    setState(() => _busy = false);
  }

  // Eye popup: lists the links for one duration row, each with copy + delete.
  Future<void> _showDurationLinks(
      StockCatalog c, ({String value, String label}) row) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final links = (_catLinks[c.id] ?? const <ShareLink>[])
              .where((l) => l.label == row.label)
              .toList();
          return SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
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
                  Text(
                      '${row.label} link${row.value == 'permanent' ? '' : 's'}'
                      '  ·  ${c.name}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 8),
                  if (links.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      child: Text(
                          'No ${row.label} links yet. Close this and tap + to '
                          'create one.',
                          style: TextStyle(color: Colors.grey.shade600)),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: links.length,
                        separatorBuilder: (_, __) =>
                            Divider(height: 1, color: Colors.grey.shade200),
                        itemBuilder: (_, i) {
                          final l = links[i];
                          final status = l.expired
                              ? 'Expired'
                              : (l.expiresAt == null
                                  ? 'Never expires'
                                  : 'Expires ${_fmtDate(l.expiresAt!)}');
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                                l.expiresAt == null
                                    ? Icons.all_inclusive
                                    : Icons.schedule,
                                color: l.expired ? Colors.grey : _navy),
                            title: Text(status,
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: l.expired ? Colors.red : null)),
                            subtitle: l.createdAt == null
                                ? null
                                : Text('Created ${_fmtDate(l.createdAt!)}',
                                    style: const TextStyle(fontSize: 11)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Copy link',
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(Icons.copy, size: 20),
                                  onPressed:
                                      l.expired ? null : () => _copyToken(l.token),
                                ),
                                if (l.revocable)
                                  IconButton(
                                    tooltip: 'Delete',
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(Icons.delete_outline,
                                        size: 20, color: Colors.red),
                                    onPressed: () async {
                                      final confirm = await showDialog<bool>(
                                        context: ctx,
                                        builder: (dctx) => AlertDialog(
                                          title: const Text('Delete link?'),
                                          content: const Text(
                                              'This link will stop working '
                                              'immediately. Anyone who already '
                                              'saved it keeps their copy.'),
                                          actions: [
                                            TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(dctx, false),
                                                child: const Text('Cancel')),
                                            TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(dctx, true),
                                                child: const Text('Delete',
                                                    style: TextStyle(
                                                        color: Colors.red))),
                                          ],
                                        ),
                                      );
                                      if (confirm != true) return;
                                      final ok =
                                          await _data.revokeShareLink(l.id!);
                                      if (!ctx.mounted) return;
                                      if (ok) {
                                        await _reloadLinks(c.id);
                                        setSheet(() {});
                                      } else {
                                        ScaffoldMessenger.of(ctx).showSnackBar(
                                            const SnackBar(
                                                content:
                                                    Text('Could not delete.'),
                                                backgroundColor: Colors.red));
                                      }
                                    },
                                  ),
                              ],
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

  // The expandable 6-row Links panel shown on a catalog card.
  Widget _linksPanel(StockCatalog c) {
    final all = _catLinks[c.id] ?? const <ShareLink>[];
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 4),
        leading: const Icon(Icons.link, size: 20, color: _navy),
        title: const Text('Links',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        children: [
          for (final row in _linkRows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                children: [
                  SizedBox(
                    width: 78,
                    child: Text(row.label,
                        style: const TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w500)),
                  ),
                  if (all
                          .where((l) => l.label == row.label && !l.expired)
                          .isNotEmpty)
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: _navy.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                          '${all.where((l) => l.label == row.label && !l.expired).length}',
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: _navy)),
                    ),
                  const Spacer(),
                  if (row.value != 'permanent')
                    IconButton(
                      tooltip: 'Create ${row.label} link',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.add_circle_outline,
                          size: 22, color: _navy),
                      onPressed:
                          _busy ? null : () => _createLink(c.id, row.value),
                    ),
                  IconButton(
                    tooltip: 'View ${row.label} link'
                        '${row.value == 'permanent' ? '' : 's'}',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.visibility_outlined, size: 21),
                    onPressed: () => _showDurationLinks(c, row),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _renameDialog(StockCatalog c) async {
    final ctrl = TextEditingController(text: c.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename stock catalogue'),
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
        title: const Text('Share My Stock Catalogues'),
        actions: [
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
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    'Public stock catalogues show in the app marketplace and via their link. '
                    'Private stock catalogues are shared only by their own link.'
                    '${_canPrivate ? '' : ' (Private stock catalogues are admin-enabled.)'}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 90),
                    itemCount: _items.length,
                    itemBuilder: (_, i) => _tile(_items[i]),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _tile(StockCatalog c) {
    final private = c.isPrivate;
    final inMarket = !private && c.showInMarketplace;
    final tagColor = private ? Colors.deepPurple : _navy;
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
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: tagColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(private ? 'PRIVATE' : 'PUBLIC',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: tagColor)),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                private
                    ? 'Link only — not in marketplace'
                    : (inMarket ? 'In marketplace + link' : 'Link only'),
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
              if ((_inq[c.id] ?? 0) > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('${_inq[c.id]} enquiries via this link',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: tagColor)),
                ),
              // Marketplace toggle (public catalogs only).
              if (!private)
                Row(
                  children: [
                    const Text('Show in marketplace',
                        style: TextStyle(fontSize: 12)),
                    const Spacer(),
                    Switch(
                      value: c.showInMarketplace,
                      activeThumbColor: _navy,
                      onChanged: _busy
                          ? null
                          : (v) =>
                              _run(() => _data.setCatalogMarketplace(c.id, v)),
                    ),
                  ],
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
