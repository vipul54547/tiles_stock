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
