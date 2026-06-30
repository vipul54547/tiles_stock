import 'package:syncfusion_flutter_xlsio/xlsio.dart';
import '../models/dna.dart';
import '../models/brand.dart';

/// Builds the downloadable stock-import .xlsx template. The visible "Stock" sheet
/// has the correct headers in the right shape; a second "Lists" sheet holds every
/// allowed value, and each constrained column gets a real Excel dropdown sourced
/// from that sheet (so the stockist picks instead of typing — no mismatches the
/// importer would have to reconcile). Two skins:
///   • multiBrand (M) → Master Design + one column per brand + WIDE Premium /
///     Standard quantity columns.
///   • single brand (T/W) → Design Name + Quality + Box Qty.
/// The header wording matches the importer's column synonyms, so a filled
/// template imports with no Map steps.
class ExcelTemplateService {
  static List<int> buildStockTemplate({
    required bool multiBrand,
    required List<String> sizes,
    required List<String> finishes,
    required List<String> tileTypes,
    required List<DnaAttribute> dnaAttrs,
    required List<Brand> brands,
    int dataRows = 200,
  }) {
    final wb = Workbook();
    try {
      final stock = wb.worksheets[0];
      stock.name = 'Stock';
      final lists = wb.worksheets.addWithName('Lists');

      // DNA columns we can offer a dropdown for (free-text / value-less skipped).
      final dnaUsable =
          dnaAttrs.where((a) => !a.isFreeText && a.values.isNotEmpty).toList();

      // ── Lists sheet: one vocabulary per column; remember each column's range ──
      final listCols = <String, List<String>>{
        'Size': sizes,
        'Quality': const ['Premium', 'Standard'],
        'Surface': finishes,
        'Tile Type': tileTypes,
        for (final a in dnaUsable) a.name: a.values.map((v) => v.name).toList(),
      };
      final localRange = <String, String>{}; // header -> 'A2:A12' on the Lists sheet
      var lc = 1;
      listCols.forEach((header, values) {
        lists.getRangeByIndex(1, lc).setText(header);
        for (var i = 0; i < values.length; i++) {
          lists.getRangeByIndex(i + 2, lc).setText(values[i]);
        }
        final letter = _colLetter(lc);
        final last = values.isEmpty ? 2 : values.length + 1;
        localRange[header] = '${letter}2:$letter$last';
        lc++;
      });

      // ── Stock sheet headers (order = skin) ──
      // Columns are grouped left→right into blocks, colour-coded on the header so
      // the stockist sees at a glance what to re-enter vs what to set once:
      //   • DAILY (navy)  → identity + the value that changes every upload
      //     (quality / quantity). Fill on every row.
      //   • SET-ONCE (grey) → Surface, Tile Type, Pieces/Box, Weight, DNA. Only a
      //     NEW design needs these; for an existing design the importer reuses the
      //     stored value, so they can be left blank.
      //   • BRAND (purple, M only) → this design's name under each brand.
      const dailyColor = '#1B4F72';
      const onceColor = '#6C7A89';
      const brandColor = '#6A1B9A';

      final headers = <String>[];
      // Each entry maps its column to the Lists header it should validate against
      // (null = free text / number, no dropdown), plus its header colour.
      final validateWith = <String?>[];
      final headerColor = <String>[];
      void col(String h, String? listHeader, String color) {
        headers.add(h);
        validateWith.add(listHeader);
        headerColor.add(color);
      }

      if (multiBrand) {
        col('Master Design', null, dailyColor);
        for (final b in brands) {
          col(b.name, null, brandColor);
        }
        col('Size', 'Size', dailyColor);
        col('Premium', null, dailyColor);
        col('Standard', null, dailyColor);
        col('Surface', 'Surface', onceColor);
        col('Tile Type', 'Tile Type', onceColor);
        col('Pieces/Box', null, onceColor);
        col('Weight (kg)', null, onceColor);
      } else {
        col('Design Name', null, dailyColor);
        col('Size', 'Size', dailyColor);
        col('Quality', 'Quality', dailyColor);
        col('Box Qty', null, dailyColor);
        col('Surface', 'Surface', onceColor);
        col('Tile Type', 'Tile Type', onceColor);
        col('Pieces/Box', null, onceColor);
        col('Weight (kg)', null, onceColor);
      }
      for (final a in dnaUsable) {
        col(a.name, a.name, onceColor);
      }

      for (var i = 0; i < headers.length; i++) {
        final cell = stock.getRangeByIndex(1, i + 1);
        cell.setText(headers[i]);
        cell.cellStyle
          ..bold = true
          ..fontColor = '#FFFFFF'
          ..backColor = headerColor[i]
          ..hAlign = HAlignType.center;
      }

      // ── Dropdowns: each validated column over the data rows, sourced from Lists ──
      final lastRow = dataRows + 1; // row 1 is the header
      for (var i = 0; i < validateWith.length; i++) {
        final listHeader = validateWith[i];
        if (listHeader == null) continue;
        final letter = _colLetter(i + 1);
        final target = stock.getRangeByName('${letter}2:$letter$lastRow');
        target.dataValidation
          ..allowType = ExcelDataValidationType.user
          ..dataRange = lists.getRangeByName(localRange[listHeader]!)
          ..errorBoxText = 'Pick a value from the list.'
          ..showErrorBox = true;
      }

      // Auto-fit visible columns for readability.
      for (var i = 1; i <= headers.length; i++) {
        stock.autoFitColumn(i);
      }
      // Keep the header visible while scrolling the data rows.
      stock.getRangeByName('A2').freezePanes();

      // Colour legend on the (helper) Lists sheet so the header colours are
      // self-explanatory. lc is the next free column after the vocab columns;
      // leave a one-column gap so it doesn't touch a validation range.
      final legendCol = lc + 1;
      lists.getRangeByIndex(1, legendCol).setText('Colour guide');
      lists.getRangeByIndex(1, legendCol).cellStyle.bold = true;
      lists
          .getRangeByIndex(2, legendCol)
          .setText('Navy = fill every time (identity + quantity)');
      lists
          .getRangeByIndex(3, legendCol)
          .setText('Grey = fill ONCE for a new design, then leave blank');
      if (multiBrand) {
        lists
            .getRangeByIndex(4, legendCol)
            .setText("Purple = this design's name under each brand");
      }
      lists.autoFitColumn(legendCol);

      return wb.saveAsStream();
    } finally {
      wb.dispose();
    }
  }

