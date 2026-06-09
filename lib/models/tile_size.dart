/// An admin-managed tile size (e.g. "800x1600 mm"). Mirrors a row in the
/// Supabase `tile_sizes` table; replaces the old hardcoded `kAllowedSizes`.
class TileSize {
  final String id;
  final String name;
  final int sortOrder;
  final bool isActive;

  const TileSize({
    required this.id,
    required this.name,
    required this.sortOrder,
    required this.isActive,
  });

  factory TileSize.fromJson(Map<String, dynamic> j) => TileSize(
        id:        j['id'] as String,
        name:      j['name'] as String,
        sortOrder: j['sort_order'] as int? ?? 0,
        isActive:  j['is_active'] as bool? ?? true,
      );
}
