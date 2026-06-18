/// Stockist business type (the M/T/W "actor type") — a different dimension from
/// the membership tier in [kStockistTiers]. It decides which upload/authoring
/// behaviour a stockist gets:
///   M = Manufacturer (Author)  — invents, names and photographs designs; gets
///       the full authoring toolkit + our structured PDF/Excel/manual inputs.
///   T = Trader                 — importer; ingests an external supplier's
///       arbitrary PDF/Excel (often image-less). Minimal import path only.
///   W = Wholesaler             — importer like T; the only difference is being
///       located outside Morbi, which the app does not care about.
///
/// T and W behave IDENTICALLY in the app (both are "importers"), so code should
/// branch on [isImporterType] / [isAuthorType], never on T-vs-W.
library;

const String kBusinessTypeManufacturer = 'M';
const String kBusinessTypeTrader = 'T';
const String kBusinessTypeWholesaler = 'W';

/// Selectable values in admin UI order, default first.
const List<String> kBusinessTypes = [
  kBusinessTypeManufacturer,
  kBusinessTypeTrader,
  kBusinessTypeWholesaler,
];

/// Human label for a business-type code.
String businessTypeLabel(String? code) {
  switch ((code ?? '').toUpperCase().trim()) {
    case kBusinessTypeManufacturer:
      return 'Manufacturer';
    case kBusinessTypeTrader:
      return 'Trader';
    case kBusinessTypeWholesaler:
      return 'Wholesaler';
    default:
      return 'Manufacturer'; // unknown/empty defaults to author
  }
}

/// A one-line hint for the admin form, explaining what the type unlocks.
String businessTypeHint(String? code) {
  return isImporterType(code)
      ? 'Importer — ingests an external supplier catalogue (PDF/Excel). '
          'Minimal import path; no design-authoring tools.'
      : 'Author — creates and names designs with photos. '
          'Full authoring toolkit + structured upload.';
}

/// True for Trader / Wholesaler — both ingest external supplier files and get
/// the stripped-down import path (T == W).
bool isImporterType(String? code) {
  final c = (code ?? '').toUpperCase().trim();
  return c == kBusinessTypeTrader || c == kBusinessTypeWholesaler;
}

/// True for Manufacturer — the design author with the full toolkit. Empty /
/// unknown is treated as author (the legacy default).
bool isAuthorType(String? code) => !isImporterType(code);
