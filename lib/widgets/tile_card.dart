import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/tile_design.dart';
import '../utils/tile_sizes.dart';
import '../utils/surface_labels.dart';
import '../services/supabase_auth_service.dart';
import '../services/cloudinary_service.dart';
import 'dna_tag_expander.dart';

export '../utils/tile_sizes.dart' show aspectRatioFromSize, kAllowedSizes;

class TileCard extends StatelessWidget {
  final TileDesign design;
  final VoidCallback onTap;
  final VoidCallback? onStockistTap;
  final bool isChosen;
  final VoidCallback? onChoiceTap;
  /// Quality badge on the card. Stockists hide it (they have a quality filter,
  /// and it crowds the box count); buyers keep it.
  final bool showQuality;
  /// Stockist's own dashboard: show the P · C · H · F figures instead of a single
  /// "boxes" count. Buyers keep the single count (which is already F_Stock).
  /// (project_fstock_model)
  final bool showControlFigures;
  /// Overrides the title shown on the card. Used when the dashboard is filtered
  /// to a single brand so an M box shows THAT brand's name (its alias) instead of
  /// the brand-agnostic master name. Null → falls back to [design.name].
  final String? displayName;

  /// Scenario-2 buyer merge: box split for a quality-merged buyer card. When
  /// EITHER is non-null the card renders in "merged" mode — the single boxes
  /// count is replaced by a Premium(amber)/Standard(blue) split, and the quality
  /// badge shows Both / Premium / Standard accordingly. A null grade is a grade
  /// this tile isn't stocked in (not shown). Ignored when [showControlFigures].
  final int? premiumBoxes;
  final int? standardBoxes;

  /// This design's DNA tags grouped by attribute name (e.g. {"Series":
  /// ["Monochrome"]}), for the expandable ▾ tag section. Null/empty → no
  /// arrow shown at all.
  final Map<String, List<String>>? dnaTagsByAttribute;
  final bool isDnaExpanded;
  final VoidCallback? onToggleDnaExpand;
  final VoidCallback? onCollapseDnaIfExpanded;

  const TileCard({
    super.key,
    required this.design,
    required this.onTap,
    this.onStockistTap,
    this.isChosen = false,
    this.onChoiceTap,
    this.showQuality = true,
    this.showControlFigures = false,
    this.displayName,
    this.premiumBoxes,
    this.standardBoxes,
    this.dnaTagsByAttribute,
    this.isDnaExpanded = false,
    this.onToggleDnaExpand,
    this.onCollapseDnaIfExpanded,
  });

