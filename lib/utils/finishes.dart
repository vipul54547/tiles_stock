/// Canonical surface options — the LAST-RESORT fallback only, used when the admin
/// `surface_types` table can't be read. The live list comes from the DB; this
/// constant exists so a failed load doesn't leave a picker empty.
///
/// 🚫 There is no 'None'. A tile always has a surface, and the surface is part of
/// the product's identity — 'None' was never a surface, it was "we don't know yet"
/// wearing one's clothes, and because it sits in the product key it spawned a
/// phantom product beside the real one. The DB now refuses it outright
/// (`stockist_library_surface_not_none`) and the admin row is deactivated. Never
/// put it back, and never offer it in a picker.
const List<String> kFinishes = [
  'Glossy',
  'Matt',
  'Satin',
  'Polished',
  'Rustic',
  'Carving',
  'Lappato',
  'Sugar',
];
