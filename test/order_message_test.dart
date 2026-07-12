import 'package:flutter_test/flutter_test.dart';
import 'package:tiles_stock/utils/order_message.dart';

// The buyer's WhatsApp order from the login-free /s/ catalogue. When
// create_web_order fails there is NO order number to open in the app, so the
// message must still carry every line (the stockist fulfils it by hand) plus a
// note telling them to add it manually. See public_catalog_screen._enquire.
void main() {
  const lines = <OrderLine>[
    (
      name: 'Alaska White',
      size: '300x450 mm',
      surface: 'Glossy',
      quality: 'Premium',
      qty: 10
    ),
    (
      name: 'Onyx Black',
      size: '600x600 mm',
      surface: 'Matt',
      quality: 'Standard',
      qty: 12
    ),
  ];

  test('a saved order carries its order no + code, and no note', () {
    final msg = buildOrderMessage(lines,
        orderNo: 'INQ-000126', connectionCode: 'C-11171207');

    expect(msg, contains('Order: INQ-000126'));
    expect(msg, contains('[C-11171207]'));
    expect(msg, isNot(contains('NOTE')));
    expect(msg, contains('*Total: 22 boxes*'));
  });

  test('an unsaved order still carries every line, plus the manual-add note',
      () {
    final msg = buildOrderMessage(lines,
        orderNo: '',
        connectionCode: '',
        note: 'NOTE: This order did not reach the app. '
            'Please add it manually and confirm with the buyer.');

    // The note reaches the stockist...
    expect(msg, contains('Please add it manually and confirm with the buyer.'));

    // ...and, crucially, the order is still fulfillable by hand: every design,
    // quantity and quality is present even though nothing was saved.
    expect(msg, contains('PRM-10-Alaska White'));
    expect(msg, contains('STD-12-Onyx Black'));
    expect(msg, contains('*300x450*  *Glossy*'));
    expect(msg, contains('*600x600*  *Matt*'));
    expect(msg, contains('*Total: 22 boxes*'));

    // A blank order no / code must never print an empty "Order:" or "[]" line.
    expect(msg, isNot(contains('Order: \n')));
    expect(msg, isNot(contains('[]')));
  });
}
