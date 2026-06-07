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

/// Expected display aspect ratio (width ÷ height) for a given size string.
/// Accepts "800x1600 mm", "800x1600", "800X1600", etc.
double aspectRatioFromSize(String size) {
  final key = size.replaceAll(RegExp(r'[^0-9x]', caseSensitive: false), '')
      .toLowerCase();
  return switch (key) {
    '800x1600' || '600x1200' || '300x600' => 0.5,       // 1 : 2
    '300x450'                              => 2.0 / 3.0, // 2 : 3
    _                                      => 1.0,        // 1 : 1
  };
}

/// True when the tile is taller than wide (portrait).
bool isPortraitTile(String size) => aspectRatioFromSize(size) < 0.95;

/// Human-readable ratio label for UI display.
String ratioLabel(String size) {
  final key = size.replaceAll(RegExp(r'[^0-9x]', caseSensitive: false), '')
      .toLowerCase();
  return switch (key) {
    '800x1600' || '600x1200' || '300x600' => '1:2',
    '300x450'                              => '1:1.5',
    _                                      => '1:1',
  };
}

/// Normalise a size string parsed from a filename to the canonical format.
/// "800X1600" → "800x1600 mm"
String normaliseSize(String raw) {
  final cleaned = raw
      .replaceAll(RegExp(r'[^0-9xX]'), '')
      .replaceAll('X', 'x')
      .toLowerCase();
  return '$cleaned mm';
}
