# Supplier PDF formats — parser registry

Every supplier PDF layout we can read has a **hand-coded parser** in
`lib/services/pdf_import_service.dart` (no AI/LLM — heuristic + position-based).
On upload, the engine tries each parser's "signature" **in order** and uses the
first that matches; anything unrecognised falls to a flat-text fallback (which
loses photo positions). This file is the running list of what's covered.

> Adding a format = a developer writes one new parser (a few KB of code).
> **~0 extra app size, ~0 speed cost.** The cost is developer time, not the phone.
>
> Needs: the **real PDF** with a **text layer** (born-digital, e.g. Excel/Tally→PDF).
> Phone-**scanned image** PDFs have no text and can't be parsed by this engine
> (would need OCR/vision). Ideally **2–3 samples** of a supplier so the parser
> handles their quirks (a missing field / extra column on some pages).

## Dispatch order (in `_parsePdfTask`)

| # | Format | Detector | Parser | Signature |
|---|--------|----------|--------|-----------|
| 1 | **STOCK** | `stockFooters >= 2` | `_parseDesignsStock` | `DESIGN/GRADE/QTY/IMAGE` table + `size-surface-grade :` footers |
| 2 | **DSR** ("Design Stock Report") | `_looksLikeDsr` | `_parseDesignsDsr` | labelled card (Product/Brand/Size/Category…) + unlabelled name box + `<grade> BOX <qty>` footer |
| 3 | **CONFIRM ORDER** (grade table) | `_looksLikeConfirmOrder` | `_parseDesignsConfirmOrder` | header table `BRAND/DESIGN/GRADE/QTY/IMAGE` closed by a `<size>-<surface>-<grade> : <total>` footer (size often in inches) |
| 3 | **LABELED** | `_looksLikeLabeled` | `_parseDesignsLabeled` | `Design : …` / `Box : …` key-value cards |
| 4 | **RAK** | `_looksLikeRak` | `_parseDesignsRak` | photo + caption `NAME … BOX = n`, size/surface in vertical margins |
| 5 | **PRM** | `_looksLikePrm` | `_parseDesignsPrm` | stacked name/size/surface card closed by a `brand·grade·qty` line |
| — | Adaptive | (fallback) | `_parseDesignsAdaptive` | any header table (Design/Size/Qty columns) |
| — | Flat-text | (last resort) | `_parseDesignsToMaps` | raw text, **no photo matching** |

## Supplier sample log

Keep one copy of each sample PDF (outside the repo). Number them so you can track
coverage.

| Sample # | File | Format | Added | Notes |
|---|---|---|---|---|
| 1 | `600X1200 MATT STOCK.pdf` | DSR (#2) | 2026-06-19 | 1 page, 2 tiles |
| 2 | `600X1200 M-ALT HAJAR STOCK.pdf` | DSR (#2) | 2026-06-19 | 3 pages, 7 tiles; ALT-1031 has a blank photo (left blank) |
| 3 | `600X1200 HAJAR STOCK T.pdf` | DSR (#2) | 2026-06-19 | 3 pages, 9 tiles; codes like AH-234, VS-M-1004 |
| 4 | `HAJAR STOCK 16X16.pdf` | CONFIRM ORDER (#3) | 2026-06-19 | ALTROS CERAMIC; 8 tiles; size 16X16″→400x400mm from the grand-total footer; GRADE column → quality |

### DSR ("Design Stock Report") — details
- **Layout:** photo on the left; right block of `Product / Brand / Size /
  Category(=surface) / Weight / PCS per Box / SqrFeet` labels; an unlabelled
  **design-name box**; a `PRE|STD|ECO  BOX  <qty>` footer that closes each tile.
- **Extracted:** name (name box), quantity (footer int), surface (Category
  value), quality (grade word), size (Size value). Photos matched by position
  (the name row sits inside the photo), so **blank-photo tiles stay blank**.
- **Verified:** 2026-06-19 via `flutter test` on the 3 samples — all names,
  quantities, surface, quality, size correct.

## How to add the next format
1. Get the real PDF(s) (born-digital, text layer; 2–3 samples ideal).
2. Inspect geometry (`PyMuPDF`/`fitz`: words with x/y + image bboxes).
3. Add `_looksLikeXxx` (signature) + `_parseDesignsXxx` (position-based) and a
   branch in the dispatch (place specific signatures before generic ones).
4. Validate with a quick `flutter test` harness, then on-device.
5. Log the sample here.
