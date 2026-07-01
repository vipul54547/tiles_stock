/// A stockist's stock "catalog" (the Father & Child model): a stockist (father)
/// can have several catalogs (children) — a public one shown in the marketplace
/// and, when the admin permits, private ones shared only via their own link.
class StockCatalog {
  final String id;
  final String stockistId;
  final String name;
  /// Optional note the stockist keeps to remember what's in the list. (v2)
  final String description;
  /// The list's own banner image (legacy single-image path). Empty = none. (v2)
  final String bannerUrl;
  /// Per-list banner layout (parity with the brand banner). Empty bannerSource
  /// → the list falls back to the brand banner. (project_session_resume #6)
  final String bannerSource;   // '' | 'pool' | 'library' | 'upload'
  final String bannerBgUrl;    // library background or full uploaded banner
  final String companyLogoUrl; // optional brand logo (library path)
  final String companyPos;     // 9-cell placement key, or 'none'
  final String tdPos;          // TilesDesign mark placement key
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

  /// 'permanent' = condition-based auto-updating list.
  /// 'temporary' = manually picked designs via catalog_designs.
  final String listType;
  final String? filterBrandId;
  final String? filterQuality;
  final String? filterSurface;
  final String? filterSize;

  const StockCatalog({
    required this.id,
    required this.stockistId,
    required this.name,
    this.description = '',
    this.bannerUrl = '',
    this.bannerSource = '',
    this.bannerBgUrl = '',
    this.companyLogoUrl = '',
    this.companyPos = 'none',
    this.tdPos = 'footer',
    required this.visibility,
    required this.showInMarketplace,
    required this.shareToken,
    required this.sortOrder,
    required this.isActive,
    this.brandId,
    this.isAnonymous = false,
    this.hiddenByStockist = false,
    this.deleteScheduledAt,
    this.listType = 'permanent',
    this.filterBrandId,
    this.filterQuality,
    this.filterSurface,
    this.filterSize,
  });

  bool get isPrivate => visibility == 'private';
  bool get isPermanent => listType == 'permanent';
  bool get isTemporary => listType == 'temporary';

  /// True when this list carries its own banner (rich layout or legacy image).
  bool get hasOwnBanner => bannerSource.isNotEmpty || bannerUrl.isNotEmpty;

  /// Deletion countdown running.
  bool get pendingDelete => deleteScheduledAt != null;

  factory StockCatalog.fromJson(Map<String, dynamic> j) => StockCatalog(
        id: j['id'] as String,
        stockistId: j['stockist_id'] as String,
        name: j['name'] as String,
        description: (j['description'] as String?) ?? '',
        bannerUrl: (j['banner_url'] as String?) ?? '',
        bannerSource: (j['banner_source'] as String?) ?? '',
        bannerBgUrl: (j['banner_bg_url'] as String?) ?? '',
        companyLogoUrl: (j['company_logo_url'] as String?) ?? '',
        companyPos: (j['company_pos'] as String?) ?? 'none',
        tdPos: (j['td_pos'] as String?) ?? 'footer',
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
        listType: (j['list_type'] as String?) ?? 'permanent',
        filterBrandId: j['filter_brand_id'] as String?,
        filterQuality: j['filter_quality'] as String?,
        filterSurface: j['filter_surface'] as String?,
        filterSize: j['filter_size'] as String?,
      );
}
