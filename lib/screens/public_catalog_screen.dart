import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
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
import '../utils/banner_layout.dart' show effectiveCompanyPos;
import '../widgets/filter_section.dart';

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
      (_minQtyCtrl.text.trim().isNotEmpty ? 1 : 0) +
      (_maxQtyCtrl.text.trim().isNotEmpty ? 1 : 0);

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
        final hay =
            '${d['name'] ?? ''} ${d['surface'] ?? ''} ${d['finish'] ?? ''}'
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

  // Manual quantity entry — tapping the number opens this so the buyer can type
  // a large box count directly instead of holding the +/- steppers.
  Future<void> _editQty(String id, int current) async {
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
    if (value != null && value > 0) _setQty(id, value);
  }

  // ── WhatsApp enquiry (lists the selected designs) ──────────────────────────

  Future<void> _enquire() async {
    final phone =
        '${_stockist['country_code'] ?? '+91'}${_stockist['phone'] ?? ''}'
            .replaceAll(RegExp(r'[^0-9]'), '');
    final name = (_stockist['name'] ?? '').toString();
    final sid = (_stockist['id'] ?? '').toString();
    final who = sid.isNotEmpty ? '$name ($sid)' : name;

    final lines = <String>[];
    if (_selected.isEmpty) {
      lines.add('Hello $who, I saw your stock catalogue and would like to enquire '
          'about some designs.');
    } else {
      lines.add('Hello $who, I would like to enquire about these designs '
          'from your stock catalogue:');
      lines.add('');
      var n = 1;
      for (final d in _all) {
        final id = '${d['id']}';
        if (!_selected.containsKey(id)) continue;
        final qty = _selected[id]!;
        final desc = [
          (d['name'] ?? '').toString(),
          (d['size'] ?? '').toString().replaceAll(' mm', ''),
          (d['surface'] ?? '').toString(),
        ].where((x) => x.isNotEmpty).join(' · ');
        lines.add('${n++}. $desc — $qty box${qty == 1 ? '' : 'es'}');
      }
    }
    // Record this link enquiry (which catalog/visibility, selected designs) so
    // the stockist/admin can see demand coming via links. Best-effort.
    _svc.logLinkInquiry(widget.token, _selected.keys.toList());

    lines.add('');
    lines.add('— Powered by TilesDesign');
    final msg = lines.join('\n');
    final uri = phone.isEmpty
        ? Uri.parse('https://wa.me/?text=${Uri.encodeComponent(msg)}')
        : Uri.parse('https://wa.me/$phone?text=${Uri.encodeComponent(msg)}');

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
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
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
                        setSheet(() => v ? sel.add(o) : sel.remove(o)),
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

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 16,
                  bottom: 16 + MediaQuery.of(ctx).viewInsets.bottom),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header: title + Apply (top) + Clear all.
                    Row(
                      children: [
                        const Text('Filters',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16)),
                        const Spacer(),
                        FilledButton(
                          onPressed: () {
                            setState(() {});
                            Navigator.pop(ctx);
                          },
                          style: FilledButton.styleFrom(
                              backgroundColor: _brand,
                              foregroundColor: Colors.white,
                              visualDensity: VisualDensity.compact,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 20)),
                          child: const Text('Apply'),
                        ),
                        const SizedBox(width: 6),
                        TextButton(
                          onPressed: () => setSheet(() {
                            _fSizes.clear();
                            _fFinishes.clear();
                            _fQualities.clear();
                            _fTypes.clear();
                            _fThickness.clear();
                            _fStockTypes.clear();
                            _minQtyCtrl.clear();
                            _maxQtyCtrl.clear();
                          }),
                          child: const Text('Clear all',
                              style: TextStyle(color: Colors.red)),
                        ),
                      ],
                    ),
                    const Divider(height: 16),
                    // Quantity (collapsible).
                    FilterSection(
                      title: 'Quantity (boxes)',
                      summary: qtySummary(),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _minQtyCtrl,
                              keyboardType: TextInputType.number,
                              onChanged: (_) => setSheet(() {}),
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
                              onChanged: (_) => setSheet(() {}),
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
                    section('Size', _distinct('size'), _fSizes),
                    section('Finish', _distinct('surface'), _fFinishes),
                    section('Quality', _distinct('quality'), _fQualities),
                    section('Tile Type', _distinct('tile_type'), _fTypes),
                    section('Thickness (approx)', _thicknessBands(), _fThickness),
                    section('Stock Type', _distinct('stock_type'), _fStockTypes),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          );
        },
      ),
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
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: CustomScrollView(
        slivers: [
          // Name bar scrolls away (not pinned) — the brand identity lives on the
          // banner; the buyer gets the full screen for designs while browsing.
          SliverAppBar(
            pinned: false,
            floating: false,
            backgroundColor: _brand,
            foregroundColor: Colors.white,
            title: Text(
                (_brandInfo['name'] ?? '').toString().isNotEmpty
                    ? _brandInfo['name'].toString()
                    : (_stockist['name']?.toString() ?? 'Stock Catalogue')),
          ),
          SliverToBoxAdapter(child: _bannerArea()),
          // Search + filter row stays PINNED so it's always reachable while scrolling.
          SliverPersistentHeader(
            pinned: true,
            delegate: _PinnedHeader(height: 60, child: _searchRow()),
          ),
          SliverToBoxAdapter(child: _metaRow(list.length)),
          if (list.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                  child: Text('No designs match.',
                      style: TextStyle(color: Colors.grey))),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              sliver: SliverMasonryGrid.count(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childCount: list.length,
                itemBuilder: (_, i) => _card(list[i]),
              ),
            ),
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
  // Maps a placement key to an Alignment for overlay positioning.
  static Alignment _alignFor(String pos) {
    switch (pos) {
      case 'top-left':
        return Alignment.topLeft;
      case 'top-center':
        return Alignment.topCenter;
      case 'top-right':
        return Alignment.topRight;
      case 'middle-left':
        return Alignment.centerLeft;
      case 'center':
        return Alignment.center;
      case 'middle-right':
        return Alignment.centerRight;
      case 'bottom-left':
        return Alignment.bottomLeft;
      case 'bottom-center':
      case 'footer':
        return Alignment.bottomCenter;
      case 'bottom-right':
        return Alignment.bottomRight;
      default:
        return Alignment.center;
    }
  }

  Widget _bannerArea() {
    final source = (_banner['source'] ?? 'pool').toString();
    final bg = (_banner['bg_url'] ?? _banner['image_url'] ?? '').toString();
    final companyLogo = (_banner['company_logo_url'] ?? '').toString();
    // Big NAME (no logo) never uses the middle row — coerce legacy values down.
    final companyPos = effectiveCompanyPos(
        (_banner['company_pos'] ?? 'none').toString(),
        hasLogo: companyLogo.isNotEmpty);
    final tdPos = (_banner['td_pos'] ?? 'footer').toString();
    final name = (_banner['name'] ?? _stockist['name'] ?? '').toString();
    final topRow = companyPos == 'top-left' ||
        companyPos == 'top-center' ||
        companyPos == 'top-right';
    // Welcome text: pool always; library only when the company is NOT on the top
    // row (top logo hides Welcome); upload never (the design is self-contained).
    final showWelcome = source == 'pool' || (source == 'library' && !topRow);
    final showCompany = source == 'library' && companyPos != 'none';

    return LayoutBuilder(
      builder: (context, c) {
        final h = (c.maxWidth / 2.5).clamp(0.0, 200.0);
        return SizedBox(
          width: double.infinity,
          height: h,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Background
              if (bg.isNotEmpty)
                Image.network(bg,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _bannerGradient())
              else
                _bannerGradient(),
              // Company logo or big name (library path)
              if (showCompany)
                Align(
                  alignment: _alignFor(companyPos),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: _scrim(
                      companyLogo.isNotEmpty
                          ? Image.network(companyLogo,
                              height: h * 0.40, fit: BoxFit.contain)
                          : Text(
                              name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: (h * 0.20).clamp(16.0, 34.0),
                                  fontWeight: FontWeight.bold,
                                  shadows: const [
                                    Shadow(blurRadius: 4, color: Colors.black87)
                                  ]),
                            ),
                    ),
                  ),
                ),
              // TilesDesign logo (library/upload). Pool shows it in the trust strip.
              if (source != 'pool')
                Align(
                  alignment: _alignFor(tdPos),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: _scrim(Image.asset(
                        tdPos == 'footer'
                            ? 'assets/brand/tilesdesign_wide.png'
                            : 'assets/brand/tilesdesign_square.png',
                        height: tdPos == 'footer' ? h * 0.16 : h * 0.22)),
                  ),
                ),
              // Welcome / Powered-by trust strip
              if (showWelcome) _trustStrip(name, poweredBy: source == 'pool'),
            ],
          ),
        );
      },
    );
  }

  // A subtle translucent backing so an overlay stays legible on any art.
  Widget _scrim(Widget child) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.28),
          borderRadius: BorderRadius.circular(6),
        ),
        child: child,
      );

  // Brand-colour gradient shown when no banner image is configured yet.
  Widget _bannerGradient() => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [_brand, Color.lerp(_brand, Colors.black, 0.35)!],
          ),
        ),
      );

  // System trust strip for generic/anonymous banners: centred "Welcome to
  // [name]" + right "Powered by TilesDesign", over a dark scrim for readability.
  Widget _trustStrip(String name, {bool poweredBy = true}) => Align(
        alignment: Alignment.topCenter,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xB3000000), Color(0x00000000)],
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 86),
                child: Text(
                  name.trim().isEmpty ? 'Welcome' : 'Welcome to $name',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      shadows: [Shadow(blurRadius: 4, color: Colors.black54)]),
                ),
              ),
              if (poweredBy)
                const Align(
                  alignment: Alignment.centerRight,
                  child: Text('Powered by TilesDesign',
                      style: TextStyle(
                          color: Colors.white70,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600)),
                ),
            ],
          ),
        ),
      );

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

  // Footer credit shown at the bottom of every catalog page. On the WEB build we
  // also show a quiet "download the app" nudge — buyers reaching this page in a
  // browser (no app) get sent to the right store for their device. Hidden in the
  // app itself and until at least one store link is configured.
  Widget _poweredBy() {
    final showNudge = kIsWeb && AppConfig.hasAnyStoreLink;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 8, 16, 16 + MediaQuery.viewPaddingOf(context).bottom),
      child: Column(
        children: [
          if (showNudge) ...[
            GestureDetector(
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
                          style: TextStyle(
                              fontWeight: FontWeight.bold, color: _brand),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          Text('Powered by TilesDesign',
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade500,
                  letterSpacing: 0.3)),
        ],
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

  Widget _card(Map<String, dynamic> d) {
    final id = '${d['id']}';
    final selected = _selected.containsKey(id);
    final qty = _selected[id] ?? 0;
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
      onTap: () => _toggle(id),
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
                  child: img.isEmpty
                      ? Container(
                          color: Colors.grey.shade100,
                          child: Icon(Icons.image_not_supported,
                              size: 32, color: Colors.grey.shade400))
                      : CachedNetworkImage(
                          // Grid card → lightweight Cloudinary thumbnail.
                          imageUrl: CloudinaryService.thumbUrl(img, width: 600),
                          fit: BoxFit.cover,
                          placeholder: (_, __) =>
                              Container(color: Colors.grey.shade200),
                          errorWidget: (_, __, ___) => Container(
                              color: Colors.grey.shade200,
                              child: const Icon(Icons.broken_image)),
                        ),
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
                      (d['quality'] ?? '').toString(),
                    ].where((x) => x.isNotEmpty).join(' · '),
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  const SizedBox(height: 6),
                  if (selected)
                    _qtyStepper(id, qty)
                  else
                    Text('${d['boxes']} boxes in stock',
                        style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF2E7D32))),
                ],
              ),
            ),
          ],
        ),
      ),
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
