import 'dart:ui' show Rect;
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// One line on a dispatch note.
class DispatchPdfLine {
  final String name;
  final String size;
  final String surface; // "Word (Canonical)" or ''
  final String quality;
  final int boxes;
  const DispatchPdfLine({
    required this.name,
    required this.size,
    required this.surface,
    required this.quality,
    required this.boxes,
  });
}

/// Everything a printed dispatch note shows. Kept as a plain payload so the PDF
/// can be built (and unit-tested) without any widget/state. (project_customer_history)
class DispatchPdfData {
  final String stockistName;
  final String who; // customer name / order token label, '' when unknown
  final String dispatchNo;
  final String date;
  final String invoice;
  final String vehicle;
  final String transporter;
  final String note;
  final List<DispatchPdfLine> lines;
  final int total;
  final String balanceLine; // outstanding/closed note, '' when none
  const DispatchPdfData({
    required this.stockistName,
    required this.who,
    required this.dispatchNo,
    required this.date,
    required this.invoice,
    required this.vehicle,
    required this.transporter,
    required this.note,
    required this.lines,
    required this.total,
    required this.balanceLine,
  });
}

/// Build an A4 dispatch note and return its bytes. Uses syncfusion (already a
/// dependency); the `printing` package prints or shares these bytes.
Future<List<int>> buildDispatchPdf(DispatchPdfData d) async {
  final doc = PdfDocument();
  final page = doc.pages.add();
  final g = page.graphics;
  final w = page.getClientSize().width;

  final titleFont = PdfStandardFont(PdfFontFamily.helvetica, 18,
      style: PdfFontStyle.bold);
  final h2 = PdfStandardFont(PdfFontFamily.helvetica, 12,
      style: PdfFontStyle.bold);
  final body = PdfStandardFont(PdfFontFamily.helvetica, 10);

  double y = 0;
  void line(String s, PdfFont f, {double gap = 2}) {
    g.drawString(s, f, bounds: Rect.fromLTWH(0, y, w, f.height + 2));
    y += f.height + gap;
  }

  line('DISPATCH NOTE', titleFont, gap: 4);
  if (d.stockistName.trim().isNotEmpty) line(d.stockistName, h2, gap: 6);

  // Meta block — only the fields that are filled.
  for (final e in <MapEntry<String, String>>[
    MapEntry('Dispatch No', d.dispatchNo),
    MapEntry('Date', d.date),
    if (d.who.trim().isNotEmpty) MapEntry('To', d.who),
    if (d.invoice.trim().isNotEmpty) MapEntry('Invoice No', d.invoice),
    if (d.vehicle.trim().isNotEmpty) MapEntry('Vehicle No', d.vehicle),
    if (d.transporter.trim().isNotEmpty) MapEntry('Transporter', d.transporter),
  ]) {
    if (e.value.trim().isEmpty) continue;
    line('${e.key}:  ${e.value}', body);
  }
  y += 8;

  // Line-item grid.
  final grid = PdfGrid();
  grid.columns.add(count: 5);
  grid.columns[0].width = 28; // #
  grid.columns[4].width = 55; // boxes
  final header = grid.headers.add(1)[0];
  header.cells[0].value = '#';
  header.cells[1].value = 'Design';
  header.cells[2].value = 'Size';
  header.cells[3].value = 'Surface / Quality';
  header.cells[4].value = 'Boxes';
  header.style = PdfGridRowStyle(
      font: PdfStandardFont(PdfFontFamily.helvetica, 10,
          style: PdfFontStyle.bold),
      backgroundBrush: PdfSolidBrush(PdfColor(230, 236, 243)));

  for (var i = 0; i < d.lines.length; i++) {
    final l = d.lines[i];
    final r = grid.rows.add();
    r.cells[0].value = '${i + 1}';
    r.cells[1].value = l.name;
    r.cells[2].value = l.size.replaceAll(' mm', '');
    r.cells[3].value =
        [l.quality, l.surface].where((x) => x.trim().isNotEmpty).join(' · ');
    r.cells[4].value = '${l.boxes}';
  }
  grid.style = PdfGridStyle(
      font: body,
      cellPadding: PdfPaddings(left: 4, right: 4, top: 3, bottom: 3));

  final res = grid.draw(
      page: page, bounds: Rect.fromLTWH(0, y, w, 0))!;
  y = res.bounds.bottom + 10;

  line('Total dispatched:  ${d.total} boxes', h2, gap: 4);
  if (d.balanceLine.trim().isNotEmpty) line(d.balanceLine, body);
  if (d.note.trim().isNotEmpty) {
    y += 6;
    line('Note: ${d.note}', body);
  }

  final bytes = await doc.save();
  doc.dispose();
  return bytes;
}
