import 'package:flutter/material.dart';

import 'package:cached_network_image/cached_network_image.dart';

import '../models/tile_design.dart';

double _aspectRatioFromSize(String size) {
  try {
    final clean = size.replaceAll(RegExp(r'[^0-9x]'), '');
    final parts = clean.split('x');
    if (parts.length == 2) {
      final w = double.parse(parts[0]);
      final h = double.parse(parts[1]);
      if (h > 0) return w / h;
    }
  } catch (_) {}
  return 1.0;
}



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

                  aspectRatio: _aspectRatioFromSize(design.size),

                  child: CachedNetworkImage(

                    imageUrl: design.faceImageUrls.isNotEmpty

                        ? design.faceImageUrls.first

                        : 'https://picsum.photos/seed/${design.id}/${design.size.contains('1200') ? '800/400' : design.size.contains('300') ? '400/800' : '400/400'}',

                    fit: BoxFit.cover,

                    width: double.infinity,

                    placeholder: (_, __) => Container(color: Colors.grey[200]),

                    errorWidget: (_, __, ___) => Container(

                      color: Colors.grey[200],

                      child: const Icon(Icons.image_not_supported),

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

              padding: const EdgeInsets.all(8),

              child: Column(

                crossAxisAlignment: CrossAxisAlignment.start,

                children: [

                  Text(design.name,

                      style: const TextStyle(

                          fontWeight: FontWeight.bold, fontSize: 13),

                      maxLines: 1,

                      overflow: TextOverflow.ellipsis),

                  const SizedBox(height: 2),

                  Text(design.size,

                      style: TextStyle(color: Colors.grey[600], fontSize: 11)),

                  Text(design.surfaceType,

                      style: TextStyle(color: Colors.grey[600], fontSize: 11)),

                  const SizedBox(height: 4),

                  _QualityBadge(quality: design.quality),

                  const SizedBox(height: 4),

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
                                ? const Color(0xFF1B4F72).withValues(alpha: 0.15)
                                : const Color(0xFF1B4F72).withValues(alpha: 0.1),
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
                                      fontSize: 10, color: Color(0xFF1B4F72))),
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
        bg = const Color(0xFFFFF8E1);
        fg = const Color(0xFFF9A825);
        icon = Icons.star_rounded;
        break;
      case 'both':
        bg = const Color(0xFFE8F5E9);
        fg = const Color(0xFF2E7D32);
        icon = Icons.layers_outlined;
        break;
      default: // standard
        bg = const Color(0xFFE3F2FD);
        fg = const Color(0xFF1565C0);
        icon = Icons.verified_outlined;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: fg),
          const SizedBox(width: 3),
          Text(
            quality,
            style: TextStyle(fontSize: 10, color: fg, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}