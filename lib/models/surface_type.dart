/// An admin-managed tile finish (surface type). Mirrors a row in the Supabase
/// `surface_types` table. The admin master list replaces the old hardcoded
/// `kFinishes` constant — stockists align their PDF surface words to these.
///
/// `isSystem` marks the protected 'None' fallback: it can't be renamed, hidden
/// or deleted, and is used whenever a PDF surface word can't be aligned to an
/// official finish.
class SurfaceType {
  final String id;
  final String name;
  final int sortOrder;
  final bool isActive;
  final bool isSystem;

  const SurfaceType({
    required this.id,
    required this.name,
    required this.sortOrder,
    required this.isActive,
    required this.isSystem,
  });

  factory SurfaceType.fromJson(Map<String, dynamic> j) => SurfaceType(
        id:        j['id'] as String,
        name:      j['name'] as String,
        sortOrder: j['sort_order'] as int? ?? 0,
        isActive:  j['is_active'] as bool? ?? true,
        isSystem:  j['is_system'] as bool? ?? false,
      );
}
