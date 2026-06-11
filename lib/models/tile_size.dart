/// An admin-managed tile size (e.g. "800x1600 mm"). Mirrors a row in the
/// Supabase `tile_sizes` table; replaces the old hardcoded `kAllowedSizes`.
class TileSize {
  final String id;
  final String name;
  final int sortOrder;
  final bool isActive;
  /// Alternate trade names (inch/feet, either orientation), e.g. for
  /// "300x450 mm": ["12x18", "1x1.5"]. Used to map import sizes to this one.
  final List<String> aliases;

  const TileSize({
    required this.id,
    required this.name,
    required this.sortOrder,
    required this.isActive,
    this.aliases = const [],
  });

  factory TileSize.fromJson(Map<String, dynamic> j) => TileSize(
        id:        j['id'] as String,
        name:      j['name'] as String,
        sortOrder: j['sort_order'] as int? ?? 0,
        isActive:  j['is_active'] as bool? ?? true,
        aliases:   (j['aliases'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
      );
}
