import 'dart:io';
import 'dart:convert' show latin1; // byte→marker scanning of PDF image dicts
import 'dart:ui' show Offset; // page-template placement during per-page split
import 'package:flutter/foundation.dart'; // compute() + Uint8List
import 'package:image/image.dart' as img;
import 'package:syncfusion_flutter_pdf/pdf.dart';

// ── Data classes ──────────────────────────────────────────────────────────────

class PdfImportResult {
  final String size;
  final String quality;
  final List<PdfDesignRow> designs;
  final int imageCount;   // how many images were extracted from the PDF
  final int rawLineCount; // total non-empty lines in extracted text (debug)
  final int digitLines;   // lines that started with a digit (debug)

  PdfImportResult({
    required this.size,
    required this.quality,
    required this.designs,
    this.imageCount = 0,
    this.rawLineCount = 0,
    this.digitLines = 0,
  });
}

class PdfDesignRow {
  final String name;
  final int quantity;
  String surface;
  /// Original finish text from the PDF when it isn't a standard finish
  /// (e.g. "Punch Ghr", "Lustra"). Null for standard finishes.
  final String? finishLabel;
  /// Raw JPEG bytes extracted from the PDF for this design.
  /// Null if the PDF had no matching image or image count didn't align.
  final Uint8List? imageBytes;

  bool isNew;
  int currentQuantity;
  int newTotalQuantity;
  String? designId;
  String? selectedDesignId;
  bool createNew;

  PdfDesignRow({
    required this.name,
    required this.quantity,
    required this.surface,
    this.finishLabel,
    this.imageBytes,
    this.isNew = true,
    this.currentQuantity = 0,
    this.newTotalQuantity = 0,
    this.designId,
    this.selectedDesignId,
    this.createNew = true,
  });
}

// ── Background isolate entry point ────────────────────────────────────────────
//
// Must be a top-level function (not a class method) to work with compute().
// Receives the raw PDF bytes + filename.
// Returns a plain Map (isolate-safe: primitives + Uint8List lists).
//
// Performs three tasks in one background pass so the UI never freezes:
//   1. Parse filename → size + quality
//   2. Extract text  → design names, quantities, surface types
//   3. Extract JPEGs → raw image bytes for each tile design
//
Future<Map<String, dynamic>> _parsePdfTask(Map<String, dynamic> args) async {
  final Uint8List bytes    = args['bytes']    as Uint8List;
  final String    filename = args['filename'] as String;

  // ── 1. Filename → size + quality ──────────────────────────────────────────
  final baseName = filename
      .replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '')
      .trim();
  final parts   = baseName.split(RegExp(r'[\s_]+'));
  final sizeRaw = parts[0]
      .replaceAll(RegExp(r'[xX]'), 'x')
      .toLowerCase();
  final size  = '$sizeRaw mm';

  // Tile WxH (mm) drives image orientation correction below.
  int? tileW, tileH;
  final dimParts = sizeRaw.split('x');
  if (dimParts.length == 2) {
    tileW = int.tryParse(dimParts[0].replaceAll(RegExp(r'[^0-9]'), ''));
    tileH = int.tryParse(dimParts[1].replaceAll(RegExp(r'[^0-9]'), ''));
  }
  final code  = parts.length > 1 ? parts[1].toUpperCase() : 'STD';
  String quality;
  if (code == 'PRE' || code == 'PREMIUM') {
    quality = 'Premium';
  } else if (code == 'ECO' || code == 'ECONOMY') {
    quality = 'Economy';
  } else {
    quality = 'Standard';
  }

  // ── 2. PDF → design list (column-adaptive, position based) ────────────────
  // Parse by word geometry so the table is read by where each value sits and
  // what it contains — not by a fixed column order. Falls back to the legacy
  // flat-text parser only if positional extraction yields nothing.
  const int minImageBytes = 5 * 1024;

  List<Map<String, dynamic>> designMaps = [];
  int dbgTotalLines = 0;
  List<List<Uint8List?>>? imagesPerPage; // image slots per page (null = N/A)
  try {
    final doc = PdfDocument(inputBytes: bytes);
    final lines = PdfTextExtractor(doc).extractTextLines();
    dbgTotalLines = lines.length;
    designMaps = _parseDesignsAdaptive(lines); // each map carries its 'page'
    if (designMaps.isEmpty) {
      // Flat-text fallback has no page geometry; per-page matching is skipped.
      designMaps = _parseDesignsToMaps(PdfTextExtractor(doc).extractText());
    } else {
      imagesPerPage = await _extractImageSlotsPerPage(doc);
    }
    doc.dispose();
  } catch (e, st) {
    debugPrint('PDF parse failed: $e\n$st');
  }
  final dbgDigitLines = designMaps.length; // designs found (debug stat)

  // ── 3. Match tile photos to designs ───────────────────────────────────────
  //
  // Preferred path: every image XObject on a page becomes an ordered *slot* —
  // the raw JPEG bytes for DCTDecode photos, or null for photos we can't
  // byte-extract (PNG/FlateDecode). Keeping null placeholders preserves the
  // 1:1 order between images and design rows, so a non-JPEG photo no longer
  // shifts every photo beneath it, and matching stays scoped per page so one
  // page's miscount can't cascade onto the next. Falls back to a whole-document
  // JPEG scan when per-page extraction is unavailable (flat-text parser ran).
  //
  List<Uint8List?> imagesByDesign;
  int imageCount;
  final perPageUsable = imagesPerPage != null &&
      designMaps.every((m) => (m['page'] as int? ?? -1) >= 0);

  if (perPageUsable) {
    imageCount =
        imagesPerPage.fold(0, (a, b) => a + b.where((x) => x != null).length);
    imagesByDesign = _matchImagesPerPage(designMaps, imagesPerPage);
  } else {
    final images = _extractJpegsFromBytes(bytes, minSizeBytes: minImageBytes);
    imageCount = images.length;
    imagesByDesign = _matchImagesGlobally(images, designMaps.length);
  }

  // Rotate any photo whose orientation disagrees with the tile's real shape
  // (derived from the filename size, e.g. 600x1200 → portrait).
  final orientedImages = _orientImages(imagesByDesign, tileW, tileH);

  return {
    'size':           size,
    'quality':        quality,
    'designs':        designMaps,
    'images':         orientedImages,
    'imageCount':     imageCount,
    'dbgTotalLines':  dbgTotalLines,
    'dbgDigitLines':  dbgDigitLines,
  };
}

