import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../config/app_config.dart';
import '../../models/choice_state.dart';
import '../../models/stock_catalog.dart';
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
    if (!mounted) return;
    setState(() {
      _items = items;
      _canPrivate = canPriv;
      _inq = inq;
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

  String _urlFor(String token) => '${AppConfig.shareBaseUrl}/#/s/$token';

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

  Future<void> _renameDialog(StockCatalog c) async {
    final ctrl = TextEditingController(text: c.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename catalog'),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Share My Catalogs')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    'Public catalogs show in the app marketplace and via their link. '
                    'Private catalogs are shared only by their own link.'
                    '${_canPrivate ? '' : ' (Private catalogs are admin-enabled.)'}',
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
            ],
          ),
        ),
      ),
    );
  }
}
