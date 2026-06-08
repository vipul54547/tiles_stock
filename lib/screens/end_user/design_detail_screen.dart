import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../models/tile_design.dart';
import '../../services/supabase_data_service.dart';
import '../../services/supabase_auth_service.dart';
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
    final idx = data.indexWhere((d) => d.id == widget.designId);
    setState(() {
      _designs = data;
      _currentIndex = idx >= 0 ? idx : 0;
      _loading = false;
    });
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
            AspectRatio(
              aspectRatio: aspectRatioFromSize(design.size),
              child: PageView.builder(
                itemCount: design.faceImageUrls.isNotEmpty
                    ? design.faceImageUrls.length
                    : 1,
                itemBuilder: (_, i) => TileImage(
                  url: design.faceImageUrls.isNotEmpty
                      ? design.faceImageUrls[i]
                      : '',
                ),
              ),
            ),
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

                  // ── Boxes & Price highlight cards ────────────────────────
                  Row(
                    children: [
                      Expanded(
                        child: _StatCard(
                          icon: Icons.inventory_2_outlined,
                          value: '${design.boxQuantity}',
                          sub: 'Boxes Available',
                          color: const Color(0xFF1B4F72),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _StatCard(
                          icon: Icons.currency_rupee_rounded,
                          value: design.boxPrice.toStringAsFixed(0),
                          sub: 'Price / Box',
                          color: const Color(0xFF2E7D32),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // ── Quality badge ────────────────────────────────────────
                  _QualityRow(quality: design.quality),
                  const SizedBox(height: 16),

                  // ── Secondary details grid ───────────────────────────────
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Column(
                      children: [
                        _DetailRow(
                          icon: Icons.scale_outlined,
                          label: 'Box Weight',
                          value: '${design.boxWeightKg} kg',
                        ),
                        _divider(),
                        _DetailRow(
                          icon: Icons.grid_view_rounded,
                          label: 'Pieces / Box',
                          value: '${design.piecesPerBox} pcs',
                        ),
                        _divider(),
                        _DetailRow(
                          icon: Icons.palette_outlined,
                          label: 'Colour',
                          value: design.colour,
                        ),
                        // Stockist ID is hidden from guests.
                        if (!isGuest) ...[
                          _divider(),
                          _DetailRow(
                            icon: Icons.storefront_outlined,
                            label: 'Stockist ID',
                            value: design.stockistId,
                          ),
                        ],
                      ],
                    ),
                  ),
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
