// Smoke test for ExcelTemplateService: builds both skins (T/W single-brand and M
// multi-brand) with representative config and writes them to build/test_out/ so
// the generated .xlsx can be inspected (headers, colours, dropdowns, legend).
// A free-text DNA attribute (Range) is included to prove it's excluded.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiles_stock/utils/tile_types.dart';
import 'package:tiles_stock/services/excel_template_service.dart';
import 'package:tiles_stock/models/dna.dart';
import 'package:tiles_stock/models/brand.dart';
import 'package:tiles_stock/utils/finishes.dart';

void main() {
  final sizes = ['600x1200', '800x1600', '600x600'];
  // The stockist's OWN words, as my_surface_options() hands them over: "Raindrop"
  // is this stockist's word for the canonical Sugar; the rest they have no word of
  // their own for, so the admin name stands in. 'None' is NOT a surface and must
  // never appear in a picker.
  final surfaceWords = ['Raindrop', 'Matt', 'Glossy', 'Carving'];
  final tileTypes = ['PGVT & GVT', 'Porcelain', 'Ceramic'];
  // The declarable thicknesses, as the template offers them: 0.5 mm BANDS, picked not typed.
  final thicknesses = ['8.0–8.5 mm', '8.5–9.0 mm', '9.0–9.5 mm'];
  final dnaAttrs = <DnaAttribute>[
    const DnaAttribute(id: 'a-colour', name: 'Colour', isMulti: true, values: [
      DnaValue(id: 'c1', name: 'White'),
      DnaValue(id: 'c2', name: 'Blue'),
      DnaValue(id: 'c3', name: 'Beige'),
    ]),
    const DnaAttribute(id: 'a-look', name: 'Look', values: [
      DnaValue(id: 'l1', name: 'Marble'),
      DnaValue(id: 'l2', name: 'Wood'),
    ]),
    // Free text → must NOT appear as a template column.
    const DnaAttribute(id: 'a-range', name: 'Range', isFreeText: true),
  ];

  Brand brand(String id, String name, {bool isDefault = false}) =>
      Brand(id: id, name: name, isDefault: isDefault);

  setUpAll(() => Directory('build/test_out').createSync(recursive: true));

  // Thickness is IDENTITY, so the template OFFERS it rather than inviting a typed figure. Whatever
  // it offers must survive the round trip back through the importer's parser, or a stockist who
  // picked from our own dropdown would get "not one of..." thrown back at them on import.
  test('every thickness the template offers parses back to a real band', () {
    expect(thicknessOptions, isNotEmpty);
    for (final mm in thicknessOptions) {
      expect(parseDeclaredThickness(thicknessLabel(mm)), mm,
          reason: '"${thicknessLabel(mm)}" does not round-trip');
    }
  });

  // 🚫 'None' is not a surface. It is part of the product key, so offering it forges
  // a phantom product beside the real one — and the DB refuses it outright. kFinishes
  // is the last-resort fallback when the admin list can't be read, and it carried a
  // 'None' that leaked all the way into a stockist's downloaded template.
  test("'None' is never offered as a surface", () {
    expect(kFinishes.map((f) => f.toLowerCase()), isNot(contains('none')));
  });

  test('T/W single-brand template builds and writes', () {
    final bytes = ExcelTemplateService.buildStockTemplate(
      multiBrand: false,
      sizes: sizes,
      surfaceWords: surfaceWords,
      tileTypes: tileTypes,
      thicknesses: thicknesses,
      dnaAttrs: dnaAttrs,
      brands: [brand('br1', 'VERITAAS', isDefault: true)],
    );
    expect(bytes, isNotEmpty);
    File('build/test_out/tw_template.xlsx').writeAsBytesSync(bytes);
  });

  test('M multi-brand template builds and writes', () {
    final bytes = ExcelTemplateService.buildStockTemplate(
      multiBrand: true,
      sizes: sizes,
      surfaceWords: surfaceWords,
      tileTypes: tileTypes,
      thicknesses: thicknesses,
      dnaAttrs: dnaAttrs,
      brands: [
        brand('br1', 'BOTTEGA', isDefault: true),
        brand('br2', 'CERA TILES'),
        brand('br3', 'ENNFACE'),
      ],
    );
    expect(bytes, isNotEmpty);
    File('build/test_out/m_template.xlsx').writeAsBytesSync(bytes);
  });
}
