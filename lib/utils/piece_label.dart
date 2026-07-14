import '../models/library_entry.dart';
import 'tile_types.dart';

/// Composes the display label for ONE PIECE of tile — a `stockist_library` row.
///
/// 🔑 **A piece has no name, and it never will.** It has no size and no image either: all three
/// belong to the PRINT above it. What identifies a piece is what it IS —
/// `print + surface + body + thickness` — so a label for one must be COMPOSED at display time and
/// never stored. Storing it would make a third name (beside the print's word and the box's word),
/// and copies rot: `master_design_name` sat on this table until it had drifted stale, and was
/// deleted in July 2026.
///
/// The rule, and it is the same one the Library card uses:
///
///   `print_name` — `surface` [ `(thickness)` ]
///
/// * the **surface** is the stockist's OWN word when he has one (`Raindrops`), else the admin
///   canonical (`P.Glossy`). 874 of 935 products have no word of their own, so the fallback is
///   the normal case, not the exception.
/// * the **thickness** is added ONLY to a piece forked off the original by a genuinely different
///   thickness (>1 mm). The original reads plainly. Without this, cura's two `6003 (SV)` pieces —
///   same print, same surface, same body, 8.4 mm and 11.8 mm — are labelled identically, and in a
///   PICKER that means adding stock to the wrong tile.
///
/// ⚠️ **It does NOT branch on `surface_mode`, and must not.** That flag describes how a factory
/// STAMPS ITS BOXES, nothing else. What tells two pieces of one print apart is not predictable
/// from it: famous is `attribute` and forks by SURFACE (`1001` = Matt/Carving/GHR), cura is
/// `in_name` and forks by THICKNESS. Branching on the mode would drop the surface for cura and
/// label its two pieces the same. Every past attempt to decide identity from stockist type has
/// gone wrong the same way (it left famous's `1001` wearing a stale `Sugar` label).
/// Returns the SUFFIX, not a whole label — `" — Raindrops (11.5–12.0 mm)"` — because the name in
/// front is not always the print's. For an M adding stock under one brand, the row should read the
/// word stamped on THAT brand's box (`601001`), since that is what he is holding. The suffix is
/// what turns a print into a PIECE, and it is needed just the same: a print carrying two pieces
/// gives two `601001`s.
///
/// libraryId -> suffix.
Map<String, String> pieceSuffixes(List<LibraryEntry> library) {
  // Group the pieces by the PRINT they are made from — a label only has to be unambiguous
  // among its own siblings.
  final byPrint = <String, List<LibraryEntry>>{};
  for (final e in library) {
    final key = e.printId.isNotEmpty ? e.printId : '${e.masterName}|${e.size}';
    (byPrint[key] ??= <LibraryEntry>[]).add(e);
  }

  final out = <String, String>{};
  for (final group in byPrint.values) {
    for (final e in group) {
      final surface = pieceSurfaceWord(e);
      final thickness = _forkedThickness(e, group);
      out[e.id] = [
        if (surface.isNotEmpty) ' — $surface',
        if (thickness != null) ' ($thickness)',
      ].join();
    }
  }
  return out;
}

/// The surface as the stockist reads it: HIS word if he has one, else the admin canonical.
/// Never blank in practice — `surface_type` is NOT NULL.
String pieceSurfaceWord(LibraryEntry e) {
  final own = e.surfaceLabel.trim();
  return own.isNotEmpty ? own : e.surfaceType.trim();
}

/// The thickness to show in brackets beside a piece, or null for a plain label.
///
/// A print+surface+body holds more than one piece only when the thicknesses are more than 1 mm
/// apart — a genuinely different tile (box weight drifts in the trade; 0.62 mm is the SAME tile).
/// The FIRST one created is the original and reads plainly; anything forked off it later carries
/// its thickness so the two can be told apart.
String? _forkedThickness(LibraryEntry e, List<LibraryEntry> group) {
  if (e.thicknessMm == null) return null;
  final siblings = group.where((o) =>
      o.surfaceType == e.surfaceType && o.tileType == e.tileType);
  if (siblings.length < 2) return null; // the only one of its kind — nothing to tell apart

  // The oldest is the original. A piece with no date sorts as oldest-unknown and keeps its plain
  // label rather than being mislabelled as the fork.
  DateTime? oldest;
  for (final o in siblings) {
    if (o.createdAt == null) continue;
    if (oldest == null || o.createdAt!.isBefore(oldest)) oldest = o.createdAt;
  }
  if (oldest == null || e.createdAt == null) return null;
  if (!e.createdAt!.isAfter(oldest)) return null; // this IS the original

  return thicknessBandLabel(e.thicknessMm);
}