// ── Image → design matching ─────────────────────────────────────────────────
//
// Alignment rule (shared by both paths): when there are more image slots than
// designs the extras drop from the front (page/section logos appear first);
// when there are fewer, the trailing designs pad with null. Per-page slots
// already carry null placeholders for non-JPEG photos, so equal counts map 1:1.

// Whole-document fallback: one ordered photo list against the full design list.
List<Uint8List?> _matchImagesGlobally(List<Uint8List> images, int designCount) {
  if (images.length != designCount) {
    debugPrint('PDF image/design count mismatch: '
        '${images.length} images vs $designCount designs — '
        'photos may be misaligned.');
  }
  if (images.length == designCount) {
    return List<Uint8List?>.from(images);
  } else if (images.length > designCount) {
    return List<Uint8List?>.from(images.sublist(images.length - designCount));
  }
  final out = List<Uint8List?>.filled(designCount, null);
  for (var i = 0; i < images.length; i++) {
    out[i] = images[i];
  }
  return out;
}

// Per-page: align each page's photos to that page's designs in isolation, so a
// miscount on one page cannot cascade onto the pages that follow it.
List<Uint8List?> _matchImagesPerPage(
  List<Map<String, dynamic>> designMaps,
  List<List<Uint8List?>> imagesPerPage,
) {
  final out = List<Uint8List?>.filled(designMaps.length, null);

  // Bucket design indices by their page, preserving document order.
  final idxByPage = <int, List<int>>{};
  for (var i = 0; i < designMaps.length; i++) {
    final p = designMaps[i]['page'] as int;
    (idxByPage[p] ??= <int>[]).add(i);
  }

  idxByPage.forEach((page, idxs) {
    final imgs = (page >= 0 && page < imagesPerPage.length)
        ? imagesPerPage[page]
        : const <Uint8List?>[];
    if (imgs.length != idxs.length) {
      debugPrint('PDF page ${page + 1}: ${imgs.length} images vs '
          '${idxs.length} designs — matched within page.');
    }

    List<Uint8List?> aligned;
    if (imgs.length == idxs.length) {
      aligned = List<Uint8List?>.from(imgs);
    } else if (imgs.length > idxs.length) {
      aligned = List<Uint8List?>.from(imgs.sublist(imgs.length - idxs.length));
    } else {
      aligned = List<Uint8List?>.filled(idxs.length, null);
      for (var k = 0; k < imgs.length; k++) {
        aligned[k] = imgs[k];
      }
    }
    for (var k = 0; k < idxs.length; k++) {
      out[idxs[k]] = aligned[k];
    }
  });

  return out;
}