  /// M stockist multi-brand Option 3: Master Design + Brand value col + Design Name col.
  static List<int> buildMOption3Template({
    required List<String> sizes,
    required List<String> finishes,
    required List<String> tileTypes,
    required List<Brand> brands,
    int dataRows = 200,
  }) {
    final wb = Workbook();
    try {
      final stock = wb.worksheets[0];
      stock.name = 'Stock';
      final lists = wb.worksheets.addWithName('Lists');

      final brandNames = brands.map((b) => b.name).toList();
      final listCols = <String, List<String>>{
        'Brand':    brandNames,
        'Size':     sizes,
        'Surface':  finishes,
        'Tile Type': tileTypes,
      };
      final localRange = <String, String>{};
      var lc = 1;
      listCols.forEach((header, values) {
        lists.getRangeByIndex(1, lc).setText(header);
        for (var i = 0; i < values.length; i++) {
          lists.getRangeByIndex(i + 2, lc).setText(values[i]);
        }
        final letter = _colLetter(lc);
        final last = values.isEmpty ? 2 : values.length + 1;
        localRange[header] = '${letter}2:$letter$last';
        lc++;
      });

      const masterColor = '#1B4F72';
      const brandColor  = '#6A1B9A';
      const dailyColor  = '#1B4F72';
      const onceColor   = '#6C7A89';

      final headers      = <String>[];
      final validateWith = <String?>[];
      final headerColor  = <String>[];
      void col(String h, String? listH, String color) {
        headers.add(h); validateWith.add(listH); headerColor.add(color);
      }

      col('Master Design', null,       masterColor);
      col('Brand',         'Brand',    brandColor);
      col('Design Name',   null,       brandColor);
      col('Size',          'Size',     dailyColor);
      col('Premium',       null,       dailyColor);
      col('Standard',      null,       dailyColor);
      col('Surface',       'Surface',  onceColor);
      col('Tile Type',     'Tile Type',onceColor);
      col('Pieces/Box',    null,       onceColor);
      col('Weight (kg)',   null,       onceColor);

      for (var i = 0; i < headers.length; i++) {
        final cell = stock.getRangeByIndex(1, i + 1);
        cell.setText(headers[i]);
        cell.cellStyle
          ..bold = true
          ..fontColor = '#FFFFFF'
          ..backColor = headerColor[i]
          ..hAlign = HAlignType.center;
      }

      final lastRow = dataRows + 1;
      for (var i = 0; i < validateWith.length; i++) {
        final lh = validateWith[i];
        if (lh == null) continue;
        final letter = _colLetter(i + 1);
        final target = stock.getRangeByName('${letter}2:$letter$lastRow');
        target.dataValidation
          ..allowType = ExcelDataValidationType.user
          ..dataRange = lists.getRangeByName(localRange[lh]!)
          ..errorBoxText = 'Pick a value from the list.'
          ..showErrorBox = true;
      }

      for (var i = 1; i <= headers.length; i++) { stock.autoFitColumn(i); }
      stock.getRangeByName('A2').freezePanes();

      final legendCol = lc + 1;
      lists.getRangeByIndex(1, legendCol).setText('Colour guide');
      lists.getRangeByIndex(1, legendCol).cellStyle.bold = true;
      lists.getRangeByIndex(2, legendCol)
          .setText('Navy = Master Design (brand-agnostic library key)');
      lists.getRangeByIndex(3, legendCol)
          .setText('Purple = Brand (pick from dropdown) + Design Name under that brand');
      lists.getRangeByIndex(4, legendCol)
          .setText('Grey = fill once for a new design, then leave blank');
      lists.autoFitColumn(legendCol);

      return wb.saveAsStream();
    } finally {
      wb.dispose();
    }
  }

