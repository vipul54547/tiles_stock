import 'package:flutter_test/flutter_test.dart';
import 'package:tiles_stock/app.dart';

void main() {
  testWidgets('App builds without error', (WidgetTester tester) async {
    await tester.pumpWidget(const TilesStockApp());
    expect(find.byType(TilesStockApp), findsOneWidget);
  });
}
