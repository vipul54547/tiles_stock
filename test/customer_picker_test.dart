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
