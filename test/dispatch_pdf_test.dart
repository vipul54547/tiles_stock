import 'package:flutter_test/flutter_test.dart';
import 'package:tiles_stock/utils/dispatch_pdf.dart';

void main() {
  test('buildDispatchPdf produces a valid, non-empty PDF', () async {
    final bytes = await buildDispatchPdf(const DispatchPdfData(
      stockistName: 'livok ceramic',
      who: 'new sati ceramica',
      dispatchNo: 'DSP-000043',
      date: '12 Jul 2026',
      invoice: '125',
      vehicle: 'GJ-01-AB-1234',
      transporter: '',
      note: 'handle with care',
      lines: [
        DispatchPdfLine(
            name: '3209',
            size: '300x450 mm',
            surface: 'Carv (Carving)',
            quality: 'Premium',
            boxes: 97),
        DispatchPdfLine(
            name: '3202',
            size: '300x450 mm',
            surface: 'Matt',
            quality: 'Premium',
            boxes: 85),
      ],
      total: 182,
      balanceLine: '',
    ));

    expect(bytes, isNotEmpty);
    // Every PDF file begins with the "%PDF" magic bytes.
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
  });

  test('handles an empty line list and missing meta without throwing', () async {
    final bytes = await buildDispatchPdf(const DispatchPdfData(
      stockistName: '',
      who: '',
      dispatchNo: 'DSP-1',
      date: '12 Jul 2026',
      invoice: '',
      vehicle: '',
      transporter: '',
      note: '',
      lines: [],
      total: 0,
      balanceLine: '',
    ));
    expect(bytes, isNotEmpty);
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
  });
}
