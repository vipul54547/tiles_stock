import '../models/tile_design.dart';
import 'tile_types.dart';

/// Grouping holdings by PRINT — the shared brain behind both hand-pick paths
/// (`showHoldingPicker` for touch, `HoldingEntryBar` for the keyboard).
///
/// One print can be held in several brand × quality × surface variants:
/// `DELTON_8_A` alone is six holdings. Listing them flat is six near-identical
/// rows, and tapping Premium when you meant Standard is one slip away. Every
/// picker therefore asks the PRINT first and only then the variants that are
/// genuinely ambiguous — each carrying its box count, because the number is what
/// stops the wrong pick. (docs/DISPATCH_ORDER_BACKED_PLAN.md)

/// A library row IS the print (name + size), so its holdings differ only by
/// brand / quality / surface — exactly the variants worth asking about.
class HoldingPrint {
  final String key;
  final String name;
  final String size;
  final String imageUrl;
  final List<TileDesign> holdings;
  const HoldingPrint(
      this.key, this.name, this.size, this.imageUrl, this.holdings);

  int boxes(int Function(TileDesign) boxesOf) =>
      holdings.fold(0, (s, d) => s + boxesOf(d));

  /// What is still to be decided about this print — shown on the row, so the
  /// stockist knows a second question is coming before they pick it.
  String get variantHint {
    final bits = [
      if (holdings.map(brandKeyOf).toSet().length > 1)
        '${holdings.map(brandKeyOf).toSet().length} brands',
      if (holdings.map(surfaceKeyOf).toSet().length > 1)
        '${holdings.map(surfaceKeyOf).toSet().length} surfaces',
      if (holdings.map((d) => d.quality).toSet().length > 1)
        '${holdings.map((d) => d.quality).toSet().length} qualities',
    ];
    return bits.join(' · ');
  }
}

String surfaceKeyOf(TileDesign d) => d.surfaceType.trim().toLowerCase();
String brandKeyOf(TileDesign d) => d.brandId ?? '';

/// Group holdings into prints, alphabetical by name.
///
/// ⚠️ A print carried in TWO THICKNESSES is two products with the SAME name, size and surface —
/// they differ only by `library_id`. Each rightly gets its own row here, but they would READ
/// identically, and the stockist could not tell which stock they were dispatching. So the product
/// FORKED off the original wears its thickness: `6003 (SV) (11.5–12.0 mm)`.
/// (This is the one chokepoint for the dispatch picker AND the desktop entry bar.)
List<HoldingPrint> groupHoldingsByPrint(List<TileDesign> list) {
  final forkLabels = thicknessForkLabels(list);
  final map = <String, List<TileDesign>>{};
  final order = <String>[];
  for (final d in list) {
    final k = d.libraryId.isNotEmpty ? d.libraryId : d.id;
    if (map[k] == null) {
      map[k] = [d];
      order.add(k);
    } else {
      map[k]!.add(d);
    }
  }
  final out = <HoldingPrint>[];
  for (final k in order) {
    final hs = map[k]!;
    final img = hs
        .map((d) => d.faceImageUrls.isNotEmpty ? d.faceImageUrls.first : '')
        .firstWhere((u) => u.isNotEmpty, orElse: () => '');
    final fork = forkLabels[hs.first.libraryId];
    final name =
        fork == null ? hs.first.name : '${hs.first.name} ($fork)';
    out.add(HoldingPrint(k, name, hs.first.size, img, hs));
  }
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}
