import '../models/tile_design.dart';

/// Scenario-2 buyer merge (step 2). A buyer-facing card that folds the Premium
/// and Standard holdings of the SAME physical tile (same stockist + master +
/// brand + surface) into one. Either slot may be null — a tile stocked in only
/// one grade shows as a single-grade card. Merging is ONLY across quality; a
/// different stockist, brand or surface stays a separate card (step 5).
class MergedDesign {
  final TileDesign? premium;
  final TileDesign? standard;
  const MergedDesign({this.premium, this.standard});

  /// The holding used for image / name / size / family / brand on the card —
  /// prefer Premium, fall back to Standard. Never null (a group always has one).
  TileDesign get rep => (premium ?? standard)!;
  int get premiumBoxes => premium?.boxQuantity ?? 0;
  int get standardBoxes => standard?.boxQuantity ?? 0;
  int get totalBoxes => premiumBoxes + standardBoxes;
  bool get hasBoth => premium != null && standard != null;

  /// The underlying cart-addressable holdings (the cart is keyed per holding id).
  List<TileDesign> get holdings =>
      [if (premium != null) premium!, if (standard != null) standard!];
}

/// Merge key: same physical tile across quality only. Surface is kept in the key
/// so two finishes of one master/brand stay separate; brand (name, then id) is
/// kept so per-brand holdings stay separate (step 5). Falls back to the holding
/// id when library_id is missing so legacy rows never collapse together.
String _mergeKey(TileDesign d) {
  final lib = d.libraryId.isNotEmpty ? d.libraryId : d.id;
  final brand = d.brandName.isNotEmpty ? d.brandName : (d.brandId ?? '');
  return '${d.stockistId}|$lib|$brand|${d.surfaceType}';
}

bool _isPremium(TileDesign d) => d.quality.trim().toLowerCase() == 'premium';

/// Groups a flat design list into merged cards, preserving first-appearance
/// order (so newest-first / ranking order carries over). If two rows somehow
/// share a key + quality, the larger box count wins.
List<MergedDesign> mergeByQuality(List<TileDesign> designs) {
  final order = <String>[];
  final prem = <String, TileDesign>{};
  final std = <String, TileDesign>{};
  for (final d in designs) {
    final k = _mergeKey(d);
    if (!prem.containsKey(k) && !std.containsKey(k)) order.add(k);
    final map = _isPremium(d) ? prem : std;
    final cur = map[k];
    if (cur == null || d.boxQuantity > cur.boxQuantity) map[k] = d;
  }
  return [
    for (final k in order) MergedDesign(premium: prem[k], standard: std[k]),
  ];
}