// Split each page into its own single-page PDF and read that page's image
// XObjects in order. createTemplate()/drawPdfTemplate() copy the page's images
// by reference, so DCTDecode JPEG streams survive the round trip intact while
// the leading image dictionaries stay as plaintext (PDF stream objects are
// never packed into compressed object streams). Returns one ordered slot per
// image: JPEG bytes for DCTDecode photos, null for everything else.
Future<List<List<Uint8List?>>> _extractImageSlotsPerPage(PdfDocument doc) async {
  final perPage = <List<Uint8List?>>[];
  final pageCount = doc.pages.count;
  for (var i = 0; i < pageCount; i++) {
    final single = PdfDocument();
    try {
      final src = doc.pages[i];
      single.pageSettings.margins.all = 0;
      single.pageSettings.size = src.size;
      single.pages.add().graphics.drawPdfTemplate(
            src.createTemplate(),
            const Offset(0, 0),
          );
      final pageBytes = Uint8List.fromList(await single.save());
      perPage.add(_extractImageSlotsFromBytes(pageBytes));
    } finally {
      single.dispose();
    }
  }
  return perPage;
}

// Walk a single-page PDF's bytes, finding every image XObject in file order
// (which follows top-to-bottom draw order in these reports). For each image we
// read its /Filter from the leading dictionary: DCTDecode photos yield their
// raw JPEG bytes (located by the SOI marker right after the dict); any other
// encoding (PNG/FlateDecode etc.) yields a null slot, holding the design row's
// place so the JPEGs around it stay aligned.
List<Uint8List?> _extractImageSlotsFromBytes(Uint8List bytes) {
  final slots = <Uint8List?>[];
  // 1 char == 1 byte under latin1, so string indices map straight onto bytes.
  final text = latin1.decode(bytes, allowInvalid: true);
  final imageRe = RegExp(r'/Subtype\s*/Image');

  for (final m in imageRe.allMatches(text)) {
    final dictStart = m.start;
    final streamKw = text.indexOf('stream', dictStart);
    final dictEnd =
        streamKw < 0 ? (dictStart + 800).clamp(0, text.length) : streamKw;
    final dict = text.substring(dictStart, dictEnd);

    if (!dict.contains('DCTDecode')) {
      slots.add(null); // non-JPEG photo — keep the slot, no bytes to extract
      continue;
    }

    // The JPEG body is the first SOI marker after this image's dictionary.
    final searchFrom = streamKw < 0 ? dictStart : streamKw;
    int soi = -1;
    for (var i = searchFrom; i < bytes.length - 2; i++) {
      if (bytes[i] == 0xFF && bytes[i + 1] == 0xD8 && bytes[i + 2] == 0xFF) {
        soi = i;
        break;
      }
    }
    if (soi < 0) {
      slots.add(null);
      continue;
    }
    final end = _findJpegEnd(bytes, soi);
    slots.add(end > soi ? bytes.sublist(soi, end) : null);
  }

  return slots;
}

// ── Orientation correction ─────────────────────────────────────────────────────
//
// PDFs sometimes store a tile photo rotated 90° from its real-world shape.
// The filename carries the tile's true size (e.g. 600x1200 → portrait), so we
// compare each extracted photo's pixel aspect against the tile's expected
// aspect and rotate it back when they disagree.
//
// Square tiles (600x600) carry no orientation, and near-square photos are left
// untouched — there's nothing to correct and rotating would only risk harm.
//
List<Uint8List?> _orientImages(List<Uint8List?> images, int? tileW, int? tileH) {
  if (tileW == null || tileH == null || tileW <= 0 || tileH <= 0) return images;
  if ((tileW / tileH - 1).abs() < 0.05) return images; // square tile → no-op
  final tilePortrait = tileH > tileW;

  final out = List<Uint8List?>.from(images);
  for (var i = 0; i < out.length; i++) {
    final bytes = out[i];
    if (bytes == null) continue;
    final decoded = img.decodeJpg(bytes);
    if (decoded == null || decoded.width == 0 || decoded.height == 0) continue;
    if ((decoded.width / decoded.height - 1).abs() < 0.05) continue; // ~square photo
    final imgPortrait = decoded.height > decoded.width;
    if (imgPortrait == tilePortrait) continue; // already correct
    final rotated = img.copyRotate(decoded, angle: 90);
    out[i] = img.encodeJpg(rotated, quality: 90);
  }
  return out;
}

// ── JPEG extractor ────────────────────────────────────────────────────────────
//
// Scans raw bytes for JPEG Start-Of-Image (FF D8 FF) and reads each JPEG
// by following its segment structure to the End-Of-Image (FF D9).
// This is more reliable than a naive FF D9 scan because JPEG segment
// lengths tell us exactly how many bytes to skip per segment.
//
List<Uint8List> _extractJpegsFromBytes(
  Uint8List bytes, {
  int minSizeBytes = 0,
}) {
  final result = <Uint8List>[];
  int i = 0;

  while (i < bytes.length - 3) {
    // Look for SOI: FF D8 FF
    if (bytes[i] != 0xFF || bytes[i + 1] != 0xD8 || bytes[i + 2] != 0xFF) {
      i++;
      continue;
    }

    // Found a JPEG start — walk the segment structure to find EOI
    final end = _findJpegEnd(bytes, i);
    if (end > i) {
      final jpegBytes = bytes.sublist(i, end);
      if (jpegBytes.length >= minSizeBytes) {
        result.add(jpegBytes);
      }
      i = end;
    } else {
      i++;
    }
  }

  return result;
}

