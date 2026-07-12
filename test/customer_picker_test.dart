import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiles_stock/services/supabase_data_service.dart';
import 'package:tiles_stock/widgets/customer_picker.dart';

/// The shared saved-customer picker (Dispatch + Add Order). These pump the
/// pick/search/select paths — none of which call the data service — so no live
/// Supabase is needed. The New-customer save path (the only one that hits the
/// service) is left for on-device verification.
void main() {
  final customers = <Map<String, dynamic>>[
    {'id': 'c1', 'name': 'Ramesh Traders', 'city': 'Bopal', 'phone': '9111'},
    {'id': 'c2', 'name': 'Suresh Tiles', 'city': 'Maninagar', 'phone': ''},
  ];

  Future<Map<String, dynamic>?> openAndReturn(WidgetTester tester) async {
    Map<String, dynamic>? result;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              result = await CustomerPicker.show(ctx,
                  customers: customers, svc: SupabaseDataService());
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('lists saved customers + the New-customer option', (tester) async {
    await openAndReturn(tester);
    expect(find.text('New customer'), findsOneWidget);
    expect(find.text('Ramesh Traders'), findsOneWidget);
    expect(find.text('Suresh Tiles'), findsOneWidget);
  });

  testWidgets('tapping a customer returns that exact row', (tester) async {
    Map<String, dynamic>? result;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              result = await CustomerPicker.show(ctx,
                  customers: customers, svc: SupabaseDataService());
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Suresh Tiles'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!['id'], 'c2');
    expect(result!['name'], 'Suresh Tiles');
  });

  // State + District are compulsory on a new customer: a saved customer with no
  // place is useless in the directory, and the pincode lookup needs the network.
  testWidgets('New customer: Save stays disabled until name + state + district',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await openAndReturn(tester);
    await tester.tap(find.text('New customer'));
    await tester.pumpAndSettle();

    ElevatedButton saveBtn() => tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Save'));
    Future<void> pick(Finder dropdown, String option) async {
      await tester.ensureVisible(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text(option).last);
      await tester.pumpAndSettle();
    }

    expect(find.text('State *'), findsOneWidget);
    expect(find.text('District *'), findsOneWidget);
    expect(saveBtn().onPressed, isNull, reason: 'empty form');

    await tester.enterText(find.widgetWithText(TextField, 'Name *'), 'Ramesh');
    await tester.pumpAndSettle();
    expect(saveBtn().onPressed, isNull, reason: 'name alone is not enough');

    await pick(find.byType(DropdownButtonFormField<String>).first, 'Gujarat');
    expect(saveBtn().onPressed, isNull, reason: 'state without district');

    await pick(find.byType(DropdownButtonFormField<String>).last, 'Morbi');
    expect(saveBtn().onPressed, isNotNull, reason: 'name + state + district');
  });

  testWidgets('search narrows the list to the match', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () => CustomerPicker.show(ctx,
                customers: customers, svc: SupabaseDataService()),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'suresh');
    await tester.pumpAndSettle();

    expect(find.text('Suresh Tiles'), findsOneWidget);
    expect(find.text('Ramesh Traders'), findsNothing);
  });
}
