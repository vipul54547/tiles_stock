/// A single order/enquiry line, resolved to what the buyer wants.
typedef OrderLine = ({String name, String size, String quality, int qty});

/// Builds a WhatsApp order/enquiry message. Designs are grouped by size — each
/// size gets a bold title, then a fixed-width MONOSPACE table (wrapped in triple
/// backticks so the columns align on the phone): design name | quality | qty.
/// No greeting, no "powered by" footer — just the order.
///
/// [headerExtras] are extra lines printed right under the title (e.g. an order
/// number / connection code).
String buildOrderMessage(List<OrderLine> lines,
    {List<String> headerExtras = const []}) {
  const nameW = 13; // narrow enough that a line never wraps on a phone
  String padR(String s) =>
      (s.length > nameW ? '${s.substring(0, nameW - 1)}…' : s).padRight(nameW);
  String padL(Object s, int w) => '$s'.padLeft(w);

  // Group by size, preserving first-seen order.
  final order = <String>[];
  final bySize = <String, List<OrderLine>>{};
  for (final l in lines) {
    final sz = l.size.replaceAll(' mm', '').trim();
    if (!bySize.containsKey(sz)) order.add(sz);
    (bySize[sz] ??= []).add(l);
  }

  final b = StringBuffer()..writeln('*Order Request*');
  for (final e in headerExtras) {
    b.writeln(e);
  }

  var total = 0;
  for (final sz in order) {
    b
      ..writeln()
      ..writeln('*$sz*')
      ..writeln('```')
      ..writeln('${padR('Design')}| Q |${padL('Qty', 5)}')
      ..writeln('${'-' * nameW}|---|-----');
    for (final l in bySize[sz]!) {
      total += l.qty;
      final g = l.quality.trim().toLowerCase().startsWith('p') ? 'P' : 'S';
      b.writeln('${padR(l.name)}| $g |${padL(l.qty, 5)}');
    }
    b.writeln('```');
  }

  b
    ..writeln()
    ..writeln('*Total: $total boxes*');
  return b.toString();
}
