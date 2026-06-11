import '../models/tile_size.dart';

/// Canonical tile sizes supported by the system.
/// Format: "WIDTHxHEIGHT mm"  (e.g. "800x1600 mm")
const List<String> kAllowedSizes = [
  '800x1600 mm',   // 1:2
  '600x1200 mm',   // 1:2
  '300x600 mm',    // 1:2
  '300x450 mm',    // 2:3
  '600x600 mm',    // 1:1
  '500x500 mm',    // 1:1
  '400x400 mm',    // 1:1
  '300x300 mm',    // 1:1
];

/// Parses a size string into (width, height) in mm, or null if not parseable.
/// Accepts "800x1600 mm", "800x1600", "800 X 1600", etc.
({int w, int h})? sizeDimensions(String size) {
  final m = RegExp(r'(\d{2,4})\s*[xX]\s*(\d{2,4})').firstMatch(size);
  if (m == null) return null;
  final w = int.tryParse(m.group(1)!);
  final h = int.tryParse(m.group(2)!);
  if (w == null || h == null || w <= 0 || h <= 0) return null;
  return (w: w, h: h);
}

/// Expected display aspect ratio (width ÷ height) for any size string — computed
/// from the numbers themselves, so new sizes work without code changes.
/// Accepts "800x1600 mm", "800x1600", "800X1600", "800 X 1600", etc.
double aspectRatioFromSize(String size) {
  final d = sizeDimensions(size);
  return d == null ? 1.0 : d.w / d.h;
}

/// True when the tile is taller than wide (portrait).
bool isPortraitTile(String size) => aspectRatioFromSize(size) < 0.95;

/// Human-readable ratio label for UI display (e.g. "1:2", "2:3", "1:1"),
/// derived from the actual dimensions.
String ratioLabel(String size) {
  final d = sizeDimensions(size);
  if (d == null) return '1:1';
  final g = _gcd(d.w, d.h);
  final w = d.w ~/ g, h = d.h ~/ g;
  // Use a clean "1:x" form when width divides height (the common tile case).
  if (h % w == 0) return '1:${h ~/ w}';
  if (w % h == 0) return '${w ~/ h}:1';
  return '$w:$h';
}

int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);

/// Normalise a size string parsed from a filename to the canonical format.
/// "800X1600" → "800x1600 mm"
String normaliseSize(String raw) {
  final cleaned = raw
      .replaceAll(RegExp(r'[^0-9xX]'), '')
      .replaceAll('X', 'x')
      .toLowerCase();
  return '$cleaned mm';
}

/// Order-independent numeric signature of a size token: the two numbers sorted
/// ascending, units stripped. So "12X18", "18x12", "18 x 12 inch" all collapse
/// to "12x18"; "2.5x5" stays "2.5x5". Returns null if no WxH is found.
String? sizeSignature(String raw) {
  final m =
      RegExp(r'(\d+(?:\.\d+)?)\s*[xX]\s*(\d+(?:\.\d+)?)').firstMatch(raw);
  if (m == null) return null;
  final a = double.tryParse(m.group(1)!);
  final b = double.tryParse(m.group(2)!);
  if (a == null || b == null || a <= 0 || b <= 0) return null;
  final lo = a <= b ? a : b;
  final hi = a <= b ? b : a;
  String fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();
  return '${fmt(lo)}x${fmt(hi)}';
}

/// Resolves any incoming size token (mm / inch / feet, either orientation) to a
/// canonical size NAME, by matching its [sizeSignature] against each admin size's
/// own name and its aliases. Returns null when nothing matches.
String? resolveCanonicalSize(String raw, List<TileSize> sizes) {
  final sig = sizeSignature(raw);
  if (sig == null) return null;
  for (final s in sizes) {
    if (sizeSignature(s.name) == sig) return s.name;
    for (final a in s.aliases) {
      if (sizeSignature(a) == sig) return s.name;
    }
  }
  return null;
}
