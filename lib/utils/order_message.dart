/// A single order/enquiry line, resolved to what the buyer wants.
typedef OrderLine = ({
  String name,
  String size,
  String surface,
  String quality,
  int qty,
});

/// Builds a WhatsApp order/enquiry message in the plain-text grouped format:
///
///   Order Request
///   Order: INQ 1234        <- only if [orderNo] given
///   [C-4B0712]             <- only if [connectionCode] given
///   *NOTE ...*             <- only if [note] given (no order was saved)
///                          <- blank line
///   *300x450*  *Glossy*    <- bold size + surface header
///   PRM-10-Alaska White
///   STD-5-Alaska Grey
///
///   *600x600*  *Matt*      <- new header whenever size OR surface changes
///   STD-12-Onyx Black
///
///   *Total: 27 boxes*
///
/// Each design row is `PRM-`/`STD-` + `qty-` + design name. Designs are grouped
/// by (size + surface); a fresh bold header prints whenever either changes.
/// No greeting, no "powered by" footer.
///
/// [note] is for the one case where the buyer's order could NOT be saved: the
/// message still carries every line so the stockist can fulfil it, but there is
/// no order number to open in the app, so the note tells them to add it by hand.
String buildOrderMessage(
  List<OrderLine> lines, {
  String? orderNo,
  String? connectionCode,
  String? note,
}) {
  // Group by (size + surface), preserving first-seen order.
  final order = <String>[];
  final groups = <String, List<OrderLine>>{};
  final sizeOf = <String, String>{};
  final surfaceOf = <String, String>{};
  for (final l in lines) {
    final sz = l.size.replaceAll(' mm', '').trim();
    final sf = l.surface.trim();
    final k = '$sz|$sf';
    if (!groups.containsKey(k)) {
      order.add(k);
      sizeOf[k] = sz;
      surfaceOf[k] = sf;
    }
    (groups[k] ??= []).add(l);
  }

  final b = StringBuffer()..writeln('Order Request');
  if (orderNo != null && orderNo.trim().isNotEmpty) {
    b.writeln('Order: ${orderNo.trim()}');
  }
  if (connectionCode != null && connectionCode.trim().isNotEmpty) {
    b.writeln('[${connectionCode.trim()}]');
  }
  if (note != null && note.trim().isNotEmpty) {
    b.writeln('*${note.trim()}*');
  }

  var total = 0;
  for (final k in order) {
    final sz = sizeOf[k]!;
    final sf = surfaceOf[k]!;
    b
      ..writeln()
      ..writeln(sf.isEmpty ? '*$sz*' : '*$sz*  *$sf*');
    for (final l in groups[k]!) {
      total += l.qty;
      final q =
          l.quality.trim().toLowerCase().startsWith('p') ? 'PRM' : 'STD';
      b.writeln('$q-${l.qty}-${l.name}');
    }
  }

  b
    ..writeln()
    ..writeln('*Total: $total boxes*');
  return b.toString();
}
