import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../services/supabase_data_service.dart';
import '../models/tile_design.dart' show expandSearchTerms;

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
  List<Map<String, dynamic>> _all = [];

  // Selection: designId -> box quantity wanted.
  final Map<String, int> _selected = {};

  // Search + filters
  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _smart = true;
  final Set<String> _fSizes = {};
  final Set<String> _fFinishes = {};
  final Set<String> _fQualities = {};
  final Set<String> _fTypes = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
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
      _all = ((data['designs'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      _loading = false;
    });
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
      _fSizes.length + _fFinishes.length + _fQualities.length + _fTypes.length;

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
    return r.toList();
  }

  // ── Selection ────────────────────────────────────────────────────────────

  void _toggle(String id) => setState(() {
        if (_selected.containsKey(id)) {
          _selected.remove(id);
        } else {
          _selected[id] = 1;
        }
      });

  void _setQty(String id, int q) => setState(() {
        if (q <= 0) {
          _selected.remove(id);
        } else {
          _selected[id] = q;
        }
      });

  // ── WhatsApp enquiry (lists the selected designs) ──────────────────────────

  Future<void> _enquire() async {
    final phone =
        '${_stockist['country_code'] ?? '+91'}${_stockist['phone'] ?? ''}'
            .replaceAll(RegExp(r'[^0-9]'), '');
    final name = (_stockist['name'] ?? '').toString();

    final lines = <String>[];
    if (_selected.isEmpty) {
      lines.add('Hello $name, I saw your catalog and would like to enquire '
          'about some designs.');
    } else {
      lines.add('Hello $name, I would like to enquire about these designs '
          'from your catalog:');
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
    final msg = lines.join('\n');
    final uri = phone.isEmpty
        ? Uri.parse('https://wa.me/?text=${Uri.encodeComponent(msg)}')
        : Uri.parse('https://wa.me/$phone?text=${Uri.encodeComponent(msg)}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
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
          Widget section(String title, List<String> opts, Set<String> sel) {
            if (opts.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 6),
                Wrap(
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
                const SizedBox(height: 14),
              ],
            );
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
                    Row(
                      children: [
                        const Text('Filters',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16)),
                        const Spacer(),
                        TextButton(
                          onPressed: () => setSheet(() {
                            _fSizes.clear();
                            _fFinishes.clear();
                            _fQualities.clear();
                            _fTypes.clear();
                          }),
                          child: const Text('Clear all'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    section('Size', _distinct('size'), _fSizes),
                    section('Finish', _distinct('surface'), _fFinishes),
                    section('Quality', _distinct('quality'), _fQualities),
                    section('Tile Type', _distinct('tile_type'), _fTypes),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          setState(() {});
                          Navigator.pop(ctx);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1B4F72),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: const Text('Show results'),
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
          SliverAppBar(
            pinned: true,
            backgroundColor: const Color(0xFF1B4F72),
            foregroundColor: Colors.white,
            title: Text(_stockist['name']?.toString() ?? 'Catalog'),
          ),
          SliverToBoxAdapter(child: _searchRow()),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text(
                '${list.length} of ${_all.length} designs'
                '${(_stockist['city'] ?? '').toString().isNotEmpty ? ' · ${_stockist['city']}' : ''}',
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
          ),
          if (list.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                  child: Text('No designs match.',
                      style: TextStyle(color: Colors.grey))),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 100),
              sliver: SliverMasonryGrid.count(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childCount: list.length,
                itemBuilder: (_, i) => _card(list[i]),
              ),
            ),
        ],
      ),
      bottomNavigationBar: _enquireBar(),
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
                color: _smart ? const Color(0xFF1B4F72) : Colors.grey.shade200,
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
                    ? const Color(0xFF1B4F72)
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
                  color: count == 0 ? Colors.grey : const Color(0xFF1B4F72)),
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

    return GestureDetector(
      onTap: () => _toggle(id),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: selected ? const Color(0xFF1B4F72) : Colors.grey.shade200,
              width: selected ? 2 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: img.isEmpty
                      ? Container(
                          color: Colors.grey.shade100,
                          child: Icon(Icons.image_not_supported,
                              size: 32, color: Colors.grey.shade400))
                      : CachedNetworkImage(
                          imageUrl: img,
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
                  right: 6,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFF1B4F72)
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
              color: const Color(0xFF1B4F72).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(icon, size: 18, color: const Color(0xFF1B4F72)),
          ),
        );
    return Row(
      children: [
        btn(Icons.remove, () => _setQty(id, qty - 1)),
        Expanded(
          child: Text('$qty box${qty == 1 ? '' : 'es'}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1B4F72))),
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
            Text('Catalog not available',
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
