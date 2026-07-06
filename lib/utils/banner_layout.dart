/// Banner overlay placement helpers for the per-brand /s/ catalogue banner
/// ([[project_brand_admin_console]] two-path overlay banner).
///
/// The company logo (or, when there is none, the big company NAME) is placed on a
/// 9-grid. The big NAME must NOT use the middle row: a wide name in the centre
/// band collides with the catalogue grid below it, so a middle-row choice falls
/// back to the bottom-row equivalent. The admin dropdown hides the middle row in
/// name mode; the renderer coerces any legacy value the same way.
library;

import 'package:flutter/widgets.dart';

/// Maps a 9-grid placement key (+ 'footer') to a Flutter [Alignment]. Shared by
/// the public /s/ banner and the stockist editor preview so both place overlays
/// identically.
Alignment alignFor(String pos) {
  switch (pos) {
    case 'top-left':
      return Alignment.topLeft;
    case 'top-center':
      return Alignment.topCenter;
    case 'top-right':
      return Alignment.topRight;
    case 'middle-left':
      return Alignment.centerLeft;
    case 'center':
      return Alignment.center;
    case 'middle-right':
      return Alignment.centerRight;
    case 'bottom-left':
      return Alignment.bottomLeft;
    case 'bottom-center':
    case 'footer':
      return Alignment.bottomCenter;
    case 'bottom-right':
      return Alignment.bottomRight;
    default:
      return Alignment.center;
  }
}

/// All company placements: 9 grid cells + "none" (hidden). Used when a logo is
/// set (a small logo sits fine anywhere).
const List<String> kCompanyPosAll = [
  'none', 'top-left', 'top-center', 'top-right', 'middle-left', 'center',
  'middle-right', 'bottom-left', 'bottom-center', 'bottom-right',
];

/// Company placements offered when the big NAME shows (no logo): middle row
/// dropped.
const List<String> kCompanyPosNoMiddle = [
  'none', 'top-left', 'top-center', 'top-right',
  'bottom-left', 'bottom-center', 'bottom-right',
];

/// The placements valid for the current overlay: all 9 with a logo, the
/// no-middle set without one.
List<String> companyPosKeys({required bool hasLogo}) =>
    hasLogo ? kCompanyPosAll : kCompanyPosNoMiddle;

/// Resolves the effective company position. With a logo every cell is valid;
/// without one (big name) a middle-row value falls back to the bottom-row
/// equivalent so the name never lands in the centre band.
String effectiveCompanyPos(String pos, {required bool hasLogo}) {
  if (hasLogo) return pos;
  switch (pos) {
    case 'middle-left':
      return 'bottom-left';
    case 'center':
      return 'bottom-center';
    case 'middle-right':
      return 'bottom-right';
    default:
      return pos;
  }
}
