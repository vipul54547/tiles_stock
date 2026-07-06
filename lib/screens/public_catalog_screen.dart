import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../services/supabase_data_service.dart';
import '../services/cloudinary_service.dart';
import '../models/tile_design.dart' show expandSearchTerms;
import '../utils/tile_types.dart' show thicknessRangeLabel, sqftPerBox;
import '../utils/tile_sizes.dart' show aspectRatioFromSize;
import '../utils/order_message.dart';
import '../widgets/banner_view.dart';
import '../widgets/filter_section.dart';
import '../widgets/dna_tag_expander.dart';
import '../widgets/tile_card.dart' show TileImage;

/// Public, login-free catalog opened via a stockist's private share link
/// (`/s/<token>`). Shows that stockist's in-stock designs with search, filters,
/// design SELECTION (with box qty), and a WhatsApp enquiry button that sends the
/// list of selected designs to the stockist. Served from the Flutter-Web build.
class PublicCatalogScreen extends StatefulWidget {
  final String token;
  const PublicCatalogScreen({super.key, required this.token});
  @override
  State<PublicCatalogScreen> createState() => _State();
}

class _State extends State<PublicCatalogScreen> {
  final _svc = SupabaseDataService();

  bool _loading = true;
  bool _invalid = false;
  Map<String, dynamic> _stockist = {};
  // Non-default brand identity (multi-brand): shown as the header, with the
  // company name as a "by …" subtitle. Empty for single-brand stockists.
  Map<String, dynamic> _brandInfo = {};
  // Admin-controlled banner chosen server-side: {image_url, overlay, name}.
  // overlay=true → generic/anonymous banner, render the "Welcome to [name]"
  // trust strip; false → a finished branded image shown as-is.
  Map<String, dynamic> _banner = {};
  List<Map<String, dynamic>> _all = [];

  // Selection: designId -> box quantity wanted.
  final Map<String, int> _selected = {};

