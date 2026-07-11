import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiles_stock/models/brand.dart';
import 'package:tiles_stock/models/tile_design.dart';
import 'package:tiles_stock/widgets/holding_entry_bar.dart';

/// The keyboard entry bar for a dispatch / order line.
///
/// The thing it exists to prevent: one print held in several brand × quality ×
/// surface variants, picked wrong. `DELTON_8_A` below is FOUR holdings. So the
/// bar must (a) show the print once, (b) offer only variants actually in stock,
/// (c) put a box count on every option, and (d) refuse to add a line while the
/// choices still leave more than one holding standing.
void main() {
  TileDesign holding({
    required String id,
    required String name,
    required String library,
    required String quality,
    required String surface,
    required int boxes,
    String? brandId,
  }) =>
      TileDesign(
        id: id,
        name: name,
        size: '600x600 mm',
        boxQuantity: boxes,
        surfaceType: surface,
        surfaceLabel: surface,
        piecesPerBox: 4,
        boxWeightKg: 20,
        thicknessMm: 9,
        colour: 'Beige',
        faceImageUrls: const [],
        stockistId: 's1',
        brandId: brandId ?? 'b1',
        libraryId: library,
        updatedAt: DateTime(2026, 7, 11),
        quality: quality,
        stockType: 'P',
      );

  // DELTON_8_A: one print, FOUR holdings. CANYON: one print, ONE holding.
  final stock = <TileDesign>[
    holding(
        id: 'd1',
        name: 'DELTON_8_A',
        library: 'lib-delton',
        quality: 'Premium',
        surface: 'Matt',
        boxes: 121),
    holding(
        id: 'd2',
        name: 'DELTON_8_A',
        library: 'lib-delton',
        quality: 'Standard',
        surface: 'Matt',
        boxes: 5),
    holding(
        id: 'd3',
        name: 'DELTON_8_A',
        library: 'lib-delton',
        quality: 'Premium',
        surface: 'Sugar',
        boxes: 101),
    holding(
        id: 'd4',
        name: 'DELTON_8_A',
        library: 'lib-delton',
        quality: 'Standard',
        surface: 'Sugar',
        boxes: 8),
    holding(
        id: 'c1',
        name: 'CANYON 03_A',
        library: 'lib-canyon',
        quality: 'Premium',
        surface: 'Matt',
        boxes: 345),
  ];

  final brands = [Brand(id: 'b1', name: 'LIVOK')];

  final added = <(String, int)>[];

  Widget host() {
    added.clear();
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1200,
          child: HoldingEntryBar(
            designs: stock,
            brands: brands,
            boxesOf: (d) => d.boxQuantity,
            onAdd: (d, qty) async {
              added.add((d.id, qty));
              return true;
            },
          ),
        ),
      ),
    );
  }

  Finder designBox() => find.byType(TextField).first;

  testWidgets('the print list shows DELTON_8_A ONCE, not four times',
      (t) async {
    await t.pumpWidget(host());
    await t.tap(designBox());
    await t.pumpAndSettle();

    expect(find.text('DELTON_8_A'), findsOneWidget,
        reason: 'four holdings, but they are ONE print');
    expect(find.text('CANYON 03_A'), findsOneWidget);
    // The row warns that a second question is coming, and totals the boxes.
    expect(find.textContaining('2 surfaces'), findsOneWidget);
    expect(find.textContaining('2 qualities'), findsOneWidget);
    expect(find.textContaining('235 boxes'), findsOneWidget);
  });

  testWidgets('a single-variant print resolves on the design pick alone',
      (t) async {
    await t.pumpWidget(host());
    await t.enterText(designBox(), 'canyon');
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pumpAndSettle();

    // CANYON is one holding — nothing left to ask. Its count is already showing.
    expect(find.text('of 345'), findsOneWidget);

    await t.enterText(find.byType(TextField).last, '40');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pumpAndSettle();

    expect(added, [('c1', 40)]);
  });

  testWidgets('an ambiguous print will NOT be added until it is narrowed',
      (t) async {
    await t.pumpWidget(host());
    await t.enterText(designBox(), 'delton');
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextField).last, '40');
    await t.tap(find.text('Add'));
    await t.pumpAndSettle();

    expect(added, isEmpty,
        reason: 'four holdings still standing — adding one would be a guess');
    expect(find.textContaining('more than one version'), findsOneWidget);
  });

  testWidgets('narrowing surface + quality lands on exactly one holding',
      (t) async {
    await t.pumpWidget(host());
    await t.enterText(designBox(), 'delton');
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pumpAndSettle();

    // Surface: both options carry their box count — Matt holds 121+5, Sugar 101+8.
    final surface = find.byType(TextField).at(2);
    await t.tap(surface);
    await t.pumpAndSettle();
    expect(find.text('126 boxes'), findsOneWidget, reason: 'Matt: 121 + 5');
    expect(find.text('109 boxes'), findsOneWidget, reason: 'Sugar: 101 + 8');

    await t.enterText(surface, 'matt');
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pumpAndSettle();

    // Quality now offers only what Matt is actually held in, with ITS counts.
    final quality = find.byType(TextField).at(3);
    await t.tap(quality);
    await t.pumpAndSettle();
    expect(find.text('121 boxes'), findsOneWidget, reason: 'Matt + Premium');
    expect(find.text('5 boxes'), findsOneWidget, reason: 'Matt + Standard');

    await t.enterText(quality, 'stand');
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pumpAndSettle();

    // One holding left: d2, Matt + Standard, 5 boxes.
    expect(find.text('of 5'), findsOneWidget);

    await t.enterText(find.byType(TextField).last, '3');
    await t.tap(find.text('Add'));
    await t.pumpAndSettle();

    expect(added, [('d2', 3)],
        reason: 'Standard Matt — NOT the 121-box Premium sitting next to it');
  });
}
