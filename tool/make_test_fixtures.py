"""Generate ready-to-upload test fixtures for the Excel import path.

IMPORTANT: uses xlsxwriter (NOT openpyxl). The app reads .xlsx via the Dart
`excel` package v4.0.6, which does NOT support inline strings. openpyxl writes
text as inline strings (t="inlineStr", no sharedStrings.xml) -> the app throws
"Could not read the Excel file." xlsxwriter uses a shared-string table, which
the `excel` package reads. (tool/inspect_template.py still uses openpyxl to READ.)

Outputs to docs/templates/test_fixtures/:
  * tw_filled.xlsx     — our T/W template, filled to exercise daily-only update,
                         new-design set-once, finish-mismatch map, DNA map, and
                         an invalid row.
  * m_combined.xlsx    — our M template (master + brand cols + wide Premium/
                         Standard), incl. a map-only row and a two-quality row.
  * mock_entry.xlsx    — the M_Stockist "ENTRY.xlsx" desktop export shape: same
                         design across batches (sum), brand in BoxPack (Brand all
                         "--"), GOLD/ECO present (dropped), a "(2PCS)" size note.

Headers match the importer's synonyms / the template exactly so detection works.
Run: python tool/make_test_fixtures.py
"""
import os
import xlsxwriter

OUT_DIR = os.path.join("docs", "templates", "test_fixtures")
os.makedirs(OUT_DIR, exist_ok=True)


def _write(path, sheet, headers, rows):
    wb = xlsxwriter.Workbook(path)
    ws = wb.add_worksheet(sheet)
    head = wb.add_format({"bold": True, "font_color": "white", "bg_color": "#1B4F72"})
    for c, h in enumerate(headers):
        ws.write(0, c, h, head)
        ws.set_column(c, c, max(12, len(str(h)) + 2))
    for r, row in enumerate(rows, 1):
        for c, v in enumerate(row):
            ws.write(r, c, v)
    ws.freeze_panes(1, 0)
    wb.close()


# tw_filled.xlsx — matches the T/W template headers exactly. Admin config assumed
# in the test account: sizes incl 800x1600/600x1200/600x600; finishes None/Matt/
# Glossy/Carving; colours White/Blue/Beige; Look Marble/Wood.
_write(
    os.path.join(OUT_DIR, "tw_filled.xlsx"), "Stock",
    ["Design Name", "Size", "Quality", "Box Qty",
     "Surface", "Tile Type", "Pieces/Box", "Weight (kg)", "Colour", "Look"],
    [
        # daily-only: set-once block blank (existing design -> updates qty only)
        ["Statuario Gold", "800x1600", "Premium", 150, "", "", "", "", "", ""],
        # new design, full set-once + exact dropdown values -> NO map steps
        ["Carrara Blue", "600x1200", "Standard", 80, "Matt", "Porcelain", 4, 24, "Blue", "Marble"],
        # own surface wording (not an admin finish) -> triggers Map Finishes
        ["Onyx Storm", "600x600", "Premium", 40, "glossy finish", "Ceramic", 6, 18, "White", "Wood"],
        # unknown colour word -> triggers Map DNA (learns alias)
        ["Wood Teak", "600x1200", "Standard", 25, "Matt", "Porcelain", 4, 22, "Walnut", "Wood"],
        # invalid size -> row flagged, excluded until fixed
        ["Bad Size", "999x999", "Premium", 10, "Matt", "Ceramic", 5, 20, "White", "Marble"],
    ])

# m_combined.xlsx — matches the M template: master + one col per brand + wide
# Premium/Standard. Brand columns must be the EXACT brand names in the account.
#
# Extended to carry a column for EVERY brand on the test account (cura ceramic =
# the default/main brand named after the stockist, plus BOTTEGA/CERA TILES/ENNFACE)
# AND a junk "ZZ JUNKCOL" column that is NOT a brand → the importer must IGNORE it
# (no alias written). Header matching is case-insensitive (_normHeader lowercases),
# so "cura ceramic" matches the main brand regardless of its stored casing. If the
# account's main brand is named differently, rename that column to match.
_write(
    os.path.join(OUT_DIR, "m_combined.xlsx"), "Stock",
    ["Master Design", "cura ceramic", "BOTTEGA", "CERA TILES", "ENNFACE",
     "ZZ JUNKCOL", "Size",
     "Premium", "Standard", "Surface", "Tile Type", "Pieces/Box", "Weight (kg)",
     "Colour", "Look"],
    [
        # 3 real brand aliases (cura/BOTTEGA/CERA) + a junk col that must be ignored;
        # Premium holding only.
        ["CLOUD ONYX", "Cura Cloud", "Bottega Cloud", "Cera Onyx", "",
         "Junk Cloud", "800x1600",
         252, 0, "Matt", "PGVT & GVT", 3, 35, "White", "Marble"],
        # chosen-brand (e.g. BOTTEGA) cell blank, other brand named -> MAP ONLY (qty 0)
        ["PLAIN KHAKHI", "", "", "", "Enn Khakhi",
         "", "600x1200",
         0, 32, "Glossy", "Porcelain", 4, 24, "Beige", "Wood"],
        # all 4 brand cols filled + both qualities -> 4 aliases, Premium + Standard holdings
        ["DUNE BEIGE", "Cura Dune", "Bottega Dune", "Cera Dune", "Enn Dune",
         "", "600x600",
         100, 50, "Matt", "Ceramic", 6, 18, "Beige", "Marble"],
    ])

# mock_entry.xlsx — the M_Stockist desktop export. Brand col all "--" -> brand
# lives in BoxPack. Same design repeats per batch -> importer SUMs PRE/STD;
# GOLD/ECO dropped; "(2PCS)" stripped from size.
_write(
    os.path.join(OUT_DIR, "mock_entry.xlsx"), "ENTRY",
    ["No", "DesignName", "Product", "Brand", "Size", "Category", "Batch/Shade",
     "BoxPack", "Item Status", "Location", "PRE", "STD", "GOLD", "ECO", "Total",
     "Entry Date"],
    [
        [1, "CLOUD ONYX", "Tile", "--", "800X1600 (2PCS)", "GLOSSY", "260619/-",
         "BOTTEGA", "Active", "A02", 252, 0, 10, 5, 267, "2026-06-19"],
        [2, "CLOUD ONYX", "Tile", "--", "800X1600 (2PCS)", "GLOSSY", "260619/A",
         "PLAIN KHAKHI", "Active", "D-36", 0, 32, 0, 0, 32, "2026-06-19"],
        [3, "DESERT SAND", "Tile", "--", "600X1200", "MATT", "260620/-",
         "CERA TILES", "Active", "B11", 120, 60, 0, 0, 180, "2026-06-20"],
        [4, "DESERT SAND", "Tile", "--", "600X1200", "MATT", "260620/B",
         "ENNFACE", "Active", "C03", 48, 0, 20, 0, 68, "2026-06-20"],
    ])

print("Wrote fixtures to", OUT_DIR)
for f in ("tw_filled.xlsx", "m_combined.xlsx", "mock_entry.xlsx"):
    print("  -", f)
