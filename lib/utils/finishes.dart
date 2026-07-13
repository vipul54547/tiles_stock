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

/// The surface a MACHINE import gives a row it has no surface for.
///
/// It is NOT 'None' wearing a new hat. 'None' meant "we don't know yet" while sitting in
/// the product KEY, so it spawned a phantom product beside the real one. `Special` is a
/// REAL surface, and a legitimate PERMANENT answer for a stockist whose surfaces cannot
/// sensibly be enumerated — stock INHERITS a product's surface rather than asking for one,
/// so it cannot spawn a twin, and `library_set_surface` cascades a later correction onto
/// every holding.
///
/// 🚫 NO free text under it. `surface_label` is not identity, so two `Special` tiles told
/// apart only by a label would COLLIDE into one product.
const String kSpecialSurface = 'Special';

/// The one boundary between "the app doesn't know this row's surface" and what we send
/// to the DB. Every RPC that can CREATE a product goes through here.
///
/// Inside the app, an unknown surface is the empty string (and, until the PDF parser is
/// rewritten, the legacy 'None' sentinel it still stamps on an unparseable row). Neither
/// may reach Postgres: `library_map_upsert` RAISES on both, and one bad row throws the
/// WHOLE batch — which is exactly why the M-PDF library import could not run at all.
///
/// ⚠️ A human is NEVER defaulted. This is for the PDF / Excel path only: we don't ask
/// mid-parse, so we must not GUESS mid-parse either. In the Library editor the surface is
/// COMPULSORY and blank — the stockist is standing right there, so ask him.
String surfaceForImport(String? s) {
  final t = (s ?? '').trim();
  if (t.isEmpty || t.toLowerCase() == 'none') return kSpecialSurface;
  return t;
}
