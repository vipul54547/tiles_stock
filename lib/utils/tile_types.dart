import 'tile_sizes.dart';
import '../models/tile_design.dart';

/// Tile body types the stockist picks at upload time and buyers filter on.
const List<String> kTileTypes = [
  'PGVT & GVT',
  'Porcelain',
  'Ceramic',
  'Full Body',
  'DC',
  'Colour Body',
];

/// Effective bulk density (kg/m³) per body type, used only to derive the
/// approximate thickness band from box weight + area. Calibrated from real
/// per-sq-ft weight data supplied by the user: PGVT&GVT 1.815 kg/sq.ft → 8.75 mm
/// (2233); Ceramic 1.21 kg/sq.ft → 7.79 mm (1672).
const Map<String, double> kTileDensity = {
  'PGVT & GVT': 2233,
  'Full Body': 2350,
  'DC': 2350,
  'Colour Body': 2350,
  'Porcelain': 2085,
  'Ceramic': 1672,
};

double densityFor(String tileType) => kTileDensity[tileType] ?? 2350;

/// Square feet covered by one box, from the tile size and pieces/box.
/// 1 ft = 304.8 mm. Returns null when the size or count is unusable.
double? sqftPerBox(String size, int piecesPerBox) {
  final d = sizeDimensions(size);
  if (d == null || piecesPerBox <= 0) return null;
  final perPieceFt2 = (d.w / 304.8) * (d.h / 304.8);
  return perPieceFt2 * piecesPerBox;
}

/// Approximate tile thickness in mm, derived from box weight, total tile area
/// and the body type's density: mass = area × thickness × density, so
/// thickness = mass / (area × density). Returns null when inputs are missing.
double? approxThicknessMm(
    String size, int piecesPerBox, double boxWeightKg, String tileType) {
  final d = sizeDimensions(size);
  if (d == null || piecesPerBox <= 0 || boxWeightKg <= 0) return null;
  final totalAreaM2 = (d.w / 1000.0) * (d.h / 1000.0) * piecesPerBox;
  if (totalAreaM2 <= 0) return null;
  return boxWeightKg / (totalAreaM2 * densityFor(tileType)) * 1000.0;
}

/// Thickness shown as a 0.5 mm band (e.g. "8.5–9.0 mm") rather than a single
/// number, since real tiles vary slightly. Returns null when not computable.
String? thicknessRangeLabel(
    String size, int piecesPerBox, double boxWeightKg, String tileType) {
  final t = approxThicknessMm(size, piecesPerBox, boxWeightKg, tileType);
  if (t == null || t <= 0) return null;
  final low = (t / 0.5).floor() * 0.5;
  final high = low + 0.5;
  return '${low.toStringAsFixed(1)}–${high.toStringAsFixed(1)} mm';
}

/// The thickness band a single design falls in (or null when its weight is
/// missing, so no thickness can be derived).
String? thicknessBandOf(TileDesign d) =>
    thicknessRangeLabel(d.size, d.piecesPerBox, d.boxWeightKg, d.tileType);

/// Distinct thickness bands present across [designs], sorted ascending. Drives
/// the buyer Thickness filter chips so only bands that actually exist are shown.
List<String> availableThicknessBands(Iterable<TileDesign> designs) {
  final bands = <String>{};
  for (final d in designs) {
    final b = thicknessBandOf(d);
    if (b != null) bands.add(b);
  }
  final list = bands.toList();
  double low(String band) =>
      double.tryParse(band.split('–').first.trim()) ?? 0;
  list.sort((a, b) => low(a).compareTo(low(b)));
  return list;
}

/// Always-visible caveat shown beside the derived thickness: emboss tiles have
/// no single thickness (the surface is raised in places), so the value is an
/// average for them.
const String kEmbossThicknessNote =
    'For emboss tiles this is an average — thickness varies across the surface.';
