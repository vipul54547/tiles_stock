import 'dart:math' as math;
import 'package:flutter/material.dart';

/// A body colour's on-screen swatch, derived from its **L·a·b** (preferred) or **hex** (fallback),
/// else a neutral grey. `bc` is `{name, l, a, b, hex}` as returned by the palette / library reader.
Color bodyColourSwatch(Map<String, dynamic> bc) {
  double? n(dynamic v) => v == null ? null : (v as num).toDouble();
  final l = n(bc['l']), a = n(bc['a']), b = n(bc['b']);
  if (l != null && a != null && b != null) return _labToColor(l, a, b);
  final hex = (bc['hex'] ?? '').toString().replaceAll('#', '').trim();
  if (hex.length == 6) {
    final v = int.tryParse(hex, radix: 16);
    if (v != null) return Color(0xFF000000 | v);
  }
  return const Color(0xFFBDBDBD);
}

/// CIELAB (D65) → sRGB.
Color _labToColor(double lStar, double aStar, double bStar) {
  double y = (lStar + 16) / 116, x = aStar / 500 + y, z = y - bStar / 200;
  double f(double t) =>
      (t * t * t > 0.008856) ? t * t * t : (t - 16 / 116) / 7.787;
  x = f(x) * 0.95047;
  y = f(y);
  z = f(z) * 1.08883;
  double r = x * 3.2406 + y * -1.5372 + z * -0.4986;
  double g = x * -0.9689 + y * 1.8758 + z * 0.0415;
  double bl = x * 0.0557 + y * -0.2040 + z * 1.0570;
  double gamma(double c) =>
      c > 0.0031308 ? 1.055 * math.pow(c, 1 / 2.4) - 0.055 : 12.92 * c;
  int ch(double c) => (gamma(c).clamp(0.0, 1.0) * 255).round();
  return Color.fromARGB(255, ch(r), ch(g), ch(bl));
}
