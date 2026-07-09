import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../models/tile_design.dart';
import '../../services/supabase_data_service.dart';
import '../../services/supabase_auth_service.dart';
import '../../utils/tile_types.dart';
import '../../widgets/tile_card.dart';

class DesignDetailScreen extends StatefulWidget {
  final String designId;
  const DesignDetailScreen({super.key, required this.designId});

  @override
  State<DesignDetailScreen> createState() => _DesignDetailScreenState();
}

class _DesignDetailScreenState extends State<DesignDetailScreen> {
  final SupabaseDataService _service = SupabaseDataService();
  List<TileDesign> _designs = [];
  int _currentIndex = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await _service.getAllDesigns();
    // Include the buyer's private (claimed) designs: getAllDesigns() returns only
    // the PUBLIC market (empty when the public market is off), so a private-only
    // tile would otherwise be missing → empty list → RangeError → blank screen.
    final priv =
        isGuest ? <TileDesign>[] : await _service.getMyPrivateDesigns();
    final seen = <String>{};
    final combined = <TileDesign>[];
    for (final d in [...data, ...priv]) {
      if (seen.add(d.id)) combined.add(d);
    }
    if (!mounted) return;
    final idx = combined.indexWhere((d) => d.id == widget.designId);
    setState(() {
      _designs = combined;
      _currentIndex = idx >= 0 ? idx : 0;
      _loading = false;
    });
  }

  // Jump to a family member (given its library master id). Only in-stock
  // members are in _designs; out-of-stock ones aren't tappable (shown for
  // info only), so a no-match is a safe no-op.
  void _openLibrary(String libraryId) {
    final idx = _designs.indexWhere((d) => d.libraryId == libraryId);
    if (idx >= 0 && idx != _currentIndex) {
      setState(() => _currentIndex = idx);
    }
  }

  void _openFullImage(TileDesign design, List<String> urls, double ar) {
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) =>
          _FullImageView(urls: urls, aspectRatio: ar, title: design.name),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: const Text('Tile Details'),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_designs.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: const Text('Tile Details'),
        ),
        body: const Center(child: Text('Design not found or no longer in stock.')),
      );
    }

    final design = _designs[_currentIndex];
    final isFirst = _currentIndex == 0;
    final isLast = _currentIndex == _designs.length - 1;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Tile Details'),
      ),
      body: GestureDetector(
        onHorizontalDragEnd: (details) {
          final v = details.primaryVelocity ?? 0;
          if (v < -300 && !isLast) {
            setState(() => _currentIndex++);
          } else if (v > 300 && !isFirst) {
            setState(() => _currentIndex--);
          }
        },
        child: ListView(
          children: [
            // Height-capped, tappable hero image. Bounding the height keeps the
            // specs below visible without a long scroll; tapping opens a
            // full-screen zoomable view of the full tile.
            LayoutBuilder(builder: (ctx, constraints) {
              final ar = aspectRatioFromSize(design.size); // width ÷ height
              final maxH = MediaQuery.of(context).size.height * 0.42;
              double w = constraints.maxWidth;
              double h = w / ar;
              if (h > maxH) {
                h = maxH;
                w = h * ar;
              }
              final urls = design.faceImageUrls.isNotEmpty
                  ? design.faceImageUrls
                  : <String>[''];
              return GestureDetector(
                onTap: () => _openFullImage(design, urls, ar),
                child: Container(
                  color: Colors.grey.shade100,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: SizedBox(
                    width: w,
                    height: h,
                    child: Stack(
                      children: [
                        PageView.builder(
                          itemCount: urls.length,
                          itemBuilder: (_, i) =>
                              TileImage(url: urls[i], tileAspectRatio: ar),
                        ),
                        Positioned(
                          right: 8,
                          bottom: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.zoom_out_map_rounded,
                                    size: 13, color: Colors.white),
                                SizedBox(width: 4),
                                Text('Tap to view full',
                                    style: TextStyle(
                                        color: Colors.white, fontSize: 11)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: isFirst
                          ? null
                          : () => setState(() => _currentIndex--),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.arrow_back_ios, size: 14),
                          SizedBox(width: 6),
                          Text('Previous'),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      '${_currentIndex + 1} / ${_designs.length}',
                      style: const TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                  ),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: isLast
                          ? null
                          : () => setState(() => _currentIndex++),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Next'),
                          SizedBox(width: 6),
                          Icon(Icons.arrow_forward_ios, size: 14),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(design.name,
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),

                  // ── Size · Surface · Brand · Quality chips ───────────────
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _Chip(
                        icon: Icons.crop_free_rounded,
                        label: design.size,
                        bg: const Color(0xFFE3F2FD),
                        fg: const Color(0xFF1565C0),
                      ),
                      // Only attribute brands carry a surface of their own.
                      if (design.hasSurface)
                        _Chip(
                          icon: Icons.texture_rounded,
                          label: design.surfaceCardLabel,
                          bg: const Color(0xFFF3E5F5),
                          fg: const Color(0xFF6A1B9A),
                        ),
                      if (design.brandName.isNotEmpty)
                        _Chip(
                          icon: Icons.sell_outlined,
                          label: design.brandName,
                          bg: const Color(0xFFE0F2F1),
                          fg: const Color(0xFF00695C),
                        ),
                      if (design.quality.isNotEmpty)
                        _Chip(
                          icon: Icons.workspace_premium_outlined,
                          label: design.quality,
                          bg: design.quality == 'Premium'
                              ? const Color(0xFFFFF8E1)
                              : const Color(0xFFE3F2FD),
                          fg: design.quality == 'Premium'
                              ? const Color(0xFFB26206)
                              : const Color(0xFF1565C0),
                        ),
                      if (design.tileType.isNotEmpty)
                        _Chip(
                          icon: Icons.category_outlined,
                          label: design.tileType,
                          bg: const Color(0xFFE8F5E9),
                          fg: const Color(0xFF2E7D32),
                        ),
                      if (design.finishLabel != null &&
                          design.finishLabel!.isNotEmpty)
                        _Chip(
                          icon: Icons.label_outline_rounded,
                          label: design.finishLabel!,
                          bg: const Color(0xFFFFF3E0),
                          fg: const Color(0xFFE65100),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // ── Boxes highlight card ─────────────────────────────────
                  SizedBox(
                    width: double.infinity,
                    child: _StatCard(
                      icon: Icons.inventory_2_outlined,
                      value: '${design.boxQuantity}',
                      sub: 'Boxes Available',
                      color: const Color(0xFF1B4F72),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── Quality badge ────────────────────────────────────────
                  _QualityRow(quality: design.quality),
                  const SizedBox(height: 16),

                  // ── Grouped spec sections ────────────────────────────────
                  Builder(builder: (_) {
                    final sqft = sqftPerBox(design.size, design.piecesPerBox);
                    final tRange = thicknessRangeLabel(design.size,
                        design.piecesPerBox, design.boxWeightKg, design.tileType);
                    // Key specs are ALWAYS shown — '—' when the stockist hasn't
                    // entered weight/pieces yet (so the field never disappears).
                    final dimensions = <_Spec>[
                      _Spec(Icons.crop_free_rounded, 'Size', design.size),
                      _Spec(Icons.straighten_outlined, 'Thickness (approx)',
                          tRange ?? '—',
                          note: tRange != null ? kEmbossThicknessNote : null),
                      _Spec(Icons.square_foot_outlined, 'Sq.ft / Box',
                          sqft != null ? sqft.toStringAsFixed(2) : '—'),
                      _Spec(Icons.grid_view_rounded, 'Pieces / Box',
                          design.piecesPerBox > 0
                              ? '${design.piecesPerBox} pcs'
                              : '—'),
                      _Spec(Icons.scale_outlined, 'Box Weight',
                          design.boxWeightKg > 0
                              ? '${design.boxWeightKg} kg'
                              : '—'),
                    ];
                    final material = <_Spec>[
                      _Spec(Icons.category_outlined, 'Tile Type',
                          design.tileType.isNotEmpty ? design.tileType : '—'),
                      _Spec(Icons.texture_rounded, 'Finish',
                          design.hasSurface ? design.surfaceCardLabel : '—'),
                      _Spec(Icons.palette_outlined, 'Colour',
                          design.colour.isNotEmpty ? design.colour : '—'),
                    ];
                    final commercial = <_Spec>[
                      _Spec(Icons.sell_outlined, 'Stock Type', design.stockType),
                      if (!isGuest)
                        _Spec(Icons.storefront_outlined, 'Stockist ID',
                            design.stockistId),
                    ];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _specGroup('DIMENSIONS', dimensions),
                        const SizedBox(height: 16),
                        _specGroup('MATERIAL', material),
                        const SizedBox(height: 16),
                        _specGroup('COMMERCIAL', commercial),
                      ],
                    );
                  }),

                  // ── Design DNA (searchable tags, in the stockist's words) ──
                  _DnaSection(
                      key: ValueKey(design.id),
                      designId: design.id,
                      service: _service),

                  // ── Family (concept) — sibling variants + their stock ──
                  _FamilySection(
                      key: ValueKey('fam_${design.id}'),
                      designId: design.id,
                      service: _service,
                      onOpenLibrary: _openLibrary),

                  const SizedBox(height: 24),

                  // Guests can't reach the stockist (ID, contact, portfolio).
                  if (isGuest)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1B4F72).withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: const Color(0xFF1B4F72).withValues(alpha: 0.2)),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.lock_outline,
                              size: 18, color: Color(0xFF1B4F72)),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                                'Register and get approved to view the stockist, '
                                'contact them, and place orders.',
                                style: TextStyle(
                                    fontSize: 12.5, color: Color(0xFF1B4F72))),
                          ),
                        ],
                      ),
                    )
                  else
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => context
                            .push('/stockist/${design.stockistId}/portfolio'),
                        icon: const Icon(Icons.storefront_outlined),
                        label: const Text('View Stockist Portfolio'),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Full-screen zoomable image view ────────────────────────────────────────────

class _FullImageView extends StatelessWidget {
  final List<String> urls;
  final double aspectRatio;
  final String title;
  const _FullImageView(
      {required this.urls, required this.aspectRatio, required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(title, style: const TextStyle(fontSize: 16)),
      ),
      body: PageView.builder(
        itemCount: urls.length,
        itemBuilder: (_, i) => InteractiveViewer(
          minScale: 1,
          maxScale: 5,
          child: Center(
            child: AspectRatio(
              aspectRatio: aspectRatio,
              child: TileImage(url: urls[i], tileAspectRatio: aspectRatio),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Design DNA section ──────────────────────────────────────────────────────
// Loads the design's DNA tags (shown in the design's own stockist's words) and
// renders them grouped by attribute. Renders nothing when the design is untagged.
class _DnaSection extends StatelessWidget {
  final String designId;
  final SupabaseDataService service;
  const _DnaSection(
      {super.key, required this.designId, required this.service});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<({String attribute, String label})>>(
      future: service.designDnaTags(designId),
      builder: (_, snap) {
        final tags = snap.data ?? const [];
        if (tags.isEmpty) return const SizedBox.shrink();
        // Group labels by attribute, preserving server order.
        final byAttr = <String, List<String>>{};
        for (final t in tags) {
          (byAttr[t.attribute] ??= []).add(t.label);
        }
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 0, 0, 8),
                child: Text('DESIGN DNA',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                        color: Color(0xFF8A5A09))),
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFB9770E).withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: const Color(0xFFB9770E).withValues(alpha: 0.18)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: byAttr.entries.map((e) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.key.toUpperCase(),
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.grey.shade600)),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: e.value
                                .map((label) => Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 9, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(
                                            color: const Color(0xFFB9770E)
                                                .withValues(alpha: 0.3)),
                                      ),
                                      child: Text(label,
                                          style: const TextStyle(
                                              fontSize: 12.5,
                                              color: Color(0xFF8A5A09),
                                              fontWeight: FontWeight.w600)),
                                    ))
                                .toList(),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Family (concept) section ────────────────────────────────────────────────
// Tiles sold as a coordinated set (1801-A / 1801-B, 1305 Light / Dark / HL).
// Shows every sibling variant with its live stock — including out-of-stock
// members (greyed) so the buyer can see the whole concept and decide. Hidden
// when the design has no siblings.
class _FamilySection extends StatelessWidget {
  final String designId;
  final SupabaseDataService service;
  final void Function(String libraryId) onOpenLibrary;
  const _FamilySection(
      {super.key,
      required this.designId,
      required this.service,
      required this.onOpenLibrary});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: service.designFamily(designId),
      builder: (_, snap) {
        final members = snap.data ?? const [];
        if (members.length < 2) return const SizedBox.shrink();
        const navy = Color(0xFF1B4F72);
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 0, 8),
                child: Text('COMPLETE THE FAMILY · ${members.length} DESIGNS',
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                        color: navy)),
              ),
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: navy.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: navy.withValues(alpha: 0.15)),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (var i = 0; i < members.length; i++)
                      _familyRow(context, members[i], last: i == members.length - 1),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _familyRow(BuildContext context, Map<String, dynamic> m,
      {required bool last}) {
    const navy = Color(0xFF1B4F72);
    final libId = '${m['library_id']}';
    final name = (m['name'] ?? '').toString();
    final img = (m['image_url'] ?? '').toString();
    final size = (m['size'] ?? '').toString();
    final fStock = (m['f_stock'] as num?)?.toInt() ?? 0;
    final isCurrent = m['is_current'] == true;
    final inStock = fStock > 0;
    final ratio = aspectRatioFromSize(size);

    return InkWell(
      onTap: inStock && !isCurrent ? () => onOpenLibrary(libId) : null,
      child: Opacity(
        opacity: inStock ? 1.0 : 0.55,
        child: Container(
          decoration: BoxDecoration(
            border: last
                ? null
                : Border(
                    bottom: BorderSide(color: navy.withValues(alpha: 0.10))),
          ),
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              SizedBox(
                width: 46,
                height: 46,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: TileImage(
                      url: img, tileAspectRatio: ratio, thumbWidth: 120),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 13.5)),
                        ),
                        if (isCurrent) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                                color: navy.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(4)),
                            child: const Text('This one',
                                style: TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w600,
                                    color: navy)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      inStock ? '$fStock boxes in stock' : 'Out of stock',
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
              if (inStock && !isCurrent)
                const Icon(Icons.chevron_right, size: 18, color: navy),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Chip ──────────────────────────────────────────────────────────────────────

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color bg;
  final Color fg;
  const _Chip({required this.icon, required this.label, required this.bg, required this.fg});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 13, color: fg, fontWeight: FontWeight.w600)),
          ],
        ),
      );
}

