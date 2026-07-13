// 🔑 A thickness is ALWAYS shown as a 0.5 mm BAND — "8.5–9.0 mm", never a bare "8.8 mm".
// It is derived from box weight rather than measured, real tiles vary, and every thickness
// filter in the app (buyer, stockist, /s/) chips on these bands. The DB agrees:
// `stockist_library.thickness_band` is a GENERATED column, `floor(thickness_mm / 0.5) * 0.5`.
//
// This test exists because the BOX chapter shipped a chip that printed a bare "8.8 mm".
import 'package:flutter_test/flutter_test.dart';
import 'package:tiles_stock/models/tile_design.dart';
import 'package:tiles_stock/utils/tile_types.dart';

/// A product with no BOX spec resolves pieces/weight/thickness to NULL server-side.
/// Before the BOX chapter these columns were NOT NULL and came back as 0, so the model
/// parsed them unguarded — and the first NULL crashed the buyer app on 27 live rows.
Map<String, dynamic> _json({
  Object? pieces,
  Object? weight,
  Object? thickness,
}) => {
      'id': 'd1',
      'name': 'ANT BIANCO',
      'size': '600x1200 mm',
      'box_quantity': 12,
      'surface_type': 'Glossy',
      'pieces_per_box': pieces,
      'box_weight_kg': weight,
      'thickness_mm': thickness,
      'colour': 'White',
      'face_image_urls': <String>[],
      'stockist_id': 's1',
      'updated_at': '2026-07-13T00:00:00Z',
    };

void main() {
  group('a product with no BOX spec parses, and stays honest', () {
    test('NULL pieces/weight/thickness do not throw', () {
      final d = TileDesign.fromJson(_json());
      expect(d.piecesPerBox, 0);   // 0 is the app's "unknown" — every chip hides it
      expect(d.boxWeightKg, 0);
      expect(d.thicknessMm, isNull); // but a tile is never 0 mm THICK: unknown is null
    });

    test('an unknown thickness yields no band, not a bogus one', () {
      expect(thicknessBandLabel(TileDesign.fromJson(_json()).thicknessMm), isNull);
    });

    test('a real box spec still comes through intact', () {
      final d = TileDesign.fromJson(
          _json(pieces: 2, weight: 27.0, thickness: 8.4));
      expect(d.piecesPerBox, 2);
      expect(d.boxWeightKg, 27.0);
      expect(thicknessBandLabel(d.thicknessMm), '8.0–8.5 mm');
    });
  });

  // The DECLARED thickness is a 0.5 mm BAND (4.0–4.5 … 19.5–20.0), not a round number: a real tile
  // is 8.86 mm, not 9 mm. Because the bands tile the range, a figure lands in exactly ONE band —
  // so proposing it is not a rounding, it is the band that figure is already in.
  group('thicknessBandFor — the band a measured figure is IN', () {
    test('places a derived figure in its band', () {
      expect(thicknessBandFor(7.99), 7.5);   // the Porcelain artifact
      expect(thicknessBandFor(8.86), 8.5);
      expect(thicknessBandFor(9.30), 9.0);
      expect(thicknessBandFor(8.50), 8.5);   // a boundary opens its band
      expect(thicknessBandFor(4.08), 4.0);   // now IN range — 4.0 is a real band
    });

    test('proposes NOTHING outside the declarable range', () {
      // Below 4 mm or at/above 20 mm is not a tile — it is a bad box weight. Better to leave the
      // row undeclared (the server then adopts an existing product) than to declare a wrong one.
      expect(thicknessBandFor(3.9), isNull);
      expect(thicknessBandFor(20.0), isNull);
      expect(thicknessBandFor(null), isNull);
      expect(thicknessBandFor(0), isNull);
    });

    test('reads back as the band, not a bare figure', () {
      expect(thicknessLabel(8.5), '8.5–9.0 mm');
      expect(thicknessLabel(4.0), '4.0–4.5 mm');
      expect(thicknessLabel(19.5), '19.5–20.0 mm');
    });
  });

  // What a stockist can plausibly write in the sheet: the band as offered, or a bare measurement.
  group('parseDeclaredThickness — reads what they wrote', () {
    test('accepts the band as the template offers it', () {
      expect(parseDeclaredThickness('8.5–9.0 mm'), 8.5);
      expect(parseDeclaredThickness('8.5-9.0'), 8.5);
    });

    test('accepts a bare measurement and places it in its band', () {
      expect(parseDeclaredThickness('8.86'), 8.5);
      expect(parseDeclaredThickness('9'), 9.0);
      expect(parseDeclaredThickness(' 10 mm '), 10.0);
    });

    test('refuses what it cannot read — the caller must ERROR, not guess', () {
      expect(parseDeclaredThickness(''), isNull);
      expect(parseDeclaredThickness('thick'), isNull);
      expect(parseDeclaredThickness('25'), isNull);  // not a tile
      expect(parseDeclaredThickness('2'), isNull);
    });
  });

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