  /// T/W multi-brand Option 2 template: all brand columns, fill only one per row.
  /// No Master Design column (T/W design name IS the master).
  static List<int> buildTWOption2Template({
    required List<String> sizes,
    required List<String> finishes,
    required List<String> tileTypes,
    required List<Brand> brands,
    int dataRows = 200,
  }) {
    final wb = Workbook();
    try {
      final stock = wb.worksheets[0];
      stock.name = 'Stock';
      final lists = wb.worksheets.addWithName('Lists');

      final listCols = <String, List<String>>{
        'Size': sizes,
        'Quality': const ['Premium', 'Standard'],
        'Surface': finishes,
        'Tile Type': tileTypes,
      };
      final localRange = <String, String>{};
      var lc = 1;
      listCols.forEach((header, values) {
        lists.getRangeByIndex(1, lc).setText(header);
        for (var i = 0; i < values.length; i++) {
          lists.getRangeByIndex(i + 2, lc).setText(values[i]);
        }
        final letter = _colLetter(lc);
        final last = values.isEmpty ? 2 : values.length + 1;
        localRange[header] = '${letter}2:$letter$last';
        lc++;
      });

      const brandColor  = '#6A1B9A';
      const dailyColor  = '#1B4F72';
      const onceColor   = '#6C7A89';

      final headers      = <String>[];
      final validateWith = <String?>[];
      final headerColor  = <String>[];
      void col(String h, String? listH, String color) {
        headers.add(h); validateWith.add(listH); headerColor.add(color);
      }

      // All brand cols first (fill only one per row), then stock identity
      for (final b in brands) { col(b.name, null, brandColor); }
      col('Size',     'Size',    dailyColor);
      col('Quality',  'Quality', dailyColor);
      col('Box Qty',  null,      dailyColor);
      col('Surface',  'Surface', onceColor);
      col('Tile Type','Tile Type',onceColor);
      col('Pieces/Box',null,     onceColor);
      col('Weight (kg)',null,    onceColor);

      for (var i = 0; i < headers.length; i++) {
        final cell = stock.getRangeByIndex(1, i + 1);
        cell.setText(headers[i]);
        cell.cellStyle
          ..bold = true
          ..fontColor = '#FFFFFF'
          ..backColor = headerColor[i]
          ..hAlign = HAlignType.center;
      }

      final lastRow = dataRows + 1;
      for (var i = 0; i < validateWith.length; i++) {
        final lh = validateWith[i];
        if (lh == null) continue;
        final letter = _colLetter(i + 1);
        final target = stock.getRangeByName('${letter}2:$letter$lastRow');
        target.dataValidation
          ..allowType = ExcelDataValidationType.user
          ..dataRange = lists.getRangeByName(localRange[lh]!)
          ..errorBoxText = 'Pick a value from the list.'
          ..showErrorBox = true;
      }

      for (var i = 1; i <= headers.length; i++) { stock.autoFitColumn(i); }
      stock.getRangeByName('A2').freezePanes();

      final legendCol = lc + 1;
      lists.getRangeByIndex(1, legendCol).setText('Colour guide');
      lists.getRangeByIndex(1, legendCol).cellStyle.bold = true;
      lists.getRangeByIndex(2, legendCol)
          .setText('Purple = fill THIS column for the brand supplying this stock (one per row)');
      lists.getRangeByIndex(3, legendCol)
          .setText('Navy = fill every time (identity + quantity)');
      lists.getRangeByIndex(4, legendCol)
          .setText('Grey = fill once for a new design, then leave blank');
      lists.autoFitColumn(legendCol);

      return wb.saveAsStream();
    } finally {
      wb.dispose();
    }
  }

