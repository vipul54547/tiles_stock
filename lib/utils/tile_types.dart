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

/// 🔑 The thicknesses a product may DECLARE, as 0.5 mm BANDS: 4.0–4.5 … 19.5–20.0.
/// Part of product identity, alongside print + size + surface + body — an 8 mm and a 12 mm of one
/// print cover the same sq ft but sell at a different rate, so they are two products.
///
/// Each entry is the band's **LOW EDGE**; the band runs `[mm, mm + 0.5)`. A band, not a round
/// number, because a real tile is 8.86 mm — not 9 mm — and it belongs honestly in 8.5–9.0. One
/// number per band keeps it a clean key: `8` and `8.0` can never become two products.
///
/// The real list lives in the admin-managed `thickness_options` table; this const is the fallback
/// until it loads. (docs/THICKNESS_AND_BODY_IDENTITY_PLAN.md)
const List<double> kThicknessOptions = [
  4.0, 4.5, 5.0, 5.5, 6.0, 6.5, 7.0, 7.5, 8.0, 8.5, 9.0, 9.5, 10.0, 10.5,
  11.0, 11.5, 12.0, 12.5, 13.0, 13.5, 14.0, 14.5, 15.0, 15.5, 16.0, 16.5,
  17.0, 17.5, 18.0, 18.5, 19.0, 19.5,
];

List<double> _liveThickness = List<double>.from(kThicknessOptions);

/// Feed in what `SupabaseDataService.getThicknessOptions()` returned. Ignores an empty list —
/// a failed fetch must never wipe the fallback and leave every product undeclarable.
void applyThicknessOptions(List<double> mm) {
  if (mm.isEmpty) return;
  _liveThickness = List<double>.from(mm);
}

/// The nominal thicknesses on offer — the table's once loaded, [kThicknessOptions] until then.
List<double> get thicknessOptions => _liveThickness;

/// The BAND a measured/derived thickness falls in — used to PRE-FILL the picker, and to read a
/// figure a stockist typed into a spreadsheet. The stockist already gives pieces + box weight, and
/// the body type is known, so the app proposes the band rather than asking for the same fact twice.
///
/// Because the bands tile the whole range, a figure inside 4.0–20.0 lands in exactly ONE band —
/// so this is not a rounding or a guess, it is the band that figure *is in*. A figure OUTSIDE the
/// range returns null: 3 mm and 25 mm are not tiles, they are a bad box weight, and a bad weight
/// must propose nothing rather than stamp a wrong value into the identity key.
///
/// ⚠️ Still only ever a SUGGESTION to be confirmed — never stored silently. The derivation is
/// unreliable (all 258 Porcelain 600x600 derive to exactly 7.99 mm, a density artifact), and
/// identity may never be recomputed from a box edit. (THICKNESS_AND_BODY_IDENTITY_PLAN.md)
double? thicknessBandFor(double? mm) {
  if (mm == null || mm <= 0 || thicknessOptions.isEmpty) return null;
  final low = (mm / 0.5).floor() * 0.5;
  return thicknessOptions.contains(low) ? low : null;
}

/// A declared thickness reads as its BAND — "8.5–9.0 mm". [mm] is the band's low edge.
String thicknessLabel(double? mm) {
  if (mm == null) return '';
  return '${mm.toStringAsFixed(1)}–${(mm + 0.5).toStringAsFixed(1)} mm';
}

/// Read a thickness a stockist wrote in a spreadsheet, and return the BAND's low edge.
///
/// Accepts what they can plausibly type: the band as the template offers it ("8.5–9.0 mm"), or a
/// bare measurement ("8.86", "9"). A bare figure is not "rounded" — it is placed in the band it
/// already falls in, which is exactly one band. Anything outside 4.0–20.0, or unreadable, is null
/// (and the caller then REJECTS the row rather than guessing an identity).
double? parseDeclaredThickness(String raw) {
  var s = raw.toLowerCase().replaceAll('mm', '').trim();
  if (s.isEmpty) return null;
  // "8.5–9.0" / "8.5-9.0" → take the low edge they picked.
  for (final dash in const ['–', '-', '—', 'to']) {
    final i = s.indexOf(dash);
    if (i > 0) {
      s = s.substring(0, i).trim();
      break;
    }
  }
  return thicknessBandFor(double.tryParse(s));
}

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