  // Search + filters
  final _searchCtrl = TextEditingController();
  final _minQtyCtrl = TextEditingController();
  final _maxQtyCtrl = TextEditingController();
  String _query = '';
  bool _smart = true;
  final Set<String> _fSizes = {};
  final Set<String> _fFinishes = {};
  final Set<String> _fQualities = {};
  final Set<String> _fTypes = {};
  final Set<String> _fThickness = {};
  final Set<String> _fStockTypes = {};
  // Design DNA "special search": admin facet catalog [{id,name,values:[{id,name}]}]
  // from the RPC, plus the selected canonical value ids. Each design carries its
  // tagged value ids in d['dna']. (project_design_dna_engine)
  List<Map<String, dynamic>> _dnaFacets = [];
  final Set<String> _fDna = {};
  // Which card's DNA-tag ▾ is currently expanded (only one at a time).
  String? _expandedDnaDesignId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _minQtyCtrl.dispose();
    _maxQtyCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final data = await _svc.getPublicCatalog(widget.token);
    if (!mounted) return;
    if (data == null) {
      setState(() {
        _invalid = true;
        _loading = false;
      });
      return;
    }
    setState(() {
      _stockist = Map<String, dynamic>.from(data['stockist'] ?? {});
      _brandInfo = data['brand'] != null
          ? Map<String, dynamic>.from(data['brand'])
          : {};
      _banner = data['banner'] != null
          ? Map<String, dynamic>.from(data['banner'])
          : {};
      _all = ((data['designs'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      _dnaFacets = ((data['dna_facets'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      _loading = false;
    });
  }

  // ── Branding ─────────────────────────────────────────────────────────────

  // Default theme blue, overridden by the stockist's chosen brand colour.
  static const Color _defaultBrand = Color(0xFF1B4F72);

  /// The stockist's brand accent colour (hex from the RPC) or the default.
  Color get _brand {
    final hex = (_stockist['brand_color'] ?? '').toString().replaceAll('#', '').trim();
    final v = int.tryParse(hex, radix: 16);
    if (v == null || hex.length != 6) return _defaultBrand;
    return Color(0xFF000000 | v);
  }

  // ── Derived ────────────────────────────────────────────────────────────────

  List<String> _distinct(String key) {
    final s = <String>{};
    for (final d in _all) {
      final v = (d[key] ?? '').toString().trim();
      if (v.isNotEmpty) s.add(v);
    }
    final list = s.toList()..sort();
    return list;
  }

  int get _filterCount =>
      _fSizes.length +
      _fFinishes.length +
      _fQualities.length +
      _fTypes.length +
      _fThickness.length +
      _fStockTypes.length +
      _fDna.length +
      (_minQtyCtrl.text.trim().isNotEmpty ? 1 : 0) +
      (_maxQtyCtrl.text.trim().isNotEmpty ? 1 : 0);

  // The DNA value ids tagged on a design (sent by the RPC as a list).
  Set<String> _dnaOf(Map<String, dynamic> d) =>
      ((d['dna'] as List?) ?? const []).map((e) => e.toString()).toSet();

  // This design's DNA tags grouped by attribute name, for the card's
  // expandable ▾ section. Built from the already-loaded facet catalog.
  Map<String, List<String>> _dnaTagsFor(Map<String, dynamic> d) {
    final vals = _dnaOf(d);
    if (vals.isEmpty) return const {};
    final out = <String, List<String>>{};
    for (final attr in _dnaFacets) {
      final name = (attr['name'] ?? '').toString();
      for (final v in ((attr['values'] as List?) ?? const [])) {
        final map = v as Map;
        final vName = (map['name'] ?? '').toString();
        if (vName.toLowerCase() == 'none') continue;
        if (vals.contains(map['id'].toString())) {
          (out[name] ??= []).add(vName);
        }
      }
    }
    return out;
  }

  // DNA value ids present across the in-stock pool (so empty facets hide).
  Set<String> get _dnaInUse {
    final used = <String>{};
    for (final d in _all) {
      used.addAll(_dnaOf(d));
    }
    return used;
  }

  // Faceted DNA match: within an attribute picks OR, across attributes AND.
  bool _matchesDna(Map<String, dynamic> d) {
    if (_fDna.isEmpty) return true;
    final vals = _dnaOf(d);
    for (final attr in _dnaFacets) {
      final ids = ((attr['values'] as List?) ?? const [])
          .map((v) => (v as Map)['id'].toString())
          .where(_fDna.contains)
          .toSet();
      if (ids.isNotEmpty && ids.intersection(vals).isEmpty) return false;
    }
    return true;
  }

  // Thickness band for a design, computed from box weight + pieces (sent by the
  // RPC now). Null when there's no weight data, so it just won't show a band.
  String? _bandOf(Map<String, dynamic> d) => thicknessRangeLabel(
        (d['size'] ?? '').toString(),
        (d['pieces'] as num?)?.toInt() ?? 0,
        (d['weight'] as num?)?.toDouble() ?? 0,
        (d['tile_type'] ?? '').toString(),
      );

  List<String> _thicknessBands() {
    final s = <String>{};
    for (final d in _all) {
      final b = _bandOf(d);
      if (b != null) s.add(b);
    }
    final list = s.toList()
      ..sort((a, b) => (double.tryParse(a.split('–').first.trim()) ?? 0)
          .compareTo(double.tryParse(b.split('–').first.trim()) ?? 0));
    return list;
  }

  List<Map<String, dynamic>> get _filtered {
    Iterable<Map<String, dynamic>> r = _all;
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      final terms = _smart ? expandSearchTerms(q) : {q};
      r = r.where((d) {
        final dnaWords = _dnaTagsFor(d).values.expand((x) => x).join(' ');
        final hay =
            '${d['name'] ?? ''} ${d['surface'] ?? ''} ${d['finish'] ?? ''} $dnaWords'
                .toLowerCase();
        return terms.any((t) => hay.contains(t));
      });
    }
    if (_fSizes.isNotEmpty) r = r.where((d) => _fSizes.contains('${d['size']}'));
    if (_fFinishes.isNotEmpty) {
      r = r.where((d) => _fFinishes.contains('${d['surface']}'));
    }
    if (_fQualities.isNotEmpty) {
      r = r.where((d) => _fQualities.contains('${d['quality']}'));
    }
    if (_fTypes.isNotEmpty) {
      r = r.where((d) => _fTypes.contains('${d['tile_type']}'));
    }
    if (_fThickness.isNotEmpty) {
      r = r.where((d) => _fThickness.contains(_bandOf(d)));
    }
    if (_fStockTypes.isNotEmpty) {
      r = r.where((d) => _fStockTypes.contains('${d['stock_type']}'));
    }
    if (_fDna.isNotEmpty) r = r.where(_matchesDna);
    final mn = int.tryParse(_minQtyCtrl.text);
    final mx = int.tryParse(_maxQtyCtrl.text);
    if (mn != null) r = r.where((d) => ((d['boxes'] as num?) ?? 0) >= mn);
    if (mx != null) r = r.where((d) => ((d['boxes'] as num?) ?? 0) <= mx);
    return r.toList();
  }

  // ── Selection ────────────────────────────────────────────────────────────

  void _toggle(String id) => setState(() {
        if (_selected.containsKey(id)) {
          _selected.remove(id);
        } else {
          // Default the wanted quantity to the design's available stock, so the
          // buyer starts from the full in-stock count and trims down as needed.
          final d =
              _all.firstWhere((e) => '${e['id']}' == id, orElse: () => const {});
          final stock = (d['boxes'] as num?)?.toInt() ?? 1;
          _selected[id] = stock > 0 ? stock : 1;
        }
      });

  void _setQty(String id, int q) => setState(() {
        if (q <= 0) {
          _selected.remove(id);
        } else {
          _selected[id] = q;
        }
      });

  // ── Quality merge (Scenario-2 buyer merge) ─────────────────────────────────
  // Fold a tile's Premium + Standard holdings (same library_id + surface on this
  // single-stockist page) into one "rep" map carrying both holding ids/boxes in
  // _premId/_premBoxes/_stdId/_stdBoxes. Preserves first-appearance order; a
  // family band still needs >=2 DISTINCT masters, so a lone tile's own P/S split
  // never bands. Merges across quality only — a different surface stays separate.
  List<Map<String, dynamic>> _mergeByQuality(List<Map<String, dynamic>> rows) {
    final order = <String>[];
    final prem = <String, Map<String, dynamic>>{};
    final std = <String, Map<String, dynamic>>{};
    for (final d in rows) {
      final lib = (d['library_id'] ?? d['id'] ?? '').toString();
      final surface = (d['surface'] ?? '').toString();
      final k = '$lib|$surface';
      if (!prem.containsKey(k) && !std.containsKey(k)) order.add(k);
      final isPrem = '${d['quality']}'.toLowerCase() == 'premium';
      final m = isPrem ? prem : std;
      final cur = m[k];
      if (cur == null ||
          ((d['boxes'] as num?) ?? 0) > ((cur['boxes'] as num?) ?? 0)) {
        m[k] = d;
      }
    }
    final out = <Map<String, dynamic>>[];
    for (final k in order) {
      final p = prem[k];
      final s = std[k];
      final rep = Map<String, dynamic>.from((p ?? s)!);
      rep['_premId'] = p?['id'];
      rep['_premBoxes'] = p?['boxes'];
      rep['_stdId'] = s?['id'];
      rep['_stdBoxes'] = s?['boxes'];
      out.add(rep);
    }
    return out;
  }

  // Premium/Standard/Both chooser for a merged public card (step 3). Writes box
  // counts into _selected keyed per real holding id, so "Both" is two steppers.
  void _showQualityChoicePublic(Map<String, dynamic> d) {
    final premId = d['_premId'] == null ? null : '${d['_premId']}';
    final stdId = d['_stdId'] == null ? null : '${d['_stdId']}';
    final premBoxes = (d['_premBoxes'] as num?)?.toInt() ?? 0;
    final stdBoxes = (d['_stdBoxes'] as num?)?.toInt() ?? 0;
    // Default each grade's wanted quantity to its full available stock (buyer
    // starts from the in-stock count and trims down), unless already chosen.
    if (premId != null && !_selected.containsKey(premId) && premBoxes > 0) {
      _selected[premId] = premBoxes;
    }
    if (stdId != null && !_selected.containsKey(stdId) && stdBoxes > 0) {
      _selected[stdId] = stdBoxes;
    }
    setState(() {});
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget grade(String? id, String label, int max, Color fg, Color bg) {
            if (id == null) return const SizedBox.shrink();
            final qty = _selected[id] ?? 0;
            void set(int v) {
              _setQty(id, v.clamp(0, max));
              setSheet(() {});
            }

            Widget step(IconData icon, VoidCallback? onTap) => InkResponse(
                  onTap: onTap,
                  radius: 18,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: onTap == null
                              ? Colors.grey.shade300
                              : Colors.grey),
                    ),
                    child: Icon(icon,
                        size: 16,
                        color: onTap == null
                            ? Colors.grey.shade300
                            : Colors.grey.shade800),
                  ),
                );

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: bg.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: fg.withValues(alpha: 0.35)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label,
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: fg,
                                fontSize: 13)),
                        Text('$max boxes available',
                            style: TextStyle(
                                color: Colors.grey.shade600, fontSize: 11)),
                      ],
                    ),
                  ),
                  step(Icons.remove, qty > 0 ? () => set(qty - 1) : null),
                  GestureDetector(
                    onTap: () async {
                      await _editQty(id, qty, max);
                      setSheet(() {});
                    },
                    child: SizedBox(
                      width: 44,
                      child: Text('$qty',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: fg,
                              decoration: TextDecoration.underline,
                              decorationColor: fg.withValues(alpha: 0.4))),
                    ),
                  ),
                  step(Icons.add, qty < max ? () => set(qty + 1) : null),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: qty == max ? () => set(0) : () => set(max),
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                      decoration: BoxDecoration(
                        color: fg.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(qty == max ? 'Clear' : 'All',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: fg)),
                    ),
                  ),
                ],
              ),
            );
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text((d['name'] ?? '').toString(),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 12),
                  grade(premId, 'Premium', premBoxes, const Color(0xFFF9A825),
                      const Color(0xFFFFF8E1)),
                  grade(stdId, 'Standard', stdBoxes, const Color(0xFF1565C0),
                      const Color(0xFFE3F2FD)),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: _brand),
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Done'),
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

  // Manual quantity entry — tapping the number opens this so the buyer can type
  // a large box count directly instead of holding the +/- steppers.
  Future<void> _editQty(String id, int current, [int? max]) async {
    // TextFormField (self-managed controller) avoids the '_dependents.isEmpty'
    // crash a hand-disposed controller caused during the dialog's close.
    int? entered = current;
    final value = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quantity (boxes)'),
        content: TextFormField(
          initialValue: '$current',
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            hintText: 'Enter boxes',
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => entered = int.tryParse(v.trim()),
          onFieldSubmitted: (v) => Navigator.pop(ctx, int.tryParse(v.trim())),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, entered),
            child: const Text('Set'),
          ),
        ],
      ),
    );
    if (value != null && value > 0) {
      _setQty(id, max != null ? value.clamp(0, max) : value);
    }
  }

  // ── WhatsApp enquiry (lists the selected designs) ──────────────────────────

  Future<void> _enquire() async {
    // Real supplier phone (country code alone must NOT count as a number).
    final rawPhone = (_stockist['phone'] ?? '').toString().trim();
    final phone =
        '${_stockist['country_code'] ?? '+91'}${_stockist['phone'] ?? ''}'
            .replaceAll(RegExp(r'[^0-9]'), '');
    final name = (_stockist['name'] ?? '').toString();
    // Turn a selection into a real saved order so the stockist can manage it;
    // the returned connection code goes into the message as the shared handle.
    Map<String, dynamic>? order;
    if (_selected.isNotEmpty) {
      order = await _svc.createWebOrder(
        widget.token,
        _selected.entries
            .map((e) => {'design_id': e.key, 'quantity': e.value})
            .toList(),
      );
    }

    final String msg;
    if (_selected.isEmpty) {
      msg = 'I would like to enquire about some designs.';
    } else {
      final ot = order == null ? '' : (order['token'] ?? '').toString();
      final code =
          order == null ? '' : (order['connection_code'] ?? '').toString();
      msg = buildOrderMessage([
        for (final d in _all)
          if (_selected.containsKey('${d['id']}'))
            (
              name: (d['name'] ?? '').toString(),
              size: (d['size'] ?? '').toString(),
              surface: (d['surface'] ?? '').toString(),
              quality: (d['quality'] ?? '').toString(),
              qty: _selected['${d['id']}']!,
            ),
      ], orderNo: ot, connectionCode: code);
    }
    // Record this link enquiry (which catalog/visibility, selected designs) so
    // the stockist/admin can see demand coming via links. Best-effort.
    _svc.logLinkInquiry(widget.token, _selected.keys.toList());

    // No supplier number on file → copy the order so the buyer can paste it into
    // any chat, instead of a blank WhatsApp chooser.
    if (rawPhone.isEmpty) {
      await Clipboard.setData(ClipboardData(text: msg));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Order copied — paste it into your chat.'),
            backgroundColor: Color(0xFF2E7D32)));
      }
      return;
    }
    final uri =
        Uri.parse('https://wa.me/$phone?text=${Uri.encodeComponent(msg)}');

    // High-intent moment: on the web, the FIRST time a browser visitor sends an
    // enquiry, offer the app (once). The enquiry is NEVER blocked — "Skip & send"
    // and "Download" both proceed to WhatsApp; Download also opens the store with
    // the supplier token so the install auto-reconnects (Scenario 2).
    if (kIsWeb && AppConfig.hasAnyStoreLink) {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool('app_prompt_shown') ?? false)) {
        await prefs.setBool('app_prompt_shown', true);
        if (!mounted) return;
        final supplier = (_brandInfo['name'] ?? '').toString().isNotEmpty
            ? _brandInfo['name'].toString()
            : name;
        final choice = await _showGetAppDialog(supplier);
        if (choice == 'download') {
          launchUrl(Uri.parse(_downloadUrl()),
              mode: LaunchMode.externalApplication);
        }
      }
    }

    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  // The store URL for this visitor's platform, with the supplier token appended
  // as a Play Store install referrer so a fresh install reconnects them to this
  // exact supplier (Scenario 2). Other platforms just get the plain store URL.
  String _downloadUrl() {
    final base = _storeUrl;
    if (defaultTargetPlatform == TargetPlatform.android &&
        AppConfig.androidStoreUrl.isNotEmpty) {
      final sep = base.contains('?') ? '&' : '?';
      return '$base${sep}referrer=${Uri.encodeComponent('token=${widget.token}')}';
    }
    return base;
  }

  // One-time "get the app" prompt shown at the enquiry moment. Returns
  // 'download' or 'skip' (or null if dismissed). Never blocks the enquiry.
  Future<String?> _showGetAppDialog(String supplier) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.smartphone, color: _brand, size: 36),
        title: const Text('Get the app for the best experience'),
        content: Text(
            '${supplier.isEmpty ? 'Save this supplier' : 'Save $supplier'} and '
            'see their latest stock anytime — no more PDFs.'),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'skip'),
              child: const Text('Skip & send')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, 'download'),
            icon: const Icon(Icons.download, size: 18),
            label: const Text('Download app'),
            style: FilledButton.styleFrom(backgroundColor: _brand),
          ),
        ],
      ),
    );
  }

  // ── Tile detail bottom sheet ───────────────────────────────────────────────

  void _showDetail(Map<String, dynamic> d) {
    final id = '${d['id']}';
    final size = (d['size'] ?? '').toString();
    final pieces = (d['pieces'] as num?)?.toInt() ?? 0;
    final weight = (d['weight'] as num?)?.toDouble() ?? 0;
    final sqft = sqftPerBox(size, pieces);
    final band = _bandOf(d);
    final surface = (d['surface'] ?? '').toString();
    final finish = (d['finish'] ?? '').toString();
    final finishText = finish.isNotEmpty ? '$surface · $finish' : surface;
    final images = (d['images'] as List?) ?? const [];
    final img = images.isNotEmpty ? images.first.toString() : '';
    final ratio = aspectRatioFromSize(size);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final selected = _selected.containsKey(id);
          Widget row(String label, String value) {
            if (value.trim().isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                      width: 120,
                      child: Text(label,
                          style: const TextStyle(
                              fontSize: 13, color: Colors.grey))),
                  Expanded(
                      child: Text(value,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600))),
                ],
              ),
            );
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                            color: Colors.grey.shade300,
                            borderRadius: BorderRadius.circular(2)),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (img.isNotEmpty) ...[
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(
                              width: 96,
                              child: AspectRatio(
                                aspectRatio: ratio,
                                child: CachedNetworkImage(
                                    imageUrl:
                                        CloudinaryService.thumbUrl(img, width: 300),
                                    fit: BoxFit.cover),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                        ],
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text((d['name'] ?? '').toString(),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16)),
                              const SizedBox(height: 4),
                              Text('${d['boxes']} boxes in stock',
                                  style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF2E7D32))),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 22),
                    row('Size', size.replaceAll(' mm', '')),
                    row('Finish', finishText),
                    row('Quality', (d['quality'] ?? '').toString()),
                    row('Tile Type', (d['tile_type'] ?? '').toString()),
                    row('Colour', (d['colour'] ?? '').toString()),
                    if (pieces > 0) row('Pieces / box', '$pieces'),
                    if (weight > 0)
                      row('Box weight',
                          '${weight.toStringAsFixed(weight % 1 == 0 ? 0 : 1)} kg'),
                    if (sqft != null) row('Sq.ft / box', sqft.toStringAsFixed(2)),
                    if (band != null) row('Thickness (approx)', band),
                    // Family (concept) — sibling variants + their stock, incl.
                    // out-of-stock members greyed, so the buyer sees the whole set.
                    _PublicFamilyStrip(designId: id, brand: _brand),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          _toggle(id);
                          setSheet(() {});
                        },
                        icon: Icon(
                            selected
                                ? Icons.check_circle
                                : Icons.add_circle_outline,
                            size: 18),
                        label: Text(selected
                            ? 'Added to enquiry — tap to remove'
                            : 'Add to enquiry'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: selected
                              ? const Color(0xFF2E7D32)
                              : _brand,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Filters sheet ──────────────────────────────────────────────────────────

  void _openFilters() {
    var showMore = false; // reveal advanced facets (Quality, Tile Type, DNA…)
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          // Every filter field (_fSizes/_fDna/etc.) IS the real screen state —
          // setSheet only redraws the sheet itself. setBoth also rebuilds the
          // screen behind it, so results update live as soon as you tap a chip,
          // no "Apply" step required.
          void setBoth(VoidCallback fn) {
            setSheet(fn);
            setState(() {});
          }

          // Collapsible facet: header shows how many are chosen; opens on tap.
          Widget section(String title, List<String> opts, Set<String> sel) {
            if (opts.isEmpty) return const SizedBox.shrink();
            return FilterSection(
              title: title,
              summary: filterSummary(sel),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: opts.map((o) {
                  final on = sel.contains(o);
                  return FilterChip(
                    label: Text(o.replaceAll(' mm', '')),
                    selected: on,
                    onSelected: (v) =>
                        setBoth(() => v ? sel.add(o) : sel.remove(o)),
                  );
                }).toList(),
              ),
            );
          }

          String qtySummary() {
            final mn = _minQtyCtrl.text.trim();
            final mx = _maxQtyCtrl.text.trim();
            if (mn.isEmpty && mx.isEmpty) return 'Any';
            return '${mn.isEmpty ? '0' : mn}–${mx.isEmpty ? '∞' : mx}';
          }

          // Design DNA facet (id-keyed chips). Only values present in the pool
          // are shown; whole attributes with no tagged values are hidden.
          final dnaInUse = _dnaInUse;
          List<Map<String, dynamic>> dnaValuesInUse(Map<String, dynamic> attr) =>
              ((attr['values'] as List?) ?? const [])
                  .map((v) => Map<String, dynamic>.from(v as Map))
                  .where((v) => dnaInUse.contains(v['id'].toString()))
                  .toList();

          // A full collapsible facet for one DNA attribute (used for Series,
          // which stays as its own top-level row next to Finish).
          Widget dnaSection(Map<String, dynamic> attr) {
            final vals = dnaValuesInUse(attr);
            if (vals.isEmpty) return const SizedBox.shrink();
            final picked = vals
                .where((v) => _fDna.contains(v['id'].toString()))
                .map((v) => v['name'].toString());
            return FilterSection(
              title: (attr['name'] ?? '').toString(),
              summary: picked.isEmpty ? 'All' : picked.join(', '),
              child: _dnaChipWrap(vals, setBoth),
            );
          }

          // A plain (non-collapsible) label + chip row, for attributes nested
          // inside the single "Design DNA" group — avoids collapsible-inside-
          // collapsible clutter once the group itself is opened.
          Widget dnaAttributeBlock(Map<String, dynamic> attr) {
            final vals = dnaValuesInUse(attr);
            if (vals.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text((attr['name'] ?? '').toString(),
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 12.5)),
                  const SizedBox(height: 6),
                  _dnaChipWrap(vals, setBoth),
                ],
              ),
            );
          }

          final seriesAttr = _dnaFacets
              .cast<Map<String, dynamic>?>()
              .firstWhere((a) => a?['name'] == 'Series', orElse: () => null);
          final otherDnaFacets =
              _dnaFacets.where((a) => a['name'] != 'Series').toList();
          final otherDnaValueIds = otherDnaFacets
              .expand(dnaValuesInUse)
              .map((v) => v['id'].toString())
              .toSet();
          final otherDnaPickedCount =
              _fDna.where(otherDnaValueIds.contains).length;

          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.75,
            minChildSize: 0.4,
            maxChildSize: 0.92,
            builder: (_, scroll) => SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(2))),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                    child: Row(
                      children: [
                        const Text('Filters',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16)),
                        const Spacer(),
                        TextButton(
                          onPressed: () => setBoth(() {
                            _fSizes.clear();
                            _fFinishes.clear();
                            _fQualities.clear();
                            _fTypes.clear();
                            _fThickness.clear();
                            _fStockTypes.clear();
                            _fDna.clear();
                            _minQtyCtrl.clear();
                            _maxQtyCtrl.clear();
                          }),
                          child: const Text('Clear all',
                              style: TextStyle(color: Colors.red)),
                        ),
                        const SizedBox(width: 4),
                        FilledButton(
                          onPressed: () => Navigator.pop(ctx),
                          style: FilledButton.styleFrom(
                              backgroundColor: _brand,
                              foregroundColor: Colors.white,
                              visualDensity: VisualDensity.compact,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 18)),
                          child: const Text('Done'),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView(
                      controller: scroll,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      children: [
                        FilterSection(
                          title: 'Quantity (boxes)',
                          summary: qtySummary(),
                          initiallyExpanded: true,
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _minQtyCtrl,
                                  keyboardType: TextInputType.number,
                                  onChanged: (_) => setBoth(() {}),
                                  decoration: InputDecoration(
                                    hintText: 'Min',
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 10),
                                    border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8)),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextField(
                                  controller: _maxQtyCtrl,
                                  keyboardType: TextInputType.number,
                                  onChanged: (_) => setBoth(() {}),
                                  decoration: InputDecoration(
                                    hintText: 'Max',
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 10),
                                    border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8)),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Essentials — always visible.
                        section('Size', _distinct('size'), _fSizes),
                        section('Quality', _distinct('quality'), _fQualities),
                        section('Finish', _distinct('surface'), _fFinishes),
                        section(
                            'Stock Type', _distinct('stock_type'), _fStockTypes),
                        // Advanced — behind the "More filters" toggle.
                        MoreFiltersToggle(
                          expanded: showMore,
                          activeHidden: (_fTypes.isNotEmpty ? 1 : 0) +
                              (_fThickness.isNotEmpty ? 1 : 0) +
                              (_fDna.isNotEmpty ? 1 : 0),
                          onToggle: () => setSheet(() => showMore = !showMore),
                        ),
                        if (showMore) ...[
                          if (seriesAttr != null) dnaSection(seriesAttr),
                          section('Tile Type', _distinct('tile_type'), _fTypes),
                          section('Thickness (approx)', _thicknessBands(),
                              _fThickness),
                          // Every other DNA attribute (Punch/Look Type/…) nested
                          // under one group, so the list stays short.
                          if (otherDnaFacets
                              .any((a) => dnaValuesInUse(a).isNotEmpty))
                            FilterSection(
                              title: 'Design DNA',
                              summary: otherDnaPickedCount == 0
                                  ? 'All'
                                  : '$otherDnaPickedCount chosen',
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: otherDnaFacets
                                    .map(dnaAttributeBlock)
                                    .toList(),
                              ),
                            ),
                        ],
                        const SizedBox(height: 8),
                      ],
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

  // Shared chip-wrap renderer for a DNA attribute's in-use values.
  Widget _dnaChipWrap(
      List<Map<String, dynamic>> vals, void Function(VoidCallback) setBoth) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: vals.map((v) {
        final id = v['id'].toString();
        final on = _fDna.contains(id);
        return FilterChip(
          label: Text(v['name'].toString()),
          selected: on,
          onSelected: (sel) =>
              setBoth(() => sel ? _fDna.add(id) : _fDna.remove(id)),
        );
      }).toList(),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
          backgroundColor: Color(0xFFF5F5F5),
          body: Center(child: CircularProgressIndicator()));
    }
    if (_invalid) {
      return const Scaffold(
          backgroundColor: Color(0xFFF5F5F5), body: _Unavailable());
    }
    final list = _filtered;
    // Fold each tile's Premium+Standard holdings into one merged card.
    final merged = _mergeByQuality(list);
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: CustomScrollView(
        slivers: [
          // No separate name bar: the banner IS the top of the page now. The
          // name already shows once on its "Welcome to X" line, so a bar above
          // it with no title/icons of its own was just dead colored space.
          SliverToBoxAdapter(child: _bannerArea()),
          // Search + filter row stays PINNED so it's always reachable while scrolling.
          SliverPersistentHeader(
            pinned: true,
            delegate: _PinnedHeader(height: 60, child: _searchRow()),
          ),
          SliverToBoxAdapter(child: _metaRow(merged.length)),
          if (merged.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                  child: Text('No designs match.',
                      style: TextStyle(color: Colors.grey))),
            )
          else
            _familyGridSliver(merged),
          SliverToBoxAdapter(child: _poweredBy()),
        ],
      ),
      bottomNavigationBar: _enquireBar(),
    );
  }

  // ── Banner (admin-controlled) ──────────────────────────────────────────────
  // A slim, height-capped 2.5:1 (1500×600) banner. The image is chosen
  // server-side: a finished BRANDED image (overlay=false, shown as-is) or a
  // daily-rotated GENERIC/anonymous image with a system "Welcome to [name]"
  // trust strip (overlay=true). Falls back to a brand-colour gradient + strip
  // when no pool image is configured yet. Replaces the old tall logo/name/
  // tagline/address header that ate ~half the screen. (project_admin_banner_system)
  Widget _bannerArea() {
    // ONE shared renderer — identical to the stockist editor preview
    // (lib/widgets/banner_view.dart), so what a stockist designs is exactly
    // what buyers see here. Never inline a second copy of this layout.
    return BannerView(
      source: (_banner['source'] ?? 'pool').toString(),
      bgUrl: (_banner['bg_url'] ?? _banner['image_url'] ?? '').toString(),
      companyLogoUrl: (_banner['company_logo_url'] ?? '').toString(),
      companyPos: (_banner['company_pos'] ?? 'none').toString(),
      tdPos: (_banner['td_pos'] ?? 'top-right').toString(),
      tdShow: _banner['td_show'] == true,
      heading: (_banner['banner_heading'] ?? '').toString(),
      message: (_banner['banner_text'] ?? '').toString(),
      headingSize: (_banner['banner_heading_size'] ?? '').toString(),
      headingColor: (_banner['banner_heading_color'] ?? '').toString(),
      msgSize: (_banner['banner_msg_size'] ?? '').toString(),
      msgColor: (_banner['banner_msg_color'] ?? '').toString(),
      textAlign: (_banner['banner_text_align'] ?? '').toString(),
      textValign: (_banner['banner_text_valign'] ?? '').toString(),
      name: (_banner['name'] ?? _stockist['name'] ?? '').toString(),
      brandColor: _brand,
    );
  }

  // Result count + city, with a compact "Directions" link (Maps) when set.
  Widget _metaRow(int shown) {
    final city = (_stockist['city'] ?? '').toString();
    final mapUrl = (_stockist['map_url'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$shown of ${_all.length} designs'
              '${city.isNotEmpty ? ' · $city' : ''}',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
          if (mapUrl.isNotEmpty)
            GestureDetector(
              onTap: () => launchUrl(Uri.parse(mapUrl),
                  mode: LaunchMode.externalApplication),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.directions, size: 15, color: _brand),
                  const SizedBox(width: 2),
                  Text('Directions',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _brand)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // The right app-store URL for the browser visitor's platform (Android → Play,
  // iOS → App Store), falling back to the site/store-fallback when there's no
  // listing for that platform yet. Web-only (defaultTargetPlatform reflects the
  // browser's host OS on the web build).
  String get _storeUrl {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AppConfig.androidStoreUrl.isNotEmpty
            ? AppConfig.androidStoreUrl
            : AppConfig.storeFallbackUrl;
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppConfig.iosStoreUrl.isNotEmpty
            ? AppConfig.iosStoreUrl
            : AppConfig.storeFallbackUrl;
      default:
        return AppConfig.storeFallbackUrl;
    }
  }

  // Footer nudge shown at the bottom of every catalog page on the WEB build
  // only — buyers reaching this page in a browser (no app) get sent to the
  // right store for their device. Hidden in the app itself and until at
  // least one store link is configured.
  Widget _poweredBy() {
    final showNudge = kIsWeb && AppConfig.hasAnyStoreLink;
    if (!showNudge) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 8, 16, 16 + MediaQuery.viewPaddingOf(context).bottom),
      child: GestureDetector(
        onTap: () => launchUrl(Uri.parse(_storeUrl),
            mode: LaunchMode.externalApplication),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.smartphone, size: 14, color: _brand),
            const SizedBox(width: 5),
            Text.rich(
              TextSpan(
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                children: [
                  const TextSpan(text: 'Get the app for a better experience — '),
                  TextSpan(
                    text: 'Download',
                    style: TextStyle(fontWeight: FontWeight.bold, color: _brand),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: _smart
                    ? 'Smart: white = bianco, carrara…'
                    : 'Search designs…',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: Colors.grey.shade300)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: Colors.grey.shade300)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Smart toggle
          GestureDetector(
            onTap: () => setState(() => _smart = !_smart),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
              decoration: BoxDecoration(
                color: _smart ? _brand : Colors.grey.shade200,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.auto_awesome,
                  size: 18,
                  color: _smart ? Colors.white : Colors.grey.shade600),
            ),
          ),
          const SizedBox(width: 8),
          // Filter button
          GestureDetector(
            onTap: _openFilters,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
              decoration: BoxDecoration(
                color: _filterCount > 0
                    ? _brand
                    : Colors.grey.shade200,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.tune,
                      size: 18,
                      color: _filterCount > 0
                          ? Colors.white
                          : Colors.grey.shade600),
                  if (_filterCount > 0) ...[
                    const SizedBox(width: 4),
                    Text('$_filterCount',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget? _enquireBar() {
    final count = _selected.length;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 6,
                offset: const Offset(0, -2)),
          ],
        ),
        child: Row(
          children: [
            Text(
              count == 0 ? 'Tap tiles to select' : '$count selected',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: count == 0 ? Colors.grey : _brand),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _enquire,
                icon: const Icon(Icons.chat_rounded, size: 18),
                label: Text(count == 0
                    ? 'Enquire on WhatsApp'
                    : 'Enquire ($count) on WhatsApp'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF25D366),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Concept-family bands ────────────────────────────────────────────────────
  // Designs sharing (size + family_key) are variants of one concept (1801-A /
  // 1801-B). Standalone cards flow in the normal 2-col masonry; a family (>=2
  // DISTINCT masters) is pulled into one full-width band ringed by a thin colour.
  // (Only in-stock designs reach here — public_catalog already filters boxes>0.)
  static const List<Color> _familyColors = [
    Color(0xFF1B9E77), Color(0xFFD95F02), Color(0xFF7570B3),
    Color(0xFFE7298A), Color(0xFF66A61E), Color(0xFFE6AB02),
    Color(0xFFA6761D), Color(0xFF1F78B4),
  ];
  Color _famColorFor(String gk) =>
      _familyColors[gk.hashCode.abs() % _familyColors.length];

  String _gkOf(Map<String, dynamic> d) {
    final fk = (d['family_key'] ?? '').toString();
    return fk.isEmpty ? '' : '${d['size']}|$fk';
  }

  // Light boost: a rich family (>=3 distinct masters) nudges up a few slots so a
  // coordinated set surfaces above lone tiles, capped so old families don't jump
  // to the top. (concept ranking #6)
  static int _famBoost(int masters) =>
      masters < 3 ? 0 : (4 + (masters - 3) * 2).clamp(0, 12);

  Widget _familyGridSliver(List<Map<String, dynamic>> list) {
    // A family needs >=2 DISTINCT masters — a design's own Premium/Standard split
    // (same library_id) must not look like a family.
    final masters = <String, Set<String>>{};
    final firstPos = <String, int>{};
    for (var i = 0; i < list.length; i++) {
      final gk = _gkOf(list[i]);
      if (gk.isEmpty) continue;
      (masters[gk] ??= <String>{})
          .add((list[i]['library_id'] ?? list[i]['id'] ?? '').toString());
      firstPos.putIfAbsent(gk, () => i);
    }
    bool isFam(String gk) => gk.isNotEmpty && (masters[gk]?.length ?? 0) >= 2;

    // Order blocks (families + singles) by key = position − family boost, stable
    // on ties so unboosted order is preserved.
    final ordered =
        <({double key, int seq, bool fam, String gk, List<int> idx})>[];
    final seen = <String>{};
    var seq = 0;
    for (var i = 0; i < list.length; i++) {
      final gk = _gkOf(list[i]);
      if (isFam(gk)) {
        if (seen.contains(gk)) continue;
        seen.add(gk);
        final idx = [
          for (var j = 0; j < list.length; j++)
            if (_gkOf(list[j]) == gk) j
        ];
        ordered.add((
          key: (firstPos[gk]! - _famBoost(masters[gk]!.length)).toDouble(),
          seq: seq++,
          fam: true,
          gk: gk,
          idx: idx,
        ));
      } else {
        ordered.add((key: i.toDouble(), seq: seq++, fam: false, gk: '', idx: [i]));
      }
    }
    ordered.sort((a, b) {
      final c = a.key.compareTo(b.key);
      return c != 0 ? c : a.seq.compareTo(b.seq);
    });

    // Consecutive singles → one masonry run; each family → its band.
    final widgets = <Widget>[];
    var run = <Widget>[];
    void flush() {
      if (run.isEmpty) return;
      final items = run;
      run = [];
      widgets.add(_staggeredRun(items));
    }
    for (final b in ordered) {
      if (!b.fam) {
        run.add(_card(list[b.idx.first]));
        continue;
      }
      flush();
      widgets.add(_familyBand(b.gk, [for (final j in b.idx) _card(list[j])]));
    }
    flush();

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Column(
          children: [
            for (var i = 0; i < widgets.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              widgets[i],
            ],
          ],
        ),
      ),
    );
  }

  Widget _staggeredRun(List<Widget> items) => StaggeredGrid.count(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        children: [
          for (final w in items)
            StaggeredGridTile.fit(crossAxisCellCount: 1, child: w),
        ],
      );

  Widget _familyBand(String gk, List<Widget> members) {
    final color = _famColorFor(gk);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 1.4),
        borderRadius: BorderRadius.circular(14),
        color: color.withValues(alpha: 0.04),
      ),
      padding: const EdgeInsets.all(8),
      child: StaggeredGrid.count(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        children: [
          for (final w in members)
            StaggeredGridTile.fit(crossAxisCellCount: 1, child: w),
        ],
      ),
    );
  }

  Widget _card(Map<String, dynamic> d) {
    // Merged rep: a tile stocked in Premium and/or Standard. hasBoth → tap opens
    // the quality chooser; single-grade keeps the classic inline toggle/stepper.
    final premId = d['_premId'] == null ? null : '${d['_premId']}';
    final stdId = d['_stdId'] == null ? null : '${d['_stdId']}';
    final premBoxes = (d['_premBoxes'] as num?)?.toInt() ?? 0;
    final stdBoxes = (d['_stdBoxes'] as num?)?.toInt() ?? 0;
    final hasBoth = premId != null && stdId != null;
    final id = premId ?? stdId ?? '${d['id']}';
    final selected = (premId != null && _selected.containsKey(premId)) ||
        (stdId != null && _selected.containsKey(stdId));
    final qty = _selected[id] ?? 0;
    void handleTap() =>
        hasBoth ? _showQualityChoicePublic(d) : _toggle(id);
    final images = (d['images'] as List?) ?? const [];
    final img = images.isNotEmpty ? images.first.toString() : '';
    final finish = (d['finish'] ?? '').toString();
    final surface = (d['surface'] ?? '').toString();
    final finishChip =
        finish.isNotEmpty ? '$surface · $finish' : surface;
    // Match the in-app card: image follows the tile's real shape (e.g. 800x1600
    // -> 1:2 portrait, 1200x1800 -> 2:3), computed from the size, not a square.
    final ratio = aspectRatioFromSize((d['size'] ?? '').toString());

    return GestureDetector(
      onTap: handleTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: selected ? _brand : Colors.grey.shade200,
              width: selected ? 2 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                AspectRatio(
                  aspectRatio: ratio,
                  // Same widget the app uses: detects a portrait tile whose
                  // source photo was stored in landscape orientation and
                  // rotates it, instead of just cropping it half-off.
                  child: TileImage(url: img, tileAspectRatio: ratio, thumbWidth: 600),
                ),
                if (finishChip.isNotEmpty)
                  Positioned(
                    left: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.62),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(finishChip,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                Positioned(
                  top: 6,
                  left: 6,
                  child: GestureDetector(
                    onTap: () => _showDetail(d),
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.info_outline,
                          size: 16, color: Colors.white),
                    ),
                  ),
                ),
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: selected
                          ? _brand
                          : Colors.black.withValues(alpha: 0.35),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                        selected
                            ? Icons.check_rounded
                            : Icons.add_rounded,
                        size: 16,
                        color: Colors.white),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text((d['name'] ?? '').toString(),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    [
                      (d['size'] ?? '').toString().replaceAll(' mm', ''),
                      if (hasBoth)
                        'Premium & Standard'
                      else
                        (d['quality'] ?? '').toString(),
                    ].where((x) => x.isNotEmpty).join(' · '),
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  const SizedBox(height: 6),
                  if (hasBoth)
                    _mergedStockOrSel(d, premId, stdId, premBoxes, stdBoxes)
                  else if (selected)
                    _qtyStepper(id, qty)
                  else
                    Text('${d['boxes']} boxes in stock',
                        style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF2E7D32))),
                  DnaTagExpander(
                    tagsByAttribute: _dnaTagsFor(d),
                    isExpanded: _expandedDnaDesignId == id,
                    onToggleExpand: () => setState(() =>
                        _expandedDnaDesignId =
                            _expandedDnaDesignId == id ? null : id),
                    onCollapseIfExpanded: () {
                      if (_expandedDnaDesignId == id) {
                        setState(() => _expandedDnaDesignId = null);
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Merged card's bottom line: a Premium(amber)/Standard(blue) stock split, or —
  // when either grade is selected — a compact "Selected · P x · S y" summary that
  // reopens the quality chooser. (Scenario-2 buyer merge)
  Widget _mergedStockOrSel(Map<String, dynamic> d, String premId, String stdId,
      int premBoxes, int stdBoxes) {
    final selP = _selected[premId];
    final selS = _selected[stdId];
    if (selP != null || selS != null) {
      final parts = <String>[
        if (selP != null) 'P $selP',
        if (selS != null) 'S $selS',
      ];
      return GestureDetector(
        onTap: () => _showQualityChoicePublic(d),
        child: Row(
          children: [
            Icon(Icons.check_circle, size: 14, color: _brand),
            const SizedBox(width: 4),
            Expanded(
              child: Text('Selected · ${parts.join(' · ')}',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _brand),
                  overflow: TextOverflow.ellipsis),
            ),
            Icon(Icons.edit, size: 13, color: _brand),
          ],
        ),
      );
    }
    return Text.rich(
      TextSpan(children: [
        const TextSpan(
            text: 'P ', style: TextStyle(fontSize: 10, color: Color(0xFFF9A825))),
        TextSpan(
            text: '$premBoxes',
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Color(0xFFF9A825))),
        const TextSpan(text: '    '),
        const TextSpan(
            text: 'S ', style: TextStyle(fontSize: 10, color: Color(0xFF1565C0))),
        TextSpan(
            text: '$stdBoxes',
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1565C0))),
        const TextSpan(
            text: ' in stock',
            style: TextStyle(fontSize: 10, color: Colors.grey)),
      ]),
    );
  }

  // Quantity stepper shown on a selected card (boxes the buyer wants).
  Widget _qtyStepper(String id, int qty) {
    Widget btn(IconData icon, VoidCallback onTap) => InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: _brand.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(icon, size: 18, color: _brand),
          ),
        );
    return Row(
      children: [
        btn(Icons.remove, () => _setQty(id, qty - 1)),
        Expanded(
          child: GestureDetector(
            onTap: () => _editQty(id, qty),
            child: Text('$qty box${qty == 1 ? '' : 'es'}',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: _brand)),
          ),
        ),
        btn(Icons.add, () => _setQty(id, qty + 1)),
      ],
    );
  }
}