// ── Stat card ─────────────────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String value;
  final String sub;
  final Color color;
  const _StatCard({required this.icon, required this.value, required this.sub, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
                Text(sub, style: TextStyle(fontSize: 10, color: color.withValues(alpha: 0.8))),
              ],
            ),
          ],
        ),
      );
}

// ── Quality row ───────────────────────────────────────────────────────────────

class _QualityRow extends StatelessWidget {
  final String quality;
  const _QualityRow({required this.quality});

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    final IconData icon;

    switch (quality.toLowerCase()) {
      case 'premium':
        bg = const Color(0xFFFFF8E1); fg = const Color(0xFFF9A825); icon = Icons.star_rounded;
        break;
      case 'both':
        bg = const Color(0xFFE8F5E9); fg = const Color(0xFF2E7D32); icon = Icons.layers_outlined;
        break;
      default:
        bg = const Color(0xFFE3F2FD); fg = const Color(0xFF1565C0); icon = Icons.verified_outlined;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
      child: Row(
        children: [
          Icon(icon, size: 18, color: fg),
          const SizedBox(width: 8),
          Text('Quality', style: TextStyle(fontSize: 12, color: fg.withValues(alpha: 0.8))),
          const SizedBox(width: 6),
          Text(quality,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: fg)),
        ],
      ),
    );
  }
}

