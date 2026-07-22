import 'dart:ui' show Rect;
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// One line on a dispatch note. Brand · batch · location are the loading-list
/// facts a supervisor pulls stock by; empty when not tracked. (LOT layer L3)
class DispatchPdfLine {
  final String name;
  final String size;
  final String surface; // "Word (Canonical)" or ''
  final String quality;
  final int boxes;
  final String brand;
  final String batch;
  final String location;
  const DispatchPdfLine({
    required this.name,
    required this.size,
    required this.surface,
    required this.quality,
    required this.boxes,
    this.brand = '',
    this.batch = '',
    this.location = '',
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
  final String vehicle; // truck / vehicle number
  final String transporter;
  final String note;
  final List<DispatchPdfLine> lines;
  final int total;
  final String balanceLine; // outstanding/closed note, '' when none
  final String title; // 'DISPATCH NOTE' or 'LOADING LIST'
  final String totalLabel; // 'Total dispatched' or 'Total to load'
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
    this.title = 'DISPATCH NOTE',
    this.totalLabel = 'Total dispatched',
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

  line(d.title, titleFont, gap: 4);
  if (d.stockistName.trim().isNotEmpty) line(d.stockistName, h2, gap: 6);

  // Meta block — only the fields that are filled.
  for (final e in <MapEntry<String, String>>[
    MapEntry('Dispatch No', d.dispatchNo),
    MapEntry('Date', d.date),
    if (d.who.trim().isNotEmpty) MapEntry('To', d.who),
    if (d.invoice.trim().isNotEmpty) MapEntry('Invoice No', d.invoice),
    if (d.vehicle.trim().isNotEmpty) MapEntry('Truck No', d.vehicle),
    if (d.transporter.trim().isNotEmpty) MapEntry('Transporter', d.transporter),
  ]) {
    if (e.value.trim().isEmpty) continue;
    line('${e.key}:  ${e.value}', body);
  }
  y += 8;

  // Line-item grid. Brand and Batch · Location columns appear only when the
  // stockist tracks them — the loading list a supervisor pulls stock by.
  final showBrand = d.lines.any((l) => l.brand.trim().isNotEmpty);
  final showBatch = d.lines
      .any((l) => l.batch.trim().isNotEmpty || l.location.trim().isNotEmpty);

  String qsOf(DispatchPdfLine l) =>
      [l.quality, l.surface].where((x) => x.trim().isNotEmpty).join(' · ');
  String blOf(DispatchPdfLine l) => [
        if (l.batch.trim().isNotEmpty) 'Batch ${l.batch}',
        if (l.location.trim().isNotEmpty) l.location,
      ].join(' · ');

  final headers = <String>[
    '#',
    if (showBrand) 'Brand',
    'Design',
    'Size',
    'Surface / Quality',
    if (showBatch) 'Batch · Location',
    'Boxes',
  ];

  final grid = PdfGrid();
  grid.columns.add(count: headers.length);
  grid.columns[0].width = 24; // #
  grid.columns[headers.length - 1].width = 45; // boxes
  final header = grid.headers.add(1)[0];
  for (var c = 0; c < headers.length; c++) {
    header.cells[c].value = headers[c];
  }
  header.style = PdfGridRowStyle(
      font: PdfStandardFont(PdfFontFamily.helvetica, 10,
          style: PdfFontStyle.bold),
      backgroundBrush: PdfSolidBrush(PdfColor(230, 236, 243)));

  for (var i = 0; i < d.lines.length; i++) {
    final l = d.lines[i];
    final vals = <String>[
      '${i + 1}',
      if (showBrand) l.brand,
      l.name,
      l.size.replaceAll(' mm', ''),
      qsOf(l),
      if (showBatch) blOf(l),
      '${l.boxes}',
    ];
    final r = grid.rows.add();
    for (var c = 0; c < vals.length; c++) {
      r.cells[c].value = vals[c];
    }
  }
  grid.style = PdfGridStyle(
      font: body,
      cellPadding: PdfPaddings(left: 4, right: 4, top: 3, bottom: 3));

  final res = grid.draw(
      page: page, bounds: Rect.fromLTWH(0, y, w, 0))!;
  y = res.bounds.bottom + 10;

  line('${d.totalLabel}:  ${d.total} boxes', h2, gap: 4);
  if (d.balanceLine.trim().isNotEmpty) line(d.balanceLine, body);
  if (d.note.trim().isNotEmpty) {
    y += 6;
    line('Note: ${d.note}', body);
  }

  final bytes = await doc.save();
  doc.dispose();
  return bytes;
}
