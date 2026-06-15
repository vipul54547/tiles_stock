/// A stockist's stock "catalog" (the Father & Child model): a stockist (father)
/// can have several catalogs (children) — a public one shown in the marketplace
/// and, when the admin permits, private ones shared only via their own link.
class StockCatalog {
  final String id;
  final String stockistId;
  final String name;
  final String visibility; // 'public' | 'private'
  final bool showInMarketplace; // public catalog: appears in the app marketplace
  final String shareToken; // the catalog's own /s/<token> link
  final int sortOrder;
  final bool isActive;
  /// The brand this catalogue belongs to (multi-brand). Null for legacy rows.
  final String? brandId;
  /// Per-list anonymity: when this Discover list is shown publicly, wear the
  /// stockist's masked identity instead of the real name. Only effective when
  /// the stockist is admin-eligible, the list is in Discover, and the market is
  /// live (enforced server-side). Private/non-Discover lists ignore it.
  final bool isAnonymous;

  const StockCatalog({
    required this.id,
    required this.stockistId,
    required this.name,
    required this.visibility,
    required this.showInMarketplace,
    required this.shareToken,
    required this.sortOrder,
    required this.isActive,
    this.brandId,
    this.isAnonymous = false,
  });

  bool get isPrivate => visibility == 'private';

  factory StockCatalog.fromJson(Map<String, dynamic> j) => StockCatalog(
        id: j['id'] as String,
        stockistId: j['stockist_id'] as String,
        name: j['name'] as String,
        visibility: (j['visibility'] as String?) ?? 'public',
        showInMarketplace: j['show_in_marketplace'] as bool? ?? true,
        shareToken: (j['share_token'] as String?) ?? '',
        sortOrder: j['sort_order'] as int? ?? 0,
        isActive: j['is_active'] as bool? ?? true,
        brandId: j['brand_id'] as String?,
        isAnonymous: j['is_anonymous'] as bool? ?? false,
      );
}