// ── Detail row ────────────────────────────────────────────────────────────────

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _DetailRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 18, color: const Color(0xFF1B4F72)),
            const SizedBox(width: 12),
            Text(label,
                style: const TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w500)),
            const Spacer(),
            Text(value,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1A1A1A))),
          ],
        ),
      );
}

Widget _divider() => Divider(height: 1, indent: 44, endIndent: 0, color: Colors.grey.shade200);

// One spec line for a grouped section. [note] renders a small italic caption
// under the row (used for the emboss thickness caveat).
class _Spec {
  final IconData icon;
  final String label;
  final String value;
  final String? note;
  const _Spec(this.icon, this.label, this.value, {this.note});
}

// A titled spec group: an UPPERCASE section header above a card of _DetailRows
// (dividers auto-inserted). Empty groups render nothing.
Widget _specGroup(String title, List<_Spec> specs) {
  if (specs.isEmpty) return const SizedBox.shrink();
  final rows = <Widget>[];
  for (var i = 0; i < specs.length; i++) {
    if (i > 0) rows.add(_divider());
    final s = specs[i];
    rows.add(_DetailRow(icon: s.icon, label: s.label, value: s.value));
    if (s.note != null) {
      rows.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Text(s.note!,
            style: TextStyle(
                fontSize: 10,
                fontStyle: FontStyle.italic,
                color: Colors.grey.shade500)),
      ));
    }
  }
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 0, 8),
        child: Text(title,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
                color: Colors.grey.shade600)),
      ),
      Container(
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Column(children: rows),
      ),
    ],
  );
}