// Walk JPEG segments from [start] to find the EOI (FF D9) marker position.
// Returns the byte index AFTER the EOI, or -1 if not found.
int _findJpegEnd(Uint8List bytes, int start) {
  int i = start + 2; // skip SOI FF D8
  while (i < bytes.length - 1) {
    if (bytes[i] != 0xFF) {
      // Inside compressed image data (scan data) — scan for next marker
      i++;
      continue;
    }
    final marker = bytes[i + 1];

    if (marker == 0xD9) return i + 2; // EOI found
    if (marker == 0x00) { i += 2; continue; } // FF 00 stuffed byte
    if (marker >= 0xD0 && marker <= 0xD8) { i += 2; continue; } // RST/SOI

    // Segment with length: marker(2) + length(2) + data(length-2)
    if (i + 3 < bytes.length) {
      final length = (bytes[i + 2] << 8) | bytes[i + 3];
      if (length < 2) { i += 2; continue; }
      i += 2 + length;
    } else {
      break;
    }
  }
  return -1; // EOI not found
}

// ── Column-adaptive positional parser ─────────────────────────────────────────
//
// Tile stock reports vary between suppliers: the NAME / IMAGE / SIZE / SURFACE /
// QTY columns can appear in any order, design names wrap across two lines, and
// every page repeats a header row plus a date / "Page x of y" footer. A fixed
// column-order parser cannot cope with that, so we parse by geometry instead:
//
//   1. turn every word into a token carrying its (page, x, y) box
//   2. group tokens into visual rows by vertical proximity
//   3. learn the column layout from the header row (NAME / BOX / SURFACE / …),
//      and fall back to content sniffing when a PDF has no header
//   4. read each row's cells, classify columns by what they hold (bare ints →
//      quantity, surface words → surface, NNNxNNN → size, the rest → name),
//      merge wrapped name lines, and drop headers / footers / logo text.

class _Tok {
  final int page;
  final double x0, x1, yc, h;
  final String text;
  _Tok(this.page, this.x0, this.x1, this.yc, this.h, this.text);
  double get xc => (x0 + x1) / 2;
}

class _RowCells {
  final int page;
  final double yc;
  final List<_Tok> name;
  final int? qty;
  final String? surface;    // mapped finish, or null if absent/unmappable
  final String? surfaceRaw; // original finish text from the PDF cell
  final bool sectionSurface; // a row that is *only* a surface = section header
  _RowCells(this.page, this.yc, this.name, this.qty, this.surface,
      {this.surfaceRaw, this.sectionSurface = false});
}

// Maps a header-cell word to a logical column role (order-independent).
String? _headerRole(String word) {
  switch (word.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '')) {
    case 'NAME': case 'DESIGN': case 'DESIGNNAME': case 'PRODUCT':
    case 'ITEM': case 'ARTICLE': case 'PARTICULARS':
      return 'name';
    case 'IMAGE': case 'PHOTO': case 'PICTURE': case 'PIC': case 'IMG':
      return 'image';
    case 'BOX': case 'BOXES': case 'QTY': case 'QNTY': case 'QUANTITY':
    case 'PCS': case 'PIECES': case 'STOCK': case 'NOS':
      return 'qty';
    case 'SURFACE': case 'FINISH': case 'TEXTURE': case 'FACE':
      return 'surface';
    case 'SIZE': case 'DIMENSION': case 'DIMENSIONS':
      return 'size';
    default:
      return null;
  }
}

// Maps a free-text cell to a normalised surface name, or null if it isn't one.
String? _surfaceOf(String cell) {
  final u = cell.toUpperCase();
  if (u.contains('CARVIN'))                              return 'Carving';
  if (u.contains('LUSTRA') || u.contains('POLISH'))      return 'Polished';
  if (u.contains('LAPPAT'))                              return 'Lappato';
  if (u.contains('GLOSS'))                               return 'Glossy';
  if (u.contains('MATT'))                                return 'Matt';
  if (u.contains('SATIN'))                               return 'Satin';
  if (u.contains('SUGAR'))                               return 'Sugar';
  if (u.contains('PUNCH') || u.contains('GHR') || u.contains('RUSTIC')) return 'Rustic';
  return null;
}

final _intRe  = RegExp(r'^\d{1,4}$');
final _yearRe = RegExp(r'^(19|20)\d{2}$');
final _sizeRe = RegExp(r'^\d{2,4}[xX]\d{2,4}(mm)?$', caseSensitive: false);
final _dateRe = RegExp(
    r'\b\d{1,2}\s+(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)[A-Z]*\.?\s+\d{2,4}\b',
    caseSensitive: false);