  /// T/W multi-brand Option 3 template: Brand value column + Design Name column.
  static List<int> buildTWOption3Template({
    required List<String> sizes,
    required List<String> finishes,
    required List<String> tileTypes,
    required List<Brand> brands,
    int dataRows = 200,
  }) {
    final wb = Workbook();
    try {
      final stock = wb.worksheets[0];
      stock.name = 'Stock';
      final lists = wb.worksheets.addWithName('Lists');

      final brandNames = brands.map((b) => b.name).toList();
      final listCols = <String, List<String>>{
        'Brand':   brandNames,
        'Size':    sizes,
        'Quality': const ['Premium', 'Standard'],
        'Surface': finishes,
        'Tile Type': tileTypes,
      };
      final localRange = <String, String>{};
      var lc = 1;
      listCols.forEach((header, values) {
        lists.getRangeByIndex(1, lc).setText(header);
        for (var i = 0; i < values.length; i++) {
          lists.getRangeByIndex(i + 2, lc).setText(values[i]);
        }
        final letter = _colLetter(lc);
        final last = values.isEmpty ? 2 : values.length + 1;
        localRange[header] = '${letter}2:$letter$last';
        lc++;
      });

      const brandColor = '#6A1B9A';
      const dailyColor = '#1B4F72';
      const onceColor  = '#6C7A89';

      final headers      = <String>[];
      final validateWith = <String?>[];
      final headerColor  = <String>[];
      void col(String h, String? listH, String color) {
        headers.add(h); validateWith.add(listH); headerColor.add(color);
      }

      col('Brand',      'Brand',    brandColor);
      col('Design Name', null,      dailyColor);
      col('Size',       'Size',     dailyColor);
      col('Quality',    'Quality',  dailyColor);
      col('Box Qty',    null,       dailyColor);
      col('Surface',    'Surface',  onceColor);
      col('Tile Type',  'Tile Type',onceColor);
      col('Pieces/Box', null,       onceColor);
      col('Weight (kg)',null,       onceColor);

      for (var i = 0; i < headers.length; i++) {
        final cell = stock.getRangeByIndex(1, i + 1);
        cell.setText(headers[i]);
        cell.cellStyle
          ..bold = true
          ..fontColor = '#FFFFFF'
          ..backColor = headerColor[i]
          ..hAlign = HAlignType.center;
      }

      final lastRow = dataRows + 1;
      for (var i = 0; i < validateWith.length; i++) {
        final lh = validateWith[i];
        if (lh == null) continue;
        final letter = _colLetter(i + 1);
        final target = stock.getRangeByName('${letter}2:$letter$lastRow');
        target.dataValidation
          ..allowType = ExcelDataValidationType.user
          ..dataRange = lists.getRangeByName(localRange[lh]!)
          ..errorBoxText = 'Pick a value from the list.'
          ..showErrorBox = true;
      }

      for (var i = 1; i <= headers.length; i++) { stock.autoFitColumn(i); }
      stock.getRangeByName('A2').freezePanes();

      final legendCol = lc + 1;
      lists.getRangeByIndex(1, legendCol).setText('Colour guide');
      lists.getRangeByIndex(1, legendCol).cellStyle.bold = true;
      lists.getRangeByIndex(2, legendCol)
          .setText('Purple = Brand (pick from dropdown) + Design Name for that brand');
      lists.getRangeByIndex(3, legendCol)
          .setText('Navy = fill every time');
      lists.getRangeByIndex(4, legendCol)
          .setText('Grey = fill once for a new design, then leave blank');
      lists.autoFitColumn(legendCol);

      return wb.saveAsStream();
    } finally {
      wb.dispose();
    }
  }

  // 1 -> A, 26 -> Z, 27 -> AA …
  static String _colLetter(int col) {
    var c = col;
    final units = <int>[];
    while (c > 0) {
      final r = (c - 1) % 26;
      units.add(65 + r);
      c = (c - 1) ~/ 26;
    }
    return String.fromCharCodes(units.reversed);
  }
}
