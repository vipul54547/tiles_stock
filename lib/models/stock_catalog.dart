/// A stockist's stock "catalog" (the Father & Child model): a stockist (father)
/// can have several catalogs (children) — a public one shown in the marketplace
/// and, when the admin permits, private ones shared only via their own link.
class StockCatalog {
  final String id;
  final String stockistId;
  final String name;
  /// Optional note the stockist keeps to remember what's in the list. (v2)
  final String description;
  /// The list's own banner image (brand-free lists). Empty = none. (v2)
  final String bannerUrl;
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

  /// Stockist hid this list from buyers (they still see + manage it).
  final bool hiddenByStockist;

  /// When non-null, scheduled for hard deletion 24h after this time (cancellable).
  final DateTime? deleteScheduledAt;

  const StockCatalog({
    required this.id,
    required this.stockistId,
    required this.name,
    this.description = '',
    this.bannerUrl = '',
    required this.visibility,
    required this.showInMarketplace,
    required this.shareToken,
    required this.sortOrder,
    required this.isActive,
    this.brandId,
    this.isAnonymous = false,
    this.hiddenByStockist = false,
    this.deleteScheduledAt,
  });

  bool get isPrivate => visibility == 'private';

  /// Deletion countdown running.
  bool get pendingDelete => deleteScheduledAt != null;

  factory StockCatalog.fromJson(Map<String, dynamic> j) => StockCatalog(
        id: j['id'] as String,
        stockistId: j['stockist_id'] as String,
        name: j['name'] as String,
        description: (j['description'] as String?) ?? '',
        bannerUrl: (j['banner_url'] as String?) ?? '',
        visibility: (j['visibility'] as String?) ?? 'public',
        showInMarketplace: j['show_in_marketplace'] as bool? ?? true,
        shareToken: (j['share_token'] as String?) ?? '',
        sortOrder: j['sort_order'] as int? ?? 0,
        isActive: j['is_active'] as bool? ?? true,
        brandId: j['brand_id'] as String?,
        isAnonymous: j['is_anonymous'] as bool? ?? false,
        hiddenByStockist: j['hidden_by_stockist'] as bool? ?? false,
        deleteScheduledAt: j['delete_scheduled_at'] == null
            ? null
            : DateTime.tryParse(j['delete_scheduled_at'].toString())?.toLocal(),
      );
}
