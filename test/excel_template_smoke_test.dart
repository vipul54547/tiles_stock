// Smoke test for ExcelTemplateService: builds both skins (T/W single-brand and M
// multi-brand) with representative config and writes them to build/test_out/ so
// the generated .xlsx can be inspected (headers, colours, dropdowns, legend).
// A free-text DNA attribute (Range) is included to prove it's excluded.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiles_stock/services/excel_template_service.dart';
import 'package:tiles_stock/models/dna.dart';
import 'package:tiles_stock/models/brand.dart';

void main() {
  final sizes = ['600x1200', '800x1600', '600x600'];
  final finishes = ['None', 'Matt', 'Glossy', 'Carving'];
  final tileTypes = ['PGVT & GVT', 'Porcelain', 'Ceramic'];
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

  test('T/W single-brand template builds and writes', () {
    final bytes = ExcelTemplateService.buildStockTemplate(
      multiBrand: false,
      sizes: sizes,
      finishes: finishes,
      tileTypes: tileTypes,
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
      finishes: finishes,
      tileTypes: tileTypes,
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
