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
  // Mutable so the stockist can correct a mis-extracted name in the import
  // preview before it's saved as a new design.
  String name;
  final int quantity;
  String surface;
  /// Original finish text from the PDF when it isn't a standard finish
  /// (e.g. "Punch Ghr", "Lustra"). Null for standard finishes.
  final String? finishLabel;
  /// The FULL finish text exactly as written in the stockist's PDF
  /// (e.g. "Endless Glossy"), kept verbatim for display + alias matching.
  /// Unlike finishLabel this is never nulled for standard finishes. Mutable so
  /// the import UI can record the stockist's own wording for a single-surface
  /// PDF (one that carried no finish text of its own).
  String? surfaceRaw;
  /// Raw JPEG bytes for this design's photo. From the PDF when one was matched,
  /// or set later when the stockist picks/takes a photo in the import preview.
  /// Null when the PDF had no photo for this design and none was added yet.
  Uint8List? imageBytes;

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
    this.surfaceRaw,
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
  var size  = '$sizeRaw mm';

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

  // Optional finish in the filename (e.g. "600x1200_PRE_Glossy.pdf"). Scanned
  // across every part so its position doesn't matter. Used only for a
  // single-surface PDF — one whose table carries no finish at all — to seed the
  // one document-wide finish; ignored for layouts that already carry finishes.
  String? fileFinish;
  for (final p in parts) {
    final f = _surfaceOf(p);
    if (f != null) { fileFinish = f; break; }
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

    // Pick a parser by layout. The 'PRM' card layout (no header row; each tile
    // is a stacked name / size / surface block closed by a brand·quality·qty
    // line) carries its size + quality in the data, so those override the
    // filename-derived defaults. Everything else uses the column-adaptive parser
    // (header-based, e.g. 800X1600 STD) with the flat-text fallback.
    final geo = _buildGeoRows(lines);
    final lineRows = _buildLineRows(lines); // Syncfusion line grouping (STOCK)
    final stockFooters = lineRows.rows
        .where((r) => _stockFooterRe.hasMatch(r.map((t) => t.text).join(' ')))
        .length;
    if (stockFooters >= 2) {
      designMaps = _parseDesignsStock(lineRows); // DESIGN/GRADE/QTY/IMAGE + footers
    } else if (_looksLikePrm(geo)) {
      designMaps = _parseDesignsPrm(geo); // vertical card blocks
    } else {
      designMaps = _parseDesignsAdaptive(lines); // header table, each carries 'page'
      if (designMaps.isEmpty) {
        // Flat-text fallback has no page geometry; per-page matching is skipped.
        designMaps = _parseDesignsToMaps(PdfTextExtractor(doc).extractText());
      }
    }

    // PRM + STOCK carry their size/quality in the data — lift the dominant value
    // up to override the filename-derived defaults (and re-derive tile W/H for
    // orientation). Adaptive/flat maps have no sizeData, so this is a no-op there.
    final sd = _modeString(designMaps, 'sizeData');
    if (sd != null) {
      size = sd;
      final dp = sd.replaceAll(' mm', '').split('x');
      if (dp.length == 2) {
        tileW = int.tryParse(dp[0].replaceAll(RegExp(r'[^0-9]'), ''));
        tileH = int.tryParse(dp[1].replaceAll(RegExp(r'[^0-9]'), ''));
      }
    }
    final qd = _modeString(designMaps, 'qualityData');
    if (qd != null) quality = qd;

    // Global banner size/grade: some layouts print one size/grade for the whole
    // document (e.g. "SIZE : 600X1200" and a title "(GRADE: PRE)") instead of
    // per row or in the filename. Authoritative when the data didn't carry them.
    final bannerText = lines.map((l) => l.text).join('\n');
    if (sd == null) {
      final m = RegExp(r'SIZE\s*:?\s*(\d{2,4})\s*[xX]\s*(\d{2,4})',
              caseSensitive: false)
          .firstMatch(bannerText);
      if (m != null) {
        size = '${m.group(1)}x${m.group(2)} mm';
        tileW = int.tryParse(m.group(1)!);
        tileH = int.tryParse(m.group(2)!);
      }
    }
    if (qd == null) {
      final m = RegExp(r'GRADE\s*:?\s*(PRE|STD|ECO|PREMIUM|STANDARD|ECONOMY)\b',
              caseSensitive: false)
          .firstMatch(bannerText);
      if (m != null) {
        quality = _kGradeQuality[m.group(1)!.toUpperCase()] ?? quality;
      }
    }

    // Single-surface PDF: a "size + name + image (+ qty)" table with no finish
    // anywhere — every design came back 'None' with no raw finish text. The
    // finish is a property of the whole document, so adopt it from the filename
    // when present; otherwise leave 'None' for the stockist to set once in the
    // import preview (it then applies to every row).
    final singleSurface = designMaps.isNotEmpty &&
        designMaps.every(
            (m) => m['surfaceRaw'] == null && m['surface'] == 'None');
    if (singleSurface && fileFinish != null) {
      for (final m in designMaps) {
        m['surface'] = fileFinish;
        m['surfaceRaw'] = fileFinish; // stockist-side wording → alias learning
      }
    }
    // Per-page image matching needs page geometry on every design (adaptive &
    // PRM carry it; the flat fallback does not).
    if (designMaps.isNotEmpty &&
        designMaps.every((m) => (m['page'] as int? ?? -1) >= 0)) {
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
  // Safety net: some PDFs don't survive the single-page re-save, so per-page
  // extraction can come back with no photos at all. Detect that and fall back
  // to the whole-document JPEG scan so photos still appear.
  if (imagesPerPage != null) {
    final nonNull = imagesPerPage.fold<int>(
        0, (a, b) => a + b.where((x) => x != null).length);
    debugPrint('PDF per-page images: ${imagesPerPage.length} pages, '
        '$nonNull photos for ${designMaps.length} designs');
    if (nonNull == 0) {
      debugPrint('Per-page extraction yielded no photos — '
          'falling back to whole-document JPEG scan.');
      imagesPerPage = null;
    }
  }

  List<Uint8List?> imagesByDesign;
  int imageCount;

  // Position-based matching: when every design carries a 'yc' (currently the PRM
  // card parser), read each photo's real position from the PDF and attach it to
  // the design it sits next to — correct even when some tiles have no photo.
  final positional = designMaps.isNotEmpty &&
      designMaps.every((m) => m.containsKey('yc') && (m['page'] as int? ?? -1) >= 0);

  final perPageUsable = imagesPerPage != null &&
      designMaps.every((m) => (m['page'] as int? ?? -1) >= 0);

  if (positional) {
    imagesByDesign = _matchImagesByPosition(bytes, designMaps);
    imageCount = imagesByDesign.where((x) => x != null).length;
    debugPrint('Position-based match: $imageCount photos placed for '
        '${designMaps.length} designs.');
    // Safety net: position parsing can come back empty for a PDF whose images
    // live inside Form XObjects (not the page content stream). Fall back to
    // per-page slot matching so those formats keep their photos.
    if (imageCount == 0 && perPageUsable) {
      debugPrint('Position-based match found nothing — '
          'falling back to per-page slot matching.');
      imageCount =
          imagesPerPage.fold(0, (a, b) => a + b.where((x) => x != null).length);
      imagesByDesign = _matchImagesPerPage(designMaps, imagesPerPage);
    }
  } else if (perPageUsable) {
    imageCount =
        imagesPerPage.fold(0, (a, b) => a + b.where((x) => x != null).length);
    imagesByDesign = _matchImagesPerPage(designMaps, imagesPerPage);
  } else {
    final images = _extractJpegsFromBytes(bytes, minSizeBytes: minImageBytes);
    imageCount = images.length;
    if (images.length == designMaps.length) {
      // Exact 1:1 — safe to place every photo in document order.
      imagesByDesign = _matchImagesGlobally(images, designMaps.length);
    } else {
      // Counts differ — some designs simply have no photo in the PDF. Without
      // per-page geometry we can't tell which, and guessing misplaces every
      // photo after the gap. Leave them all blank rather than show wrong photos;
      // the stockist fills them in manually / via camera.
      debugPrint('Whole-document scan: ${images.length} photos vs '
          '${designMaps.length} designs — leaving photos blank to avoid '
          'mismatches (stockist adds them manually).');
      imagesByDesign = List<Uint8List?>.filled(designMaps.length, null);
    }
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
      // Non-JPEG photo (PNG-sourced → FlateDecode raster). Inflate + re-encode
      // so it shows like the JPEGs; falls back to a null slot (place held) when
      // the encoding/colour space isn't one we can decode.
      slots.add(_decodeFlateSlot(bytes, text, dict, streamKw));
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

// ── Position-based image → design matching ─────────────────────────────────────
//
// When a report has fewer photos than designs (some tiles simply have none),
// count-based matching can't tell which design is photo-less and misplaces
// everything below the gap. This matcher reads each photo's real position from
// the PDF page content streams and attaches it to the design whose vertical band
// it sits in; designs with no photo in their band stay blank.
//
// It parses the PDF directly (these reports use top-level objects, no object
// streams): scan `N 0 obj … endobj`, walk the /Pages → /Kids tree for page order,
// decompress each page's content stream, track the CTM through q/Q/cm and read
// `/Name Do` image placements, then map names → image XObjects → JPEG bytes.
// Requires each design map to carry 'page' and 'yc'. Falls back to all-null on
// any parse error (the caller then leaves photos blank).

class _PdfObj {
  final String dict;
  final int? streamStart; // byte offset of stream data (null if no stream)
  final int? streamEnd;
  _PdfObj(this.dict, this.streamStart, this.streamEnd);
}

class _PlacedImg {
  double top;     // top edge in top-left page coords
  double height;
  final double width;
  final List<int> refs; // image XObject numbers (>1 when a tile is tiled strips)
  _PlacedImg(this.top, this.height, this.width, this.refs);
  double get centerY => top + height / 2;
}

Map<int, _PdfObj> _parsePdfObjects(Uint8List bytes, String s) {
  final objs = <int, _PdfObj>{};
  for (final m in RegExp(r'(\d+)\s+0\s+obj').allMatches(s)) {
    final num = int.parse(m.group(1)!);
    final start = m.end;
    final endobj = s.indexOf('endobj', start);
    if (endobj < 0) continue;
    final sidx = s.indexOf('stream', start);
    if (sidx >= 0 && sidx < endobj) {
      var so = sidx + 6; // past 'stream'
      if (s.startsWith('\r\n', so)) {
        so += 2;
      } else if (so < s.length && (s[so] == '\n' || s[so] == '\r')) {
        so += 1;
      }
      var eidx = s.indexOf('endstream', so);
      if (eidx < 0 || eidx > endobj + 9) eidx = endobj;
      objs[num] = _PdfObj(s.substring(start, sidx), so, eidx);
    } else {
      objs[num] = _PdfObj(s.substring(start, endobj), null, null);
    }
  }
  return objs;
}

List<int> _inflate(Uint8List data) {
  try {
    return zlib.decode(data);
  } catch (_) {
    try {
      return ZLibDecoder(raw: true).convert(data);
    } catch (_) {
      return const [];
    }
  }
}

List<double> _mulCtm(List<double> m1, List<double> m2) {
  final a = m1[0], b = m1[1], c = m1[2], d = m1[3], e = m1[4], f = m1[5];
  final a2 = m2[0], b2 = m2[1], c2 = m2[2], d2 = m2[3], e2 = m2[4], f2 = m2[5];
  return [
    a * a2 + b * c2,
    a * b2 + b * d2,
    c * a2 + d * c2,
    c * b2 + d * d2,
    e * a2 + f * c2 + e2,
    e * b2 + f * d2 + f2,
  ];
}

double _mediaBoxH(String pageDict) {
  final m = RegExp(r'/MediaBox\s*\[([^\]]+)\]').firstMatch(pageDict);
  if (m != null) {
    final v = m.group(1)!.trim().split(RegExp(r'\s+')).map(double.tryParse).toList();
    if (v.length == 4 && v.every((e) => e != null)) return v[3]! - v[1]!;
  }
  return 792.0;
}

Map<String, int> _xobjectMap(Map<int, _PdfObj> objs, String pageDict) {
  var rdict = pageDict;
  final rref = RegExp(r'/Resources\s+(\d+)\s+0\s+R').firstMatch(pageDict);
  if (rref != null) rdict = objs[int.parse(rref.group(1)!)]?.dict ?? pageDict;
  String? xbody =
      RegExp(r'/XObject\s*<<(.*?)>>', dotAll: true).firstMatch(rdict)?.group(1);
  if (xbody == null) {
    final xref = RegExp(r'/XObject\s+(\d+)\s+0\s+R').firstMatch(rdict);
    if (xref != null) {
      final xd = objs[int.parse(xref.group(1)!)]?.dict ?? '';
      xbody = RegExp(r'<<(.*?)>>', dotAll: true).firstMatch(xd)?.group(1);
    }
  }
  final map = <String, int>{};
  if (xbody != null) {
    for (final m in RegExp(r'/([A-Za-z0-9_.]+)\s+(\d+)\s+0\s+R').allMatches(xbody)) {
      map[m.group(1)!] = int.parse(m.group(2)!);
    }
  }
  return map;
}

String _contentText(Uint8List bytes, Map<int, _PdfObj> objs, String pageDict) {
  final refs = <int>[];
  final single = RegExp(r'/Contents\s+(\d+)\s+0\s+R').firstMatch(pageDict);
  if (single != null) {
    refs.add(int.parse(single.group(1)!));
  } else {
    final arr =
        RegExp(r'/Contents\s*\[(.*?)\]', dotAll: true).firstMatch(pageDict);
    if (arr != null) {
      for (final r in RegExp(r'(\d+)\s+0\s+R').allMatches(arr.group(1)!)) {
        refs.add(int.parse(r.group(1)!));
      }
    }
  }
  final acc = <int>[];
  for (final r in refs) {
    final o = objs[r];
    if (o?.streamStart != null) {
      acc.addAll(_inflate(
          Uint8List.fromList(bytes.sublist(o!.streamStart!, o.streamEnd!))));
    }
  }
  return latin1.decode(Uint8List.fromList(acc), allowInvalid: true);
}

List<int> _pageObjectsInOrder(Map<int, _PdfObj> objs) {
  int? root;
  objs.forEach((n, o) {
    if (root == null &&
        RegExp(r'/Type\s*/Pages\b').hasMatch(o.dict) &&
        o.dict.contains('/Kids')) {
      root = n;
    }
  });
  final pages = <int>[];
  void walk(int n, Set<int> seen) {
    if (seen.contains(n)) return;
    seen.add(n);
    final d = objs[n]?.dict ?? '';
    if (RegExp(r'/Type\s*/Page\b').hasMatch(d)) {
      pages.add(n);
      return;
    }
    final km = RegExp(r'/Kids\s*\[(.*?)\]', dotAll: true).firstMatch(d);
    if (km != null) {
      for (final k in RegExp(r'(\d+)\s+0\s+R').allMatches(km.group(1)!)) {
        walk(int.parse(k.group(1)!), seen);
      }
    }
  }

  if (root != null) walk(root!, {});
  if (pages.isEmpty) {
    final ks = objs.keys.toList()..sort();
    for (final n in ks) {
      if (RegExp(r'/Type\s*/Page\b').hasMatch(objs[n]!.dict)) pages.add(n);
    }
  }
  return pages;
}

Uint8List? _imageJpeg(Uint8List bytes, _PdfObj o) {
  if (o.streamStart == null || !o.dict.contains('DCTDecode')) return null;
  final end0 = o.streamEnd!.clamp(0, bytes.length);
  for (var i = o.streamStart!; i < end0 - 2; i++) {
    if (bytes[i] == 0xFF && bytes[i + 1] == 0xD8 && bytes[i + 2] == 0xFF) {
      final end = _findJpegEnd(bytes, i);
      return end > i ? bytes.sublist(i, end) : null;
    }
  }
  return null;
}

int? _intField(String dict, String key) {
  final m = RegExp('/$key\\s+(\\d+)').firstMatch(dict);
  return m != null ? int.parse(m.group(1)!) : null;
}

// PNG-predictor un-filtering (predictors 10–15) for FlateDecode rasters that use
// it. [colors] = samples per pixel (== bytes-per-pixel at 8 bits).
List<int> _pngUnpredict(List<int> data, int columns, int colors) {
  final bpp = colors;
  final rowLen = columns * colors;
  if (rowLen <= 0) return const [];
  final out = <int>[];
  final prev = List<int>.filled(rowLen, 0);
  var pos = 0;
  while (pos + 1 + rowLen <= data.length) {
    final ft = data[pos++];
    final row = data.sublist(pos, pos + rowLen);
    pos += rowLen;
    for (var i = 0; i < rowLen; i++) {
      final a = i >= bpp ? row[i - bpp] : 0;
      final b = prev[i];
      final c = i >= bpp ? prev[i - bpp] : 0;
      int v;
      switch (ft) {
        case 1:
          v = row[i] + a;
        case 2:
          v = row[i] + b;
        case 3:
          v = row[i] + ((a + b) >> 1);
        case 4:
          final p = a + b - c;
          final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
          final pr = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
          v = row[i] + pr;
        default:
          v = row[i];
      }
      row[i] = v & 0xFF;
    }
    out.addAll(row);
    for (var i = 0; i < rowLen; i++) {
      prev[i] = row[i];
    }
  }
  return out;
}

// Returns JPEG bytes for an image XObject, decoding the two encodings these
// reports use: DCTDecode (already JPEG) and FlateDecode 8-bit RGB/Gray rasters
// (e.g. PNG-sourced photos) which we inflate and re-encode. CMYK / other
// colour spaces / bit depths are skipped (left blank for manual fill).
Uint8List? _decodeImageXObject(Uint8List bytes, _PdfObj o) {
  if (o.streamStart == null) return null;
  final d = o.dict;
  if (d.contains('DCTDecode')) return _imageJpeg(bytes, o);
  if (!d.contains('FlateDecode')) return null;
  final w = _intField(d, 'Width');
  final h = _intField(d, 'Height');
  final bpc = _intField(d, 'BitsPerComponent') ?? 8;
  if (w == null || h == null || bpc != 8) return null;
  if (d.contains('/DeviceCMYK')) return null;
  final channels = d.contains('/DeviceGray') ? 1 : 3;

  var raw = _inflate(Uint8List.fromList(bytes.sublist(o.streamStart!, o.streamEnd!)));
  final predM = RegExp(r'/Predictor\s+(\d+)').firstMatch(d);
  if (predM != null && int.parse(predM.group(1)!) >= 10) {
    raw = _pngUnpredict(raw, w, channels);
  }
  final need = w * h * channels;
  if (raw.length < need) return null;
  final pix = Uint8List.fromList(raw.sublist(0, need));
  final im = channels == 1
      ? img.Image.fromBytes(width: w, height: h, bytes: pix.buffer, numChannels: 1)
      : img.Image.fromBytes(
          width: w,
          height: h,
          bytes: pix.buffer,
          numChannels: 3,
          order: img.ChannelOrder.rgb);
  return img.encodeJpg(im, quality: 85);
}

// Per-page slot variant of _decodeImageXObject: decode a FlateDecode 8-bit
// RGB/Gray raster (PNG-sourced photo) located by regex in a single-page PDF's
// text, given its image dictionary and the offset of its 'stream' keyword. CMYK
// / other colour spaces / bit depths / non-Flate encodings return null (slot
// stays empty for manual fill). Mirrors _decodeImageXObject's decode path.
Uint8List? _decodeFlateSlot(
    Uint8List bytes, String text, String dict, int streamKw) {
  if (streamKw < 0 || !dict.contains('FlateDecode')) return null;
  final w = _intField(dict, 'Width');
  final h = _intField(dict, 'Height');
  final bpc = _intField(dict, 'BitsPerComponent') ?? 8;
  if (w == null || h == null || bpc != 8) return null;
  if (dict.contains('/DeviceCMYK')) return null;
  final channels = dict.contains('/DeviceGray') ? 1 : 3;

  // Stream data starts just after the 'stream' keyword + its CR?LF, and runs to
  // 'endstream'. latin1 made text indices == byte indices, so reuse them.
  var dataStart = streamKw + 'stream'.length;
  if (dataStart < bytes.length && bytes[dataStart] == 0x0D) dataStart++;
  if (dataStart < bytes.length && bytes[dataStart] == 0x0A) dataStart++;
  final endIdx = text.indexOf('endstream', dataStart);
  if (endIdx < 0 || endIdx <= dataStart) return null;

  var raw = _inflate(Uint8List.fromList(bytes.sublist(dataStart, endIdx)));
  final predM = RegExp(r'/Predictor\s+(\d+)').firstMatch(dict);
  if (predM != null && int.parse(predM.group(1)!) >= 10) {
    raw = _pngUnpredict(raw, w, channels);
  }
  final need = w * h * channels;
  if (raw.length < need) return null;
  final pix = Uint8List.fromList(raw.sublist(0, need));
  final im = channels == 1
      ? img.Image.fromBytes(width: w, height: h, bytes: pix.buffer, numChannels: 1)
      : img.Image.fromBytes(
          width: w,
          height: h,
          bytes: pix.buffer,
          numChannels: 3,
          order: img.ChannelOrder.rgb);
  return img.encodeJpg(im, quality: 85);
}

// Bytes for a placement: a single image, or vertically stitched strips.
Uint8List? _placedBytes(Uint8List bytes, Map<int, _PdfObj> objs, _PlacedImg p) {
  if (p.refs.length == 1) return _decodeImageXObject(bytes, objs[p.refs.first]!);
  final parts = <img.Image>[];
  for (final r in p.refs) {
    final jb = _decodeImageXObject(bytes, objs[r]!);
    if (jb == null) return null;
    final im = img.decodeJpg(jb);
    if (im == null) return null;
    parts.add(im);
  }
  final w = parts.first.width;
  final totalH = parts.fold<int>(0, (a, b) => a + b.height);
  final canvas = img.Image(width: w, height: totalH);
  var y = 0;
  for (final part in parts) {
    img.compositeImage(canvas, part, dstY: y);
    y += part.height;
  }
  return img.encodeJpg(canvas, quality: 90);
}

List<_PlacedImg> _imagesOnPage(
    Uint8List bytes, Map<int, _PdfObj> objs, int pageObj) {
  final pd = objs[pageObj]!.dict;
  final h = _mediaBoxH(pd);
  final xo = _xobjectMap(objs, pd);
  final ct = _contentText(bytes, objs, pd);

  var ctm = <double>[1, 0, 0, 1, 0, 0];
  final st = <List<double>>[];
  final raw = <_PlacedImg>[];
  // q/Q only as standalone operators (not the 'q'/'Q' inside text strings like
  // "AQUA"), plus 6-number cm matrices and `/Name Do` image draws.
  final tokRe = RegExp(
      r'(?<![A-Za-z0-9])[qQ](?![A-Za-z0-9])|(?:[-\d.]+\s+){6}cm|/[A-Za-z0-9_.]+\s+Do');
  for (final m in tokRe.allMatches(ct)) {
    final t = m.group(0)!;
    if (t == 'q') {
      st.add(List.of(ctm));
    } else if (t == 'Q') {
      if (st.isNotEmpty) ctm = st.removeLast();
    } else if (t.endsWith('cm')) {
      final n = t
          .split(RegExp(r'\s+'))
          .where((x) => x.isNotEmpty)
          .take(6)
          .map((x) => double.tryParse(x) ?? 0)
          .toList();
      if (n.length == 6) ctm = _mulCtm(n, ctm);
    } else {
      final nm = t.split(RegExp(r'\s+')).first.substring(1);
      final ref = xo[nm];
      if (ref != null &&
          RegExp(r'/Subtype\s*/Image').hasMatch(objs[ref]?.dict ?? '')) {
        final wdt = ctm[0].abs();
        final hh = ctm[3].abs();
        final top = h - (ctm[5] + hh);
        raw.add(_PlacedImg(top, hh, wdt, [ref]));
      }
    }
  }
  raw.sort((a, b) => a.top.compareTo(b.top));

  // Merge vertically-contiguous strips of the same width (a tiled single photo).
  final merged = <_PlacedImg>[];
  for (final p in raw) {
    if (merged.isNotEmpty &&
        (merged.last.width - p.width).abs() < 3 &&
        ((merged.last.top + merged.last.height) - p.top).abs() < 4) {
      merged.last.height += p.height;
      merged.last.refs.add(p.refs.first);
    } else {
      merged.add(p);
    }
  }
  return merged;
}

List<Uint8List?> _matchImagesByPosition(
    Uint8List bytes, List<Map<String, dynamic>> designMaps) {
  final out = List<Uint8List?>.filled(designMaps.length, null);
  try {
    final s = latin1.decode(bytes, allowInvalid: true);
    final objs = _parsePdfObjects(bytes, s);
    final pageObjs = _pageObjectsInOrder(objs);

    final byPage = <int, List<int>>{};
    for (var i = 0; i < designMaps.length; i++) {
      (byPage[designMaps[i]['page'] as int] ??= <int>[]).add(i);
    }
    final cache = <int, List<_PlacedImg>>{};
    byPage.forEach((page, idxs) {
      if (page < 0 || page >= pageObjs.length) return;
      final imgs = cache[page] ??= _imagesOnPage(bytes, objs, pageObjs[page]);
      final used = List<bool>.filled(imgs.length, false);
      for (final di in idxs) {
        final dy = (designMaps[di]['yc'] as num?)?.toDouble();
        if (dy == null) continue;
        var best = -1;
        var bestDist = 1e9;
        var bestContains = false;
        for (var k = 0; k < imgs.length; k++) {
          if (used[k]) continue;
          final im = imgs[k];
          final contains = dy >= im.top - 6 && dy <= im.top + im.height + 6;
          final dist = (im.centerY - dy).abs();
          if (contains && !bestContains) {
            bestContains = true;
            best = k;
            bestDist = dist;
          } else if (contains == bestContains && dist < bestDist) {
            best = k;
            bestDist = dist;
          }
        }
        if (best >= 0 && (bestContains || bestDist <= 40)) {
          used[best] = true;
          out[di] = _placedBytes(bytes, objs, imgs[best]);
        }
      }
    });
  } catch (e, st) {
    debugPrint('position-based image match failed: $e\n$st');
  }
  return out;
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
    case 'BRAND': case 'BRND': case 'COMPANY': case 'MAKE': case 'MFR':
      return 'brand';
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
  // Global size banner (e.g. "SIZE : 600 X 1200") — captured separately as the
  // document size; never a tile design. Without this the spaced "1200" leaks
  // into the nearest design name.
  if (RegExp(r'^\s*size\s*:', caseSensitive: false).hasMatch(u)) return true;
  // Document summary lines (e.g. "WEIGHT (TON) : 43.336  GRAND TOTAL : 1670") —
  // never a tile design.
  if (RegExp(r'grand\s+total|\btotal\s*:|weight\s*\(?\s*ton|order[- ]?confirm',
          caseSensitive: false)
      .hasMatch(u)) {
    return true;
  }
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
  // No SURFACE column → the table carries no per-row finish. Don't invent
  // 'Glossy'; default such rows to 'None' so the import UI can ask the stockist
  // for the single document-wide finish (the single-surface PDF layout). A
  // content-sniffed section header, if any appears, still overrides this below.
  final hasSurfaceColumn = anchors.containsKey('surface');

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

  // 3b. Re-join vertically-wrapped surface cells. A narrow surface column can
  // wrap a finish onto two stacked lines (e.g. "ENDLESS" then "GLOSSY"); the Y
  // row-grouping then splits them, so the design keeps only "ENDLESS" and the
  // leftover "GLOSSY" becomes a phantom row. Move such orphan surface-column
  // tokens onto the design row just above — close in Y (a wrap, not the ~design
  // spacing) and already carrying a surface token — so the full finish
  // ("Endless Glossy") is preserved.
  if (hasHeader && anchors.containsKey('surface')) {
    bool hasQty(List<_Tok> r) =>
        r.any((t) => _isQtyToken(t.text) && roleForX(t.xc) == 'qty');
    bool hasSurf(List<_Tok> r) => r.any((t) => roleForX(t.xc) == 'surface');
    final designRows = [
      for (var i = 0; i < rows.length; i++)
        if (hasQty(rows[i]) && hasSurf(rows[i])) i
    ];
    for (var i = 0; i < rows.length; i++) {
      if (hasQty(rows[i])) continue; // a real design row keeps its own surface
      final orphan =
          rows[i].where((t) => roleForX(t.xc) == 'surface').toList();
      if (orphan.isEmpty) continue;
      int? tgt;
      for (final j in designRows) {
        if (rows[j].first.page != rows[i].first.page) continue;
        final gap = rows[i].first.yc - rows[j].first.yc;
        if (gap > 0 && gap <= medH * 2.2) {
          if (tgt == null || rows[j].first.yc > rows[tgt].first.yc) tgt = j;
        }
      }
      final target = tgt;
      if (target == null) continue;
      rows[target].addAll(orphan);
      rows[i].removeWhere((t) => roleForX(t.xc) == 'surface');
    }
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
          case 'brand':
            continue; // brand/maker column — not part of the design name
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

    // Order surface tokens top-to-bottom then left-to-right so a wrapped cell
    // joins as "ENDLESS GLOSSY", not "GLOSSY ENDLESS".
    surfToks.sort((a, b) =>
        a.yc != b.yc ? a.yc.compareTo(b.yc) : a.x0.compareTo(b.x0));
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
  String runningSurface = hasSurfaceColumn ? 'Glossy' : 'None';
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

    // Full original finish text as written in the stockist's PDF (own cell, else
    // the inherited section header). Kept verbatim — unlike finishLabel it is
    // never nulled — so the stockist sees their exact wording ("Endless Glossy")
    // next to the mapped admin finish, and can confirm/correct the mapping.
    final rawForDisplay = (raw != null && raw.isNotEmpty) ? raw : runningRaw;

    result.add({
      'name': name,
      'quantity': c.qty!,
      'surface': surfaceType,
      'finishLabel': finishLabel,
      'surfaceRaw': rawForDisplay == null ? null : _titleCaseFinish(rawForDisplay),
      'page': c.page, // drives per-page image↔design matching
      'yc': c.yc,     // row centre → position-based photo matching (handles
                      // reused image XObjects + photo-less rows correctly)
    });
  }

  debugPrint('Adaptive PDF parse: ${result.length} designs '
      '(header=$hasHeader, rows=${rows.length})');
  return result;
}

// ── 'PRM' card-layout parser ───────────────────────────────────────────────────
//
// Some suppliers export a vertical "card" layout instead of a table: there is no
// NAME/IMAGE/BOX/SURFACE header. Each tile is a stacked block —
//
//     6003 (SV)                    ← name (one or more lines)
//     600X1200                     ← size
//     END MATCH GLOSSY             ← surface (one or more lines)
//     GRACIAS   Premium   13       ← brand · quality · box-qty  (closes the block)
//
// with the tile photo on the left. Size and quality live in the data here (not
// in the filename). We read by geometry: group words into visual rows, then walk
// rows accumulating a block until the brand·quality·qty line closes it.

const Set<String> _kQualityWords = {'PREMIUM', 'STANDARD', 'ECONOMY'};

class _GeoRows {
  final List<List<_Tok>> rows; // visual rows, sorted by (page, y) then x
  final double medH;
  _GeoRows(this.rows, this.medH);
}

// Group every word into visual rows by vertical proximity (per page). Shared by
// the PRM parser and its detector; the adaptive parser builds its own rows.
_GeoRows _buildGeoRows(List<TextLine> lines) {
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
  if (toks.isEmpty) return _GeoRows(const [], 10);

  final hs = toks.map((t) => t.h).where((h) => h > 0).toList()..sort();
  final medH = hs.isEmpty ? 10.0 : hs[hs.length ~/ 2];
  final rowTol = medH * 0.6;

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
  return _GeoRows(rows, medH);
}

// Like _buildGeoRows but keeps Syncfusion's own line grouping (one row per
// TextLine) instead of re-grouping by Y. Used by the STOCK parser because its
// footer subtotal lines (e.g. "600X1200 - MATT - PRE : 270") must stay on a
// single row to be recognised — Y re-grouping can split them.
_GeoRows _buildLineRows(List<TextLine> lines) {
  final rows = <List<_Tok>>[];
  final heights = <double>[];
  for (final line in lines) {
    final row = <_Tok>[];
    for (final w in line.wordCollection) {
      final t = w.text.trim();
      if (t.isEmpty) continue;
      final b = w.bounds;
      row.add(_Tok(line.pageIndex, b.left, b.right, b.top + b.height / 2,
          b.height, t));
      if (b.height > 0) heights.add(b.height);
    }
    if (row.isNotEmpty) {
      row.sort((a, b) => a.x0.compareTo(b.x0));
      rows.add(row);
    }
  }
  rows.sort((a, b) => a.first.page != b.first.page
      ? a.first.page.compareTo(b.first.page)
      : a.first.yc.compareTo(b.first.yc));
  heights.sort();
  final medH = heights.isEmpty ? 10.0 : heights[heights.length ~/ 2];
  return _GeoRows(rows, medH);
}

// True when the document looks like the PRM card layout: no recognisable column
// header anywhere, but several "… <Quality> <qty>" closing lines.
bool _looksLikePrm(_GeoRows g) {
  if (g.rows.isEmpty) return false;
  final hasHeader = g.rows.any((r) {
    var roles = 0;
    for (final t in r) {
      if (_headerRole(t.text) != null) roles++;
    }
    return roles >= 2;
  });
  if (hasHeader) return false;

  var dataLines = 0;
  for (final r in g.rows) {
    final hasQual = r.any((t) => _kQualityWords.contains(t.text.toUpperCase()));
    final hasInt = r.any((t) => _isQtyToken(t.text));
    if (hasQual && hasInt) dataLines++;
  }
  return dataLines >= 3;
}

List<Map<String, dynamic>> _parseDesignsPrm(_GeoRows g) {
  final result = <Map<String, dynamic>>[];
  var buf = <List<_Tok>>[]; // name / size / surface rows awaiting their closer
  int? curPage;

  String joinRows(Iterable<List<_Tok>> rs) =>
      rs.map((r) => r.map((t) => t.text).join(' ')).join(' ').trim();

  void flush(List<_Tok> dataRow, int page) {
    final ints = dataRow.where((t) => _isQtyToken(t.text)).toList()
      ..sort((a, b) => a.x0.compareTo(b.x0));
    if (ints.isEmpty || buf.isEmpty) {
      buf = [];
      return;
    }
    final qty = int.tryParse(ints.last.text) ?? 0;
    final qualTok = dataRow.firstWhere(
        (t) => _kQualityWords.contains(t.text.toUpperCase()),
        orElse: () => dataRow.first);
    final quality = _titleCaseFinish(qualTok.text);

    // Split the buffered rows on the size line: rows above are the name, rows
    // below are the surface (handles multi-line names and multi-word surfaces).
    var sizeIdx = -1;
    for (var i = 0; i < buf.length; i++) {
      if (buf[i].any((t) => _sizeRe.hasMatch(t.text))) {
        sizeIdx = i;
        break;
      }
    }
    final String name;
    String sizeStr = '';
    final String surfaceRaw;
    if (sizeIdx >= 0) {
      name = joinRows(buf.sublist(0, sizeIdx));
      sizeStr = buf[sizeIdx]
          .firstWhere((t) => _sizeRe.hasMatch(t.text))
          .text;
      surfaceRaw = joinRows(buf.sublist(sizeIdx + 1));
    } else {
      name = buf.isNotEmpty ? joinRows([buf.first]) : '';
      surfaceRaw = joinRows(buf.skip(1));
    }

    final cleanName = _cleanName(name, allowNumeric: true);
    if (cleanName.isEmpty) {
      buf = [];
      return;
    }

    final surface = surfaceRaw.isEmpty ? 'None' : (_surfaceOf(surfaceRaw) ?? 'None');
    final finishLabel = surfaceRaw.isEmpty
        ? null
        : (surface == 'None'
            ? _titleCaseFinish(surfaceRaw)
            : _finishLabelFor(surfaceRaw, surface));

    result.add({
      'name': cleanName,
      'quantity': qty,
      'surface': surface,
      'finishLabel': finishLabel,
      'surfaceRaw': surfaceRaw.isEmpty ? null : _titleCaseFinish(surfaceRaw),
      'page': page,
      'yc': buf.first.first.yc, // block top — for position-based photo matching
      'sizeData': sizeStr.isEmpty ? null : '${sizeStr.toLowerCase()} mm',
      'qualityData': quality,
    });
    buf = [];
  }

  for (final r in g.rows) {
    final page = r.first.page;
    if (curPage != null && page != curPage) buf = []; // blocks never span pages
    curPage = page;

    final joined = r.map((t) => t.text).join(' ');
    if (_isJunkRow(joined)) continue; // page footers / dates / report titles

    final hasQual = r.any((t) => _kQualityWords.contains(t.text.toUpperCase()));
    final hasInt = r.any((t) => _isQtyToken(t.text));
    final hasSize = r.any((t) => _sizeRe.hasMatch(t.text));

    if (hasQual && hasInt) {
      flush(r, page); // closing line for the current block
    } else if (hasSize && hasInt) {
      continue; // page-title line ("600X1200  1360") — size + total, no quality
    } else {
      buf.add(r);
    }
  }
  return result;
}

// Most common non-empty value of [key] across [maps] (used to lift the
// data-carried size / quality up to the top-level result).
String? _modeString(List<Map<String, dynamic>> maps, String key) {
  final counts = <String, int>{};
  for (final m in maps) {
    final v = m[key] as String?;
    if (v != null && v.isNotEmpty) counts[v] = (counts[v] ?? 0) + 1;
  }
  if (counts.isEmpty) return null;
  return counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
}

// ── 'STOCK' footer-surface parser ──────────────────────────────────────────────
//
// Another layout: a DESIGN / GRADE / QTY / IMAGE table whose surface lives in
// section FOOTER lines, e.g. `600X1200 - MARBLE RANDOM - PRE : 234`. The footer
// closes a group: its surface (the middle field), size and grade apply to every
// design row ABOVE it since the previous footer — and groups can span pages.

// Captures: (1) size — allowing spaces around the X, e.g. "600 X 1200" as
// Syncfusion renders it; (2) the surface (middle field, may be empty/dashes);
// (3) the grade keyword. Matches the footer subtotal lines.
final _stockFooterRe = RegExp(
    r'(\d{2,4}\s*[xX]\s*\d{2,4})\s*-(.*)-\s*(PRE|STD|ECO|PREMIUM|STANDARD|ECONOMY)\b\s*:',
    caseSensitive: false);

const Map<String, String> _kGradeQuality = {
  'PRE': 'Premium', 'PREMIUM': 'Premium',
  'STD': 'Standard', 'STANDARD': 'Standard',
  'ECO': 'Economy', 'ECONOMY': 'Economy',
};

List<Map<String, dynamic>> _parseDesignsStock(_GeoRows g) {
  // Learn column x-anchors from the header rows (DESIGN→name, QTY→qty, IMAGE).
  final acc = <String, List<double>>{};
  for (final r in g.rows) {
    final found = <String, double>{};
    for (final t in r) {
      final role = _headerRole(t.text);
      if (role != null) found[role] = t.xc;
    }
    if (found.length >= 2) found.forEach((k, x) => (acc[k] ??= []).add(x));
  }
  double anchor(String k, double dflt) => acc.containsKey(k)
      ? acc[k]!.reduce((a, b) => a + b) / acc[k]!.length
      : dflt;
  final nameX = anchor('name', 42);
  final qtyX = anchor('qty', 368);
  final imageX = anchor('image', 467);
  final nameHi = (nameX + qtyX) / 2; // design column upper bound
  final qtyHi = (qtyX + imageX) / 2; // qty column upper bound

  final result = <Map<String, dynamic>>[];
  final pending = <Map<String, dynamic>>[];

  for (final r in g.rows) {
    final joined = r.map((t) => t.text).join(' ');

    final fm = _stockFooterRe.firstMatch(joined);
    if (fm != null) {
      // size: strip the spaces Syncfusion inserts ("600 X 1200" → "600x1200").
      final sizeData = '${fm.group(1)!.replaceAll(RegExp(r'\s+'), '').toLowerCase()} mm';
      // surface: the middle field, with stray dashes/extra spaces cleaned and
      // single-character fragments re-joined (Syncfusion splits short codes like
      // "3D" → "3 D", "DC" → "D C"; multi-word finishes are left untouched).
      final surfaceRaw = _joinShortFragments(fm
          .group(2)!
          .replaceAll('-', ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim());
      final grade = _kGradeQuality[fm.group(3)!.toUpperCase()] ?? 'Premium';
      final surface =
          surfaceRaw.isEmpty ? 'None' : (_surfaceOf(surfaceRaw) ?? 'None');
      for (final d in pending) {
        d['surface'] = surface;
        d['finishLabel'] = surfaceRaw.isEmpty
            ? null
            : (surface == 'None'
                ? _titleCaseFinish(surfaceRaw)
                : _finishLabelFor(surfaceRaw, surface));
        d['surfaceRaw'] =
            surfaceRaw.isEmpty ? null : _titleCaseFinish(surfaceRaw);
        d['sizeData'] = sizeData;
        d['qualityData'] = grade;
      }
      pending.clear();
      continue;
    }

    // Design row: name token(s) in the design column + a qty number in the qty
    // column. Header / junk rows fail this and are skipped.
    final nameToks = <_Tok>[];
    int? qty;
    for (final t in r) {
      if (_sizeRe.hasMatch(t.text)) continue;
      if (t.xc < nameHi) {
        if (!_isJunkNameToken(t.text)) nameToks.add(t);
      } else if (t.xc < qtyHi && _isQtyToken(t.text)) {
        qty ??= int.tryParse(t.text);
      }
    }
    if (qty == null || nameToks.isEmpty) continue;
    if (_isJunkRow(joined)) continue;
    nameToks.sort((a, b) => a.x0.compareTo(b.x0));
    final name =
        _cleanName(nameToks.map((t) => t.text).join(' '), allowNumeric: true);
    if (name.isEmpty) continue;

    final m = <String, dynamic>{
      'name': name,
      'quantity': qty,
      'surface': 'None', // filled by the next footer
      'finishLabel': null,
      'surfaceRaw': null,
      'page': r.first.page,
      'yc': r.first.yc,
      'sizeData': null,
      'qualityData': 'Premium',
    };
    result.add(m);
    pending.add(m);
  }
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

// Glue runs of consecutive single-character tokens back into one word, undoing
// Syncfusion's habit of splitting short surface codes ("3D" → "3 D", "DC" →
// "D C"). Multi-character tokens (real words like "Endless Glossy") are kept as
// separate words, so genuine multi-word finishes are unaffected.
String _joinShortFragments(String s) {
  final toks = s.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  final out = <String>[];
  final buf = StringBuffer();
  for (final t in toks) {
    if (t.length == 1) {
      buf.write(t);
    } else {
      if (buf.isNotEmpty) {
        out.add(buf.toString());
        buf.clear();
      }
      out.add(t);
    }
  }
  if (buf.isNotEmpty) out.add(buf.toString());
  return out.join(' ');
}

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
        surfaceRaw:  m['surfaceRaw']  as String?,
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
