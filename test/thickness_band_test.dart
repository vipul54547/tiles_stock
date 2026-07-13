// 🔑 A thickness is ALWAYS shown as a 0.5 mm BAND — "8.5–9.0 mm", never a bare "8.8 mm".
// It is derived from box weight rather than measured, real tiles vary, and every thickness
// filter in the app (buyer, stockist, /s/) chips on these bands. The DB agrees:
// `stockist_library.thickness_band` is a GENERATED column, `floor(thickness_mm / 0.5) * 0.5`.
//
// This test exists because the BOX chapter shipped a chip that printed a bare "8.8 mm".
import 'package:flutter_test/flutter_test.dart';
import 'package:tiles_stock/utils/tile_types.dart';

void main() {
  group('thicknessBandLabel — always a 0.5 mm range, never a bare number', () {
    test('bands to the 0.5 mm floor, like the generated column', () {
      expect(thicknessBandLabel(8.8), '8.5–9.0 mm');
      expect(thicknessBandLabel(8.5), '8.5–9.0 mm'); // a boundary belongs to the band it opens
      expect(thicknessBandLabel(8.49), '8.0–8.5 mm');
      expect(thicknessBandLabel(8.0), '8.0–8.5 mm');
      expect(thicknessBandLabel(10.2), '10.0–10.5 mm');
    });

    test('matches the DB: floor(mm / 0.5) * 0.5', () {
      for (final mm in [6.1, 7.99, 8.0, 8.3, 9.75, 12.4]) {
        final low = (mm / 0.5).floor() * 0.5;
        expect(thicknessBandLabel(mm),
            '${low.toStringAsFixed(1)}–${(low + 0.5).toStringAsFixed(1)} mm');
      }
    });

    test('no thickness -> no band (never a bogus "0.0-0.5 mm")', () {
      expect(thicknessBandLabel(0), isNull);
      expect(thicknessBandLabel(null), isNull);
      expect(thicknessBandLabel(-1), isNull);
    });

    // The live preview in the box editor derives from what is being typed; the chip reads
    // the value the server derived. They must land in the SAME band or the number would
    // appear to change on save.
    test('typed-box preview agrees with the stored value', () {
      // 4 pcs of 600x600 at 24 kg, PGVT & GVT.
      final t = approxThicknessMm('600x600', 4, 24, 'PGVT & GVT');
      expect(t, isNotNull);
      expect(thicknessRangeLabel('600x600', 4, 24, 'PGVT & GVT'),
          thicknessBandLabel(t));
    });
  });
}