  // P (physical) · C (held back) · H (booked) · F (shown to dealers), colour-coded.
  // H is 0 until the booking system exists (Phase 2). (project_fstock_model)
  Widget _controlFigures() {
    Widget fig(String label, int value, Color color) => Text.rich(
          TextSpan(children: [
            TextSpan(
                text: '$label ',
                style: TextStyle(
                    fontSize: 9, color: color.withValues(alpha: 0.75))),
            TextSpan(
                text: '$value',
                style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.bold, color: color)),
          ]),
        );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        fig('P', design.boxQuantity, Colors.grey.shade600),
        fig('C', design.controlQuantity, const Color(0xFFEF6C00)),
        fig('H', design.heldQuantity, const Color(0xFF1565C0)),
        fig('F', design.fStock, const Color(0xFF2E7D32)),
      ],
    );
  }

  // Scenario-2 buyer merge: this card folds Premium+Standard into one.
  bool get _merged =>
      !showControlFigures && (premiumBoxes != null || standardBoxes != null);

  // Derived badge for a merged card: Both when the tile is stocked in both
  // grades, else the single grade it carries.
  String get _mergedQuality => (premiumBoxes ?? 0) > 0 && (standardBoxes ?? 0) > 0
      ? 'Both'
      : premiumBoxes != null
          ? 'Premium'
          : 'Standard';

  // Boxes line for a merged card: P n (amber) · S m (blue), only the grades
  // this tile is actually stocked in.
  Widget _mergedBoxes() {
    Widget grade(String label, int n, Color c) => Text.rich(TextSpan(children: [
          TextSpan(
              text: '$label ',
              style: TextStyle(fontSize: 9, color: c.withValues(alpha: 0.8))),
          TextSpan(
              text: '$n',
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.bold, color: c)),
        ]));
    final parts = <Widget>[
      if (premiumBoxes != null)
        grade('P', premiumBoxes!, const Color(0xFFF9A825)),
      if (standardBoxes != null)
        grade('S', standardBoxes!, const Color(0xFF1565C0)),
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < parts.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          parts[i],
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ratio = aspectRatioFromSize(design.size);

    return GestureDetector(
      onTap: onTap,
      child: Card(
        elevation: 2,
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                AspectRatio(
                  aspectRatio: ratio,
                  // Grid card → load a lightweight thumbnail, not the full-size
                  // original (which is reserved for the detail/zoom view).
                  child: TileImage(
                    url: design.faceImageUrls.isNotEmpty
                        ? design.faceImageUrls.first
                        : '',
                    tileAspectRatio: ratio,
                    thumbWidth: 600,
                  ),
                ),
                // Finish chip over the image: the standard finish (surface_type),
                // plus the stockist's own wording (finish_label, e.g. "Punch Ghr",
                // "Lustra") when the design has one. Omitted entirely when the
                // design has neither — in-name brands keep the surface in the
                // name. (project_per_brand_surface_mode)
                if (design.hasSurface ||
                    (design.finishLabel?.isNotEmpty ?? false))
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
                      child: Text(
                        [
                          if (design.hasSurface)
                            surfaceLabels.label(
                                design.stockistId, design.surfaceType),
                          if (design.finishLabel?.isNotEmpty ?? false)
                            design.finishLabel!,
                        ].join(' · '),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                if (onChoiceTap != null)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onChoiceTap,
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          color: isChosen
                              ? const Color(0xFF1B4F72)
                              : Colors.black.withValues(alpha: 0.35),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          isChosen
                              ? Icons.bookmark_rounded
                              : Icons.bookmark_outline_rounded,
                          size: 15,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Design name (brand-specific alias when supplied, else master)
                  Text(displayName != null && displayName!.isNotEmpty
                          ? displayName!
                          : design.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 3),
                  // Size  +  quality badge on same row (finish now shown as a
                  // chip over the image, so it isn't repeated/truncated here).
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          design.size.replaceAll(' mm', ''),
                          style: TextStyle(
                              color: Colors.grey[600], fontSize: 10),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (showQuality) ...[
                        const SizedBox(width: 4),
                        _QualityBadge(
                            quality: _merged ? _mergedQuality : design.quality),
                      ],
                    ],
                  ),
                  const SizedBox(height: 5),
                  // Boxes count  +  stockist ID
                  if (showControlFigures) _controlFigures(),
                  if (showControlFigures) const SizedBox(height: 3),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Boxes/F_Stock count, with the DNA tag ▾ arrow (and its
                      // expanded chips, when open) directly beneath it — the
                      // card's bottom-left, only shown when tags exist.
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_merged)
                              _mergedBoxes()
                            else
                              Text(
                                showControlFigures
                                    ? (design.fStock == 0 &&
                                            design.controlQuantity > 0
                                        ? 'Hidden'
                                        : '${design.fStock} shown')
                                    : '${design.boxQuantity} boxes',
                                style: TextStyle(
                                    color: showControlFigures &&
                                            design.fStock == 0 &&
                                            design.controlQuantity > 0
                                        ? const Color(0xFFEF6C00)
                                        : const Color(0xFF1B4F72),
                                    fontWeight: FontWeight.w600,
                                    fontSize: 11)),
                            if (dnaTagsByAttribute != null &&
                                dnaTagsByAttribute!.isNotEmpty)
                              DnaTagExpander(
                                tagsByAttribute: dnaTagsByAttribute!,
                                isExpanded: isDnaExpanded,
                                onToggleExpand: onToggleDnaExpand ?? () {},
                                onCollapseIfExpanded:
                                    onCollapseDnaIfExpanded ?? () {},
                              ),
                          ],
                        ),
                      ),
                      // Stockist ID is hidden from guests.
                      if (isGuest)
                        const SizedBox.shrink()
                      else
                      GestureDetector(
                        onTap: onStockistTap,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: onStockistTap != null
                                ? const Color(0xFF1B4F72)
                                    .withValues(alpha: 0.15)
                                : const Color(0xFF1B4F72)
                                    .withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                            border: onStockistTap != null
                                ? Border.all(
                                    color: const Color(0xFF1B4F72)
                                        .withValues(alpha: 0.4),
                                    width: 0.8)
                                : null,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Brand the design is sold under (shorter, and the
                              // thing buyers shop by). Falls back to the seller's
                              // name — real or masked trade name — then the ID.
                              ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 96),
                                child: Text(
                                    design.brandName.isNotEmpty
                                        ? design.brandName
                                        : design.stockistName.isNotEmpty
                                            ? design.stockistName
                                            : 'ID: ${design.stockistId}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 10,
                                        color: Color(0xFF1B4F72))),
                              ),
                              if (onStockistTap != null) ...[
                                const SizedBox(width: 2),
                                const Icon(Icons.arrow_forward_ios_rounded,
                                    size: 8, color: Color(0xFF1B4F72)),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
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

// ── TileImage ─────────────────────────────────────────────────────────────────
//
// Displays a tile design image with the correct orientation.
//
// Portrait tiles (1:2 and 2:3) sometimes have their source images stored in
// landscape orientation (e.g. when extracted from a PDF). This widget detects
// the actual image dimensions and applies a 90° rotation when the image is
// landscape but the tile expects portrait, so the design is never cut or
// distorted.

class TileImage extends StatefulWidget {
  final String url;
  final double tileAspectRatio; // width ÷ height (e.g. 0.5 for 1:2 portrait)
  /// When set, a Cloudinary thumbnail of this width is shown instead of the
  /// full-size original (grids pass this; detail/zoom views leave it null).
  final int? thumbWidth;

  const TileImage({
    super.key,
    required this.url,
    this.tileAspectRatio = 1.0,
    this.thumbWidth,
  });

  @override
  State<TileImage> createState() => _TileImageState();
}

class _TileImageState extends State<TileImage> {
  bool _rotate = false;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  // Effective image URL: a Cloudinary thumbnail when [thumbWidth] is set,
  // otherwise the original. (No-op for asset/empty/non-Cloudinary URLs.)
  String get _src => widget.thumbWidth == null
      ? widget.url
      : CloudinaryService.thumbUrl(widget.url, width: widget.thumbWidth!);

  @override
  void initState() {
    super.initState();
    _detectOrientation();
  }

  @override
  void didUpdateWidget(TileImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.tileAspectRatio != widget.tileAspectRatio) {
      _cancel();
      setState(() => _rotate = false);
      _detectOrientation();
    }
  }

  /// Checks the actual pixel dimensions of the image.
  /// If the tile is portrait (ratio < 0.95) but the image is landscape
  /// (width > height), we flag it for 90° rotation.
  void _detectOrientation() {
    // Only portrait tiles can have the wrong orientation.
    if (widget.tileAspectRatio >= 0.95) return;
    if (widget.url.isEmpty || widget.url.startsWith('assets/')) return;

    _listener = ImageStreamListener((ImageInfo info, _) {
      if (!mounted) return;
      final imgLandscape = info.image.width > info.image.height;
      if (imgLandscape != _rotate) setState(() => _rotate = imgLandscape);
    }, onError: (_, __) {});

    _stream = CachedNetworkImageProvider(_src)
        .resolve(const ImageConfiguration());
    _stream!.addListener(_listener!);
  }

  void _cancel() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.url.isEmpty) return _placeholder();

    final isAsset = widget.url.startsWith('assets/');

    final img = isAsset
        ? Image.asset(widget.url,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _placeholder())
        : CachedNetworkImage(
            imageUrl: _src,
            fit: BoxFit.cover,
            placeholder: (_, __) => _placeholder(),
            errorWidget: (_, __, ___) => _placeholder(),
          );

    // RotatedBox swaps the constraints it passes to its child.
    // For a parent space of W×H (portrait):
    //   → child is given H×W constraints (landscape), fills the image correctly
    //   → RotatedBox rotates the rendered output 90° → appears as W×H ✓
    if (_rotate) {
      return RotatedBox(quarterTurns: 1, child: SizedBox.expand(child: img));
    }

    return SizedBox.expand(child: img);
  }

  Widget _placeholder() => Container(
        color: const Color(0xFFF0F0F2),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_photo_alternate_outlined,
                  size: 32, color: Colors.grey.shade400),
              const SizedBox(height: 4),
              Text('No photo',
                  style: TextStyle(
                      fontSize: 10, color: Colors.grey.shade400)),
            ],
          ),
        ),
      );
}

// ── Quality badge ─────────────────────────────────────────────────────────────

class _QualityBadge extends StatelessWidget {
  final String quality;
  const _QualityBadge({required this.quality});

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    final IconData icon;

    switch (quality.toLowerCase()) {
      case 'premium':
        bg   = const Color(0xFFFFF8E1);
        fg   = const Color(0xFFF9A825);
        icon = Icons.star_rounded;
        break;
      case 'both':
        bg   = const Color(0xFFE8F5E9);
        fg   = const Color(0xFF2E7D32);
        icon = Icons.layers_outlined;
        break;
      default:
        bg   = const Color(0xFFE3F2FD);
        fg   = const Color(0xFF1565C0);
        icon = Icons.verified_outlined;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: fg),
          const SizedBox(width: 3),
          Text(quality,
              style: TextStyle(
                  fontSize: 10, color: fg, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
