import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiles_stock/widgets/combo_field.dart';

/// The entry-bar combo field: type, arrow, or click. All three must select.
///
/// These exist because the first cut shipped two faults no build could catch:
/// the overlay put `Positioned` under a `TapRegion` (no Stack parent → it threw,
/// and a release build painted a grey box over the whole screen), and a tap on a
/// row blurred the text field so the tap never landed. Pumping the widget finds
/// both in a second.
void main() {
  const brands = ['FAMOUS', 'CURA', 'PREM', 'KHAKHI'];

  /// The field wired to a piece of state, exactly as the entry bar wires it.
  Widget host(void Function(String) onSelected) => MaterialApp(
        home: Scaffold(
          body: Center(child: _Host(brands: brands, onSelected: onSelected)),
        ),
      );

  testWidgets('opening the menu does not throw', (t) async {
    await t.pumpWidget(host((_) {}));
    await t.tap(find.byType(TextField));
    await t.pumpAndSettle();

    // Positioned outside its Stack throws here — silently, as a grey screen, in
    // a release build.
    expect(t.takeException(), isNull);
    for (final b in brands) {
      expect(find.text(b), findsOneWidget);
    }
  });

  testWidgets('clicking a row selects it', (t) async {
    String? picked;
    await t.pumpWidget(host((s) => picked = s));
    await t.tap(find.byType(TextField));
    await t.pumpAndSettle();

    await t.tap(find.text('CURA'));
    await t.pumpAndSettle();

    expect(picked, 'CURA');
    expect(find.text('KHAKHI'), findsNothing, reason: 'menu should have closed');
  });

  testWidgets('typing filters, and arrow down selects the match', (t) async {
    String? picked;
    await t.pumpWidget(host((s) => picked = s));

    await t.enterText(find.byType(TextField), 'f');
    await t.pumpAndSettle();
    expect(find.text('CURA'), findsNothing, reason: 'should be filtered out');

    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pumpAndSettle();
    expect(picked, 'FAMOUS', reason: 'arrowing IS selecting');
  });

  testWidgets('Tab takes the typed match and moves on', (t) async {
    String? picked;
    await t.pumpWidget(host((s) => picked = s));

    await t.enterText(find.byType(TextField), 'kha');
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pumpAndSettle();

    expect(picked, 'KHAKHI');
  });

  testWidgets('Tab straight through an untouched field picks nothing',
      (t) async {
    String? picked;
    await t.pumpWidget(host((s) => picked = s));

    await t.tap(find.byType(TextField));
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pumpAndSettle();

    expect(picked, isNull,
        reason: 'tabbing past a field must not silently pick the first option');
  });
}

class _Host extends StatefulWidget {
  final List<String> brands;
  final void Function(String) onSelected;
  const _Host({required this.brands, required this.onSelected});
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  String? _value;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 200,
        child: ComboField<String>(
          value: _value,
          options: widget.brands,
          labelOf: (s) => s,
          hint: 'Select brand',
          onSelected: (s) {
            setState(() => _value = s);
            widget.onSelected(s);
          },
        ),
      );
}
