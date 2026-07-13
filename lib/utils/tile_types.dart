import 'tile_sizes.dart';
import '../models/tile_design.dart';

/// FALLBACK tile body types. The real list lives in the admin-managed `tile_types` TABLE
/// (with each type's density) — this const is only what we use before it has loaded, or if
/// the load fails. Keep it in step with the seed in
/// `20260713_box_step1_tile_types.sql`.
const List<String> kTileTypes = [
  'PGVT & GVT',
  'Porcelain',
  'Ceramic',
  'Full Body',
  'DC',
  'Colour Body',
];

/// FALLBACK effective bulk density (kg/m³) per body type. Same story: the table is the truth.
///
/// Calibrated from real per-sq-ft weight data supplied by the user: PGVT&GVT 1.815 kg/sq.ft →
/// 8.75 mm (2233); Ceramic 1.21 kg/sq.ft → 7.79 mm (1672). Independently confirmed against the
/// live stock data with ZERO variance — Porcelain 2085 across 258 products, PGVT & GVT 2233
/// across 139.
const Map<String, double> kTileDensity = {
  'PGVT & GVT': 2233,
  'Full Body': 2350,
  'DC': 2350,
  'Colour Body': 2350,
  'Porcelain': 2085,
  'Ceramic': 1672,
};

// ── the live values, refreshed from the tile_types table ─────────────────────────────────
// densityFor() is called synchronously inside build() (the thickness preview, the buyer's
// thickness-band filter), so it cannot await a fetch. Cache it instead, seeded with the const
// above so the app is correct from the very first frame and stays correct offline.
List<String> _liveTypes = List<String>.from(kTileTypes);
Map<String, double> _liveDensity = Map<String, double>.from(kTileDensity);

/// Feed in what `SupabaseDataService.getTileTypes()` returned. Ignores an empty list — a
/// failed fetch must never wipe the fallback and leave every thickness underivable.
void applyTileTypes(List<({String name, double densityKgM3})> types) {
  if (types.isEmpty) return;
  _liveTypes = [for (final t in types) t.name];
  _liveDensity = {for (final t in types) t.name: t.densityKgM3};
}

/// The body types on offer — the table's, once loaded; [kTileTypes] until then.
List<String> get tileTypeNames => _liveTypes;

/// 🔑 There is NO list of declarable thicknesses, and there must never be one.
/// Thickness is DERIVED from the BOX — `box_weight / (pieces × area × density)` — and a stockist
/// cannot know "8.5–9.0 mm"; they read PIECES and WEIGHT off the box. The 0.5 mm band the derived
/// figure falls in is part of product identity (`stockist_library.thickness_band`, a GENERATED
/// column), so a typed thickness would let a guess into the identity key.
/// Format it with [thicknessBandLabel]. (docs/THICKNESS_AND_BODY_IDENTITY_PLAN.md)

double densityFor(String tileType) =>
    _liveDensity[tileType] ?? kTileDensity[tileType] ?? 2350;

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

/// 🔑 A thickness is ALWAYS shown as a 0.5 mm BAND — "8.5–9.0 mm", never a bare
/// "8.8 mm". Real tiles vary, the figure is derived from box weight rather than
/// measured, and every thickness filter in the app (buyer, stockist, `/s/`) chips on
/// these bands. The DB agrees: `stockist_library.thickness_band` is a GENERATED column
/// with exactly this `floor(mm / 0.5) * 0.5`.
///
/// This takes a thickness that has ALREADY been derived — the server derives it by
/// trigger and stores it on the product, and that value is authoritative.
String? thicknessBandLabel(double? mm) {
  if (mm == null || mm <= 0) return null;
  final low = (mm / 0.5).floor() * 0.5;
  final high = low + 0.5;
  return '${low.toStringAsFixed(1)}–${high.toStringAsFixed(1)} mm';
}

/// The band for a box that hasn't been saved yet — derives the thickness from the
/// pieces/weight being typed, then bands it. Same formula as the server's
/// `_derive_thickness`, so the live preview and the stored value agree.
String? thicknessRangeLabel(
        String size, int piecesPerBox, double boxWeightKg, String tileType) =>
    thicknessBandLabel(
        approxThicknessMm(size, piecesPerBox, boxWeightKg, tileType));

/// The thickness band a single design falls in (or null when its weight is
/// missing, so no thickness can be derived).
String? thicknessBandOf(TileDesign d) =>
    thicknessRangeLabel(d.size, d.piecesPerBox, d.boxWeightKg, d.tileType);

/// 🔑 Which products need their THICKNESS shown beside the name to be tellable apart.
///
/// A print can be carried in two thicknesses — but only when they differ by more than 1 mm (box
/// weights drift: a 600x1200 2-pc box went 28 kg → 26 kg, which is 0.62 mm and the SAME tile).
/// When that genuinely happens, the two products share a name, size and surface, and every screen
/// that lists them — dashboard, dispatch, stock — would otherwise show two identical rows.
///
/// The FIRST one created is the original and reads plainly; anything FORKED off it later carries
/// its thickness. Returns `library_id -> "11.5–12.0 mm"` for the forks only.
/// (docs/THICKNESS_AND_BODY_IDENTITY_PLAN.md)
Map<String, String> thicknessForkLabels(Iterable<TileDesign> designs) {
  // one entry per PRODUCT (a product has many holdings — Premium, Standard, per brand)
  final byLib = <String, TileDesign>{};
  for (final d in designs) {
    if (d.libraryId.isEmpty) continue;
    byLib.putIfAbsent(d.libraryId, () => d);
  }

  final groups = <String, List<TileDesign>>{};
  for (final d in byLib.values) {
    final k = '${d.name.toLowerCase()}|${d.size}|${d.surfaceType}';
    (groups[k] ??= []).add(d);
  }

  final out = <String, String>{};
  for (final g in groups.values) {
    if (g.length < 2) continue; // the only one of its kind — nothing to tell apart
    DateTime? oldest;
    for (final d in g) {
      final c = d.libraryCreatedAt;
      if (c == null) continue;
      if (oldest == null || c.isBefore(oldest)) oldest = c;
    }
    if (oldest == null) continue;
    for (final d in g) {
      final c = d.libraryCreatedAt;
      if (c == null || !c.isAfter(oldest)) continue; // this IS the original
      final label = thicknessBandLabel(d.thicknessMm);
      if (label != null) out[d.libraryId] = label;
    }
  }
  return out;
}

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