final _pageRe = RegExp(r'\bpage\s+\d+(\s+of\s+\d+)?\b', caseSensitive: false);

bool _isQtyToken(String s) => _intRe.hasMatch(s) && !_yearRe.hasMatch(s);

bool _isJunkRow(String joined) {
  final u = joined.trim();
  if (u.isEmpty) return true;
  if (_dateRe.hasMatch(u)) return true;
  if (_pageRe.hasMatch(u)) return true;
  if (RegExp(r'^stock\s+report\b', caseSensitive: false).hasMatch(u)) return true;
  return false;
}

// Header words that leaked into a data column should never be kept as a name.
bool _isJunkNameToken(String s) => _headerRole(s) != null;

List<Map<String, dynamic>> _parseDesignsAdaptive(List<TextLine> lines) {
  // 1. Flatten to tokens with geometry.
  final toks = <_Tok>[];
  for (final line in lines) {
    for (final w in line.wordCollection) {
      final t = w.text.trim();
      if (t.isEmpty) continue;
      final b = w.bounds;
      toks.add(_Tok(line.pageIndex, b.left, b.right,
          b.top + b.height / 2, b.height, t));
    }
  }
  if (toks.length < 2) return [];

  // Row tolerance derived from median glyph height.
  final hs = toks.map((t) => t.h).where((h) => h > 0).toList()..sort();
  final medH = hs.isEmpty ? 10.0 : hs[hs.length ~/ 2];
  final rowTol = medH * 0.6;

  // 2. Group tokens into visual rows (per page, by Y).
  toks.sort((a, b) =>
      a.page != b.page ? a.page.compareTo(b.page) : a.yc.compareTo(b.yc));
  final rows = <List<_Tok>>[];
  for (final t in toks) {
    if (rows.isNotEmpty &&
        t.page == rows.last.first.page &&
        (t.yc - rows.last.first.yc).abs() <= rowTol) {
      rows.last.add(t);
    } else {
      rows.add([t]);
    }
  }
  for (final r in rows) {
    r.sort((a, b) => a.x0.compareTo(b.x0));
  }

  // 3. Learn columns from header rows (averaged across pages).
  final anchorAcc = <String, List<double>>{};
  final headerRows = <int>{};
  for (var i = 0; i < rows.length; i++) {
    final found = <String, double>{};
    for (final t in rows[i]) {
      final role = _headerRole(t.text);
      if (role != null) found[role] = t.xc;
    }
    if (found.length >= 2) {
      headerRows.add(i);
      found.forEach((role, x) => (anchorAcc[role] ??= []).add(x));
    }
  }
  final anchors = <String, double>{};
  anchorAcc.forEach((role, xs) =>
      anchors[role] = xs.reduce((a, b) => a + b) / xs.length);
  final ordered = anchors.entries.toList()
    ..sort((a, b) => a.value.compareTo(b.value));
  final hasHeader = anchors.containsKey('qty') && ordered.length >= 2;

  // Column role for an x-centre, using midpoints between header anchors.
  String roleForX(double x) {
    for (var i = 0; i < ordered.length; i++) {
      final lo = i == 0 ? -1e9 : (ordered[i - 1].value + ordered[i].value) / 2;
      final hi = i == ordered.length - 1
          ? 1e9
          : (ordered[i].value + ordered[i + 1].value) / 2;
      if (x >= lo && x < hi) return ordered[i].key;
    }
    return 'name';
  }

  // 4. Reduce each row to cells.
  final cells = <_RowCells>[];
  for (var i = 0; i < rows.length; i++) {
    if (headerRows.contains(i)) continue;
    final r = rows[i];
    if (_isJunkRow(r.map((t) => t.text).join(' '))) continue;

    final nameToks = <_Tok>[];
    final surfToks = <_Tok>[];
    int? qty;

    for (final t in r) {
      // Unambiguous content wins regardless of column.
      if (_sizeRe.hasMatch(t.text)) continue; // size — recorded elsewhere, not a name

      if (hasHeader) {
        switch (roleForX(t.xc)) {
          case 'qty':
            if (_isQtyToken(t.text)) qty ??= int.tryParse(t.text);
            continue;
          case 'surface':
            surfToks.add(t);
            continue;
          case 'image':
            // The image cell holds no text; keep only real words that overflow
            // a long name into it, drop stray marks.
            if (RegExp(r'[A-Za-z]').hasMatch(t.text) && !_isJunkNameToken(t.text)) {
              nameToks.add(t);
            }
            continue;
          case 'size':
            continue;
          default: // name
            if (!_isJunkNameToken(t.text)) nameToks.add(t);
            continue;
        }
      } else {
        // No header → sniff by content.
        if (_isQtyToken(t.text)) { qty ??= int.tryParse(t.text); continue; }
        if (t.text.length <= 14 && _surfaceOf(t.text) != null) {
          surfToks.add(t);
          continue;
        }
        if (!_isJunkNameToken(t.text)) nameToks.add(t);
      }
    }

    final surfaceRaw = surfToks.isEmpty
        ? null
        : surfToks.map((t) => t.text).join(' ').trim();
    final surface = surfaceRaw == null ? null : _surfaceOf(surfaceRaw);

    if (qty == null && nameToks.isEmpty) {
      if (surface != null) {
        // Surface-only row = a section header for the rows beneath it.
        cells.add(_RowCells(r.first.page, r.first.yc, const [], null, surface,
            surfaceRaw: surfaceRaw, sectionSurface: true));
      }
      continue;
    }
    cells.add(_RowCells(r.first.page, r.first.yc, nameToks, qty, surface,
        surfaceRaw: surfaceRaw));
  }

  // 5. Assign each name-only row to its nearest design (handles wrapped names).
  final designIdx = [for (var i = 0; i < cells.length; i++) if (cells[i].qty != null) i];
  final extraNames = {for (final i in designIdx) i: <_Tok>[]};
  for (final c in cells) {
    if (c.qty != null || c.sectionSurface || c.name.isEmpty) continue;
    int? best;
    double bestD = double.infinity;
    for (final i in designIdx) {
      final d = cells[i];
      if (d.page != c.page) continue;
      final dist = (d.yc - c.yc).abs();
      if (dist < bestD) { bestD = dist; best = i; }
    }
    if (best != null && bestD <= medH * 2.2) {
      extraNames[best]!.addAll(c.name);
    }
  }

  // 6. Emit designs in document order, inheriting the running section surface.
  final result = <Map<String, dynamic>>[];
  String runningSurface = 'Glossy';
  String? runningRaw;
  bool sectionSeen = false;
  for (var i = 0; i < cells.length; i++) {
    final c = cells[i];
    if (c.sectionSurface) {
      runningSurface = c.surface ?? runningSurface;
      runningRaw = c.surfaceRaw;
      sectionSeen = true;
      continue;
    }
    if (c.qty == null) continue;
    final parts = <_Tok>[...c.name, ...extraNames[i]!]
      ..sort((a, b) => a.yc != b.yc ? a.yc.compareTo(b.yc) : a.x0.compareTo(b.x0));
    final name = _cleanName(parts.map((t) => t.text).join(' '), allowNumeric: true);
    if (name.isEmpty) continue;

    // Resolve finish:
    //   • recognised finish on this row → its standard name (+ label if the raw
    //     wording differs, e.g. "Lustra" → Polished, "Punch Ghr" → Rustic)
    //   • unmappable finish word (e.g. "ENDLESS", a fragment of "ENDLESS GLOSSY")
    //     under a known section → inherit the section finish
    //   • unmappable finish with no section context → genuinely unknown ⇒ 'None'
    //   • no finish cell → inherit the running section finish
    final String surfaceType;
    String? finishLabel;
    final raw = c.surfaceRaw;
    if (raw != null && raw.isNotEmpty && c.surface != null) {
      surfaceType = c.surface!;
      finishLabel = _finishLabelFor(raw, c.surface!);
    } else if (raw != null && raw.isNotEmpty && !sectionSeen) {
      surfaceType = 'None';
      finishLabel = _titleCaseFinish(raw);
    } else {
      surfaceType = runningSurface;
      finishLabel =
          runningRaw == null ? null : _finishLabelFor(runningRaw, surfaceType);
    }

    result.add({
      'name': name,
      'quantity': c.qty!,
      'surface': surfaceType,
      'finishLabel': finishLabel,
      'page': c.page, // drives per-page image↔design matching
    });
  }

  debugPrint('Adaptive PDF parse: ${result.length} designs '
      '(header=$hasHeader, rows=${rows.length})');
  return result;
}