// Family (concept) strip inside the public detail popup. View-only here (the
// public catalog map has no library_id to navigate by) — shows every sibling
// variant with its stock, out-of-stock greyed, so the buyer sees the full set.
class _PublicFamilyStrip extends StatelessWidget {
  final String designId;
  final Color brand;
  const _PublicFamilyStrip({required this.designId, required this.brand});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: SupabaseDataService().designFamily(designId),
      builder: (_, snap) {
        final members = snap.data ?? const [];
        if (members.length < 2) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('COMPLETE THE FAMILY · ${members.length} DESIGNS',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.4,
                      color: brand)),
              const SizedBox(height: 8),
              for (final m in members) _row(m),
            ],
          ),
        );
      },
    );
  }

  Widget _row(Map<String, dynamic> m) {
    final name = (m['name'] ?? '').toString();
    final img = (m['image_url'] ?? '').toString();
    final size = (m['size'] ?? '').toString();
    final fStock = (m['f_stock'] as num?)?.toInt() ?? 0;
    final isCurrent = m['is_current'] == true;
    final inStock = fStock > 0;
    return Opacity(
      opacity: inStock ? 1.0 : 0.55,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: TileImage(
                    url: img,
                    tileAspectRatio: aspectRatioFromSize(size),
                    thumbWidth: 120),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13)),
                  ),
                  if (isCurrent) ...[
                    const SizedBox(width: 6),
                    Text('(this one)',
                        style: TextStyle(fontSize: 10.5, color: brand)),
                  ],
                ],
              ),
            ),
            Text(
              inStock ? '$fStock boxes' : 'Out of stock',
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: inStock
                      ? const Color(0xFF2E7D32)
                      : const Color(0xFFC62828)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable();
  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.link_off_rounded, size: 72, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text('Stock catalogue not available',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade600)),
            const SizedBox(height: 6),
            Text(
                'This link may be invalid or the stockist is currently inactive.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
          ],
        ),
      );
}

/// Pins a fixed-height widget (the search + filter row) to the top while the
/// banner and name bar scroll away beneath it.
class _PinnedHeader extends SliverPersistentHeaderDelegate {
  final double height;
  final Widget child;
  _PinnedHeader({required this.height, required this.child});

  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Material(color: const Color(0xFFF5F5F5), child: child);
  }

  @override
  bool shouldRebuild(_PinnedHeader old) =>
      old.height != height || old.child != child;
}
