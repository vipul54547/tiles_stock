/// Shared responsive helpers.
///
/// Tile grids show more columns on wider windows (phone → tablet → desktop →
/// large monitor). Keyed off the available WIDTH, not the OS, so a resized web
/// window re-flows live. Used by every buyer browsing grid so they all agree.
int gridColumnsFor(double width) {
  if (width < 600) return 2;   // phones
  if (width < 900) return 3;   // small tablets / split view
  if (width < 1300) return 4;  // desktop
  if (width < 1700) return 5;  // large desktop
  return 6;                    // very wide monitors
}
