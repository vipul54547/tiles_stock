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

                  // ── Size & Surface chips ─────────────────────────────────
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
                      _Chip(
                        icon: Icons.texture_rounded,
                        label: design.surfaceType,
                        bg: const Color(0xFFF3E5F5),
                        fg: const Color(0xFF6A1B9A),
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
                          design.surfaceType),
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