// Tidy a joined name: collapse spaces, strip a trailing surface word the layout
// merged in, reject pure-number / junk names. The leading "CR" on carving
// designs is part of the real name and is kept.
//
// [allowNumeric] keeps all-digit names (tile design codes like "9305"). The
// adaptive path sets this because the quantity already sits in its own column,
// so a number left in the name cell is a genuine code, not a leaked quantity.
String _cleanName(String raw, {bool allowNumeric = false}) {
  final s0 = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  final parts = s0.split(' ');
  while (parts.length > 1 && _surfaceOf(parts.last) != null) {
    parts.removeLast();
  }
  final s = parts.join(' ').trim();
  if (s.isEmpty) return '';
  if (!allowNumeric && RegExp(r'^\d+$').hasMatch(s)) return '';
  if (_isJunkNameToken(s)) return '';
  return s;
}

// Returns a display label for the PDF's raw finish text when it differs from
// the standard finish it mapped to (e.g. "PUNCH GHR" → Rustic ⇒ "Punch Ghr"),
// or null when the raw text is essentially the same word as the mapped finish
// (e.g. "CARVIN" → Carving, "GLOSSY" → Glossy).
String? _finishLabelFor(String raw, String mapped) {
  String norm(String s) => s.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
  final r = norm(raw);
  final m = norm(mapped);
  if (r.isEmpty) return null;
  if (r.contains(m) || m.contains(r)) return null;
  return _titleCaseFinish(raw);
}

