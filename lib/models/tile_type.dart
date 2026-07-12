/// A tile BODY type (Porcelain, PGVT & GVT, Ceramic, …), admin-managed — the twin of
/// [SurfaceType] and [TileSize].
///
/// It carries the one thing nothing else can supply: **density**. Thickness is never typed;
/// it is derived from the box:
///
///     thickness_mm = box_weight_kg / (pieces_per_box × area_m² × density) × 1000
///
/// The densities were calibrated by the user from real per-sq-ft weight data, and fall
/// straight out of the live stock data with zero variance (Porcelain 2085, PGVT & GVT 2233,
/// Ceramic 1672). (docs/BOX_AND_DERIVED_THICKNESS_PLAN.md)
class TileType {
  final String id;
  final String name;

  /// Effective bulk density in kg/m³ — the whole reason this is a table and not a list.
  final double densityKgM3;
  final int sortOrder;
  final bool isActive;

  const TileType({
    required this.id,
    required this.name,
    required this.densityKgM3,
    required this.sortOrder,
    required this.isActive,
  });

  factory TileType.fromJson(Map<String, dynamic> j) => TileType(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        densityKgM3: (j['density_kg_m3'] as num?)?.toDouble() ?? 0,
        sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
        isActive: j['is_active'] as bool? ?? true,
      );
}
