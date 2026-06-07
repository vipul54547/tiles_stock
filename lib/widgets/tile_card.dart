import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/tile_design.dart';
import '../utils/tile_sizes.dart';

export '../utils/tile_sizes.dart' show aspectRatioFromSize, kAllowedSizes;

class TileCard extends StatelessWidget {
  final TileDesign design;
  final VoidCallback onTap;
  final VoidCallback? onStockistTap;
  final bool isChosen;
  final VoidCallback? onChoiceTap;

  const TileCard({
    super.key,
    required this.design,
    required this.onTap,
    this.onStockistTap,
    this.isChosen = false,
    this.onChoiceTap,
  });

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
                  child: TileImage(
                    url: design.faceImageUrls.isNotEmpty
                        ? design.faceImageUrls.first
                        : '',
                    tileAspectRatio: ratio,
                  ),
                ),
                // Non-standard finish (e.g. "Punch Ghr", "Lustra") shown over the image.
                if (design.finishLabel != null && design.finishLabel!.isNotEmpty)
                  Positioned(
                    left: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.62),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        design.finishLabel!,
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
                  // Design name
                  Text(design.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 3),
                  // Size · Surface  +  quality badge on same row
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          '${design.size.replaceAll(' mm', '')} · ${design.surfaceType}',
                          style: TextStyle(
                              color: Colors.grey[600], fontSize: 10),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      _QualityBadge(quality: design.quality),
                    ],
                  ),
                  const SizedBox(height: 5),
                  // Boxes count  +  stockist ID
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${design.boxQuantity} boxes',
                          style: const TextStyle(
                              color: Color(0xFF1B4F72),
                              fontWeight: FontWeight.w600,
                              fontSize: 11)),
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
                              Text('ID: ${design.stockistId}',
                                  style: const TextStyle(
                                      fontSize: 10,
                                      color: Color(0xFF1B4F72))),
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

  const TileImage({
    super.key,
    required this.url,
    this.tileAspectRatio = 1.0,
  });

  @override
  State<TileImage> createState() => _TileImageState();
}

class _TileImageState extends State<TileImage> {
  bool _rotate = false;
  ImageStream? _stream;
  ImageStreamListener? _listener;

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

    _stream = CachedNetworkImageProvider(widget.url)
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
            imageUrl: widget.url,
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
