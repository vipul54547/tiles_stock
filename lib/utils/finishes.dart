/// Canonical finish (surface) options, shared by the add/edit form, the PDF
/// import picker and every search filter so they never drift apart.
///
/// 'None' is always last — it is selected when a tile's finish is unknown or is
/// something not in this list. In that case the original finish text from the
/// PDF is preserved separately in `TileDesign.finishLabel` and shown as a badge.
const List<String> kFinishes = [
  'Glossy',
  'Matt',
  'Satin',
  'Polished',
  'Rustic',
  'Carving',
  'Lappato',
  'Sugar',
  'None',
];