String _titleCaseFinish(String s) => s
    .toLowerCase()
    .split(RegExp(r'\s+'))
    .where((w) => w.isNotEmpty)
    .map((w) => w[0].toUpperCase() + w.substring(1))
    .join(' ');

// ── PDF text parser ───────────────────────────────────────────────────────────
//
// The stock-report PDF has a 4-column table: NAME | IMAGE | BOX | SURFACE
// Text extraction interleaves columns — surface keywords can appear:
//   a) as standalone section-header lines (indented or not)
//   b) appended to the design name on the same extracted line
//
// Strategy:
//   1. Skip known junk lines (page headers, column headers)
//   2. Detect exact surface-keyword lines regardless of indentation
//   3. Digit-prefixed lines → quantity + name
//   4. After extracting the name, strip any trailing surface suffix
//      so "FORD CREMA ENDLESS GLOSSY" → name="FORD CREMA", surface="Glossy"
//
List<Map<String, dynamic>> _parseDesignsToMaps(String rawText) {
  final lines = rawText.split('\n').map((l) => l.replaceAll('\r', '')).toList();

  final result       = <Map<String, dynamic>>[];
  String surface     = 'Glossy';
  int?   pendingQty;
  String pendingName = '';
  bool   lastWasDesign = false;

  // Skip junk lines: column headers, page numbers, and date footers.
  // All alternatives use raw strings to avoid escape mistakes.
  final skipPattern = RegExp(
    r'^(?:'
    r'NAME\s+IMAGE\s+BOX\s+SURFACE|'           // column header row
    r'STOCK\s+REPORT|'                          // report title
    r'Page\s+\d+\s+of\s+\d+|'                  // "Page 2 of 11"
    r'[A-Za-z]+\s+\d{4}'                        // "May 2026" / "May 2026 Page 1 …"
    r')',
    caseSensitive: false,
  );
  final digitStart = RegExp(r'^(\d+)(.*)$');

  void flush() {
    if (pendingQty == null || pendingQty! <= 0) return;
    var cleaned = _cleanDesignName(pendingName);
    if (cleaned.isEmpty) return;
    // Strip surface suffix the PDF text-extractor may have merged into the name
    final (finalName, detectedSurface) = _stripSurfaceSuffix(cleaned);
    if (finalName.isEmpty) return;
    result.add({
      'name':     finalName,
      'quantity': pendingQty!,
      'surface':  detectedSurface ?? surface,
    });
    pendingQty  = null;
    pendingName = '';
  }

  for (final line in lines) {
    final trimR = line.trimRight();
    if (trimR.isEmpty) continue;
    final trimmed = trimR.trim();
    if (trimmed.isEmpty) continue;
    if (skipPattern.hasMatch(trimmed)) continue;

    // Detect pure surface-keyword lines (works even if Syncfusion strips indent)
    final pureSurface = _detectPureSurface(trimmed);
    if (pureSurface != null) {
      flush();
      surface       = pureSurface;
      lastWasDesign = false;
      continue;
    }

    final m = digitStart.firstMatch(trimmed);
    if (m != null) {
      flush();
      pendingQty    = int.tryParse(m.group(1)!) ?? 0;
      pendingName   = m.group(2)!.trim();
      lastWasDesign = true;
      continue;
    }

    if (lastWasDesign) {
      // Could be a name continuation or a surface that wasn't an exact keyword
      // Only append if it doesn't look like a section header
      if (!_mapSurfaceKnown(trimmed)) {
        pendingName = pendingName.isEmpty ? trimmed : '$pendingName $trimmed';
      } else {
        flush();
        surface       = _mapSurface(trimmed);
        lastWasDesign = false;
      }
    } else {
      // Section header line — update current surface
      surface       = _mapSurface(trimmed);
      lastWasDesign = false;
    }
  }
  flush();
  return result;
}

// Returns the surface type if [text] is EXACTLY a surface keyword, else null.
String? _detectPureSurface(String text) {
  switch (text.toUpperCase().trim()) {
    case 'CARVIN':         return 'Carving';
    case 'SATIN':          return 'Satin';
    case 'GLOSSY':         return 'Glossy';
    case 'MATT':           return 'Matt';
    case 'LUSTRA':         return 'Polished';
    case 'ENDLESS GLOSSY': return 'Glossy';
    case 'PUNCH GHR':      return 'Rustic';
    case 'GHR':            return 'Rustic';
    default:               return null;
  }
}

