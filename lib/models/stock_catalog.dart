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
  /// Optional message banner (Library "text" mode): a short heading + message
  /// overlaid on a text-friendly background. Empty = plain banner.
  final String bannerHeading;
  final String bannerText;
  /// Message text styling (Library "text" mode). Size = 's'|'m'|'l' ('' = medium
  /// default); colour = hex without '#' ('' = white); align = 'left'|'center'
  /// ('' = auto: left with a logo, centred without).
  final String bannerHeadingSize;
  final String bannerHeadingColor;
  final String bannerMsgSize;
  final String bannerMsgColor;
  final String bannerTextAlign;
  final String bannerTextValign; // 'top'|'middle'|'bottom' ('' = middle default)
  final String visibility; // 'public' | 'private'
  final bool showInMarketplace; // public catalog: appears in the app marketplace
  final String shareToken; // the catalog's own /s/<token> link
  final int sortOrder;
  final bool isActive;
  /// The brand this catalogue belongs to (multi-brand). Null for legacy rows.
  final String? brandId;

  /// Stockist hid this list from buyers (they still see + manage it).
  final bool hiddenByStockist;

  /// When non-null, scheduled for hard deletion 24h after this time (cancellable).
  final DateTime? deleteScheduledAt;

  /// 'permanent' = condition-based auto-updating list.
  /// 'temporary' = manually picked designs via catalog_designs.
  final String listType;

  /// Multi-select filters — empty list = no filter (show all).
  final List<String> filterBrandIds;
  final List<String> filterQualities;
  final List<String> filterSurfaces;
  final List<String> filterSizes;
  final List<String> filterTileTypes;
  final List<String> filterStockTypes;

  /// F-stock box range filter — null = no bound.
  final int? filterBoxMin;
  final int? filterBoxMax;

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
    this.bannerHeading = '',
    this.bannerText = '',
    this.bannerHeadingSize = '',
    this.bannerHeadingColor = '',
    this.bannerMsgSize = '',
    this.bannerMsgColor = '',
    this.bannerTextAlign = '',
    this.bannerTextValign = '',
    required this.visibility,
    required this.showInMarketplace,
    required this.shareToken,
    required this.sortOrder,
    required this.isActive,
    this.brandId,
    this.hiddenByStockist = false,
    this.deleteScheduledAt,
    this.listType = 'permanent',
    this.filterBrandIds = const [],
    this.filterQualities = const [],
    this.filterSurfaces = const [],
    this.filterSizes = const [],
    this.filterTileTypes = const [],
    this.filterStockTypes = const [],
    this.filterBoxMin,
    this.filterBoxMax,
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
        bannerHeading: (j['banner_heading'] as String?) ?? '',
        bannerText: (j['banner_text'] as String?) ?? '',
        bannerHeadingSize: (j['banner_heading_size'] as String?) ?? '',
        bannerHeadingColor: (j['banner_heading_color'] as String?) ?? '',
        bannerMsgSize: (j['banner_msg_size'] as String?) ?? '',
        bannerMsgColor: (j['banner_msg_color'] as String?) ?? '',
        bannerTextAlign: (j['banner_text_align'] as String?) ?? '',
        bannerTextValign: (j['banner_text_valign'] as String?) ?? '',
        visibility: (j['visibility'] as String?) ?? 'public',
        showInMarketplace: j['show_in_marketplace'] as bool? ?? true,
        shareToken: (j['share_token'] as String?) ?? '',
        sortOrder: j['sort_order'] as int? ?? 0,
        isActive: j['is_active'] as bool? ?? true,
        brandId: j['brand_id'] as String?,
        hiddenByStockist: j['hidden_by_stockist'] as bool? ?? false,
        deleteScheduledAt: j['delete_scheduled_at'] == null
            ? null
            : DateTime.tryParse(j['delete_scheduled_at'].toString())?.toLocal(),
        listType: (j['list_type'] as String?) ?? 'permanent',
        filterBrandIds:    (j['filter_brand_ids']   as List?)?.cast<String>() ?? const [],
        filterQualities:   (j['filter_qualities']   as List?)?.cast<String>() ?? const [],
        filterSurfaces:    (j['filter_surfaces']    as List?)?.cast<String>() ?? const [],
        filterSizes:       (j['filter_sizes']        as List?)?.cast<String>() ?? const [],
        filterTileTypes:   (j['filter_tile_types']  as List?)?.cast<String>() ?? const [],
        filterStockTypes:  (j['filter_stock_types'] as List?)?.cast<String>() ?? const [],
        filterBoxMin: j['filter_box_min'] as int?,
        filterBoxMax: j['filter_box_max'] as int?,
      );
}
