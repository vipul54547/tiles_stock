import 'package:flutter/material.dart';

/// In-app co-brand mark: "Powered by Tiles Stock".
///
/// The Tiles Stock brand logo is a cream wordmark on a solid charcoal block, so
/// on the app's light screens we present it inside a rounded **charcoal chip**
/// (the image already carries the charcoal — we just round its corners). Drop
/// this at the bottom of light screens where a subtle platform credit fits.
class PoweredByTilesStock extends StatelessWidget {
  /// Height of the logo chip. The wordmark scales within it.
  final double logoHeight;

  /// Show the small "Powered by" lead-in text before the chip.
  final bool showLabel;

  const PoweredByTilesStock({
    super.key,
    this.logoHeight = 22,
    this.showLabel = true,
  });

  @override
  Widget build(BuildContext context) {
    final chip = ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: Image.asset(
        'assets/brand/tilesstock_wide.png',
        height: logoHeight,
        fit: BoxFit.contain,
      ),
    );
    if (!showLabel) return chip;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('Powered by',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
        const SizedBox(width: 7),
        chip,
      ],
    );
  }
}