// True if [text] contains a recognisable surface keyword (for section headers).
bool _mapSurfaceKnown(String text) {
  final u = text.toUpperCase();
  return u.contains('GLOSSY') || u.contains('MATT') || u.contains('LUSTRA') ||
         u.contains('PUNCH')  || u.contains('GHR')  || u.contains('SATIN')  ||
         u.contains('CARVIN');
}

// Strip a trailing surface keyword from a design name (one pass, longest match first).
// Returns (cleaned name, detected surface) or (original, null) if nothing stripped.
(String, String?) _stripSurfaceSuffix(String name) {
  const keywords = [
    ('ENDLESS GLOSSY', 'Glossy'),
    ('PUNCH GHR',      'Rustic'),
    ('LUSTRA',         'Polished'),
    ('CARVIN',         'Carving'),
    ('MATT',           'Matt'),
    ('SATIN',          'Satin'),
    ('GHR',            'Rustic'),
    ('GLOSSY',         'Glossy'),
  ];
  final u = name.toUpperCase();
  for (final (kw, sf) in keywords) {
    if (u.endsWith(' $kw')) {
      final stripped = name.substring(0, name.length - kw.length - 1).trim();
      if (stripped.isNotEmpty) return (stripped, sf);
    }
  }
  return (name, null);
}

String _cleanDesignName(String raw) {
  final cleaned = raw
      .replaceFirst(RegExp(r'^CR\s+', caseSensitive: false), '')
      .trim();
  if (cleaned.isEmpty) return '';
  if (RegExp(r'^\d+$').hasMatch(cleaned)) return '';
  return cleaned;
}

String _mapSurface(String pdfText) {
  final s = pdfText.toUpperCase();
  if (s.contains('CARVIN'))                     return 'Carving';
  if (s.contains('GLOSSY'))                     return 'Glossy';
  if (s.contains('MATT'))                       return 'Matt';
  if (s.contains('LUSTRA'))                     return 'Polished';
  if (s.contains('SATIN'))                      return 'Satin';
  if (s.contains('PUNCH') || s.contains('GHR')) return 'Rustic';
  return 'Glossy';
}

// ── Service class ─────────────────────────────────────────────────────────────

class PdfImportService {
  Map<String, String> parseFilename(String filename) {
    final baseName = filename
        .replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '')
        .trim();
    final parts   = baseName.split(RegExp(r'[\s_]+'));
    final sizeRaw = parts[0]
        .replaceAll(RegExp(r'[xX]'), 'x')
        .toLowerCase();
    final size  = '$sizeRaw mm';
    final code  = parts.length > 1 ? parts[1].toUpperCase() : 'STD';
    final quality = switch (code) {
      'PRE' || 'PREMIUM' => 'Premium',
      'ECO' || 'ECONOMY' => 'Economy',
      _                   => 'Standard',
    };
    return {'size': size, 'quality': quality};
  }

  /// Parse a PDF file.
  ///
  /// Runs entirely in a background isolate via [compute]:
  ///   • Extracts text  → design names, quantities, surface types
  ///   • Extracts JPEGs → tile photos embedded in the PDF
  ///
  /// The UI thread never blocks, even for very large PDFs.
  Future<PdfImportResult> parsePdf(String filename, String? filePath) async {
    if (filePath == null || filePath.isEmpty) {
      final info = parseFilename(filename);
      return PdfImportResult(
          size: info['size']!, quality: info['quality']!, designs: []);
    }

    Uint8List bytes;
    try {
      bytes = await File(filePath).readAsBytes();
    } catch (_) {
      final info = parseFilename(filename);
      return PdfImportResult(
          size: info['size']!, quality: info['quality']!, designs: []);
    }

    // All heavy work in background isolate
    final Map<String, dynamic> result = await compute(
      _parsePdfTask,
      {'bytes': bytes, 'filename': filename},
    );

    final designMaps = result['designs'] as List<dynamic>;
    final imageList  = result['images']  as List<dynamic>;

    final designs = List.generate(designMaps.length, (i) {
      final m = designMaps[i] as Map<String, dynamic>;
      return PdfDesignRow(
        name:        m['name']        as String,
        quantity:    m['quantity']    as int,
        surface:     m['surface']     as String,
        finishLabel: m['finishLabel'] as String?,
        imageBytes:  i < imageList.length ? imageList[i] as Uint8List? : null,
      );
    });

    return PdfImportResult(
      size:         result['size']          as String,
      quality:      result['quality']       as String,
      designs:      designs,
      imageCount:   result['imageCount']    as int? ?? 0,
      rawLineCount: result['dbgTotalLines'] as int? ?? 0,
      digitLines:   result['dbgDigitLines'] as int? ?? 0,
    );
  }
}
