import 'package:flutter/foundation.dart'; // debugPrint
import '../models/tile_design.dart';
import '../models/stockist.dart';
import '../models/end_user.dart';
import '../models/surface_type.dart';
import '../models/dna.dart';
import '../models/app_notification.dart';
import '../models/tile_size.dart';
import '../models/stock_catalog.dart';
import '../models/share_link.dart';
import '../models/claimed_catalog.dart';
import '../models/brand.dart';
import '../models/inquiry_order.dart';
import '../models/dispatch_record.dart';
import '../models/library_entry.dart';
import '../utils/finishes.dart';
import '../utils/tile_sizes.dart';
import 'supabase_auth_service.dart';
import '../models/choice_state.dart';
import '../main.dart';

/// Normalises a raw PDF surface word for alias matching: uppercase, strip
/// everything but A–Z/0–9. So "Punch Ghr.", "PUNCH-GHR" and "punchghr" all
/// collapse to the same key. Shared by the alias lookup and the learn path.
String normalizeSurfaceRaw(String raw) =>
    raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// Normalises a design NAME into the shared design-image library key: uppercase,
/// A–Z/0–9 only. So "Aquarius Onyx Grey", "AQUARIUS-ONYX GRY"… collapse to the
/// same key. Pairs with [normalizeSizeKey] to identify "the same tile".
String normalizeDesignNameKey(String name) =>
    name.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// Normalises a tile SIZE to its bare WxH dimensions for the library key, so
/// "800x1600 mm", "800X1600", "800 x 1600mm" and "12X18(5)" all collapse to the
/// same "WxH" ("800x1600", "12x18") regardless of units/case/trailing counts.
String normalizeSizeKey(String size) {
  final m = RegExp(r'(\d+)\s*[xX]\s*(\d+)').firstMatch(size);
  if (m != null) return '${m.group(1)}x${m.group(2)}';
  return size.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

/// Joined "nameKey|sizeKey" used as the map key returned by [lookupDesignImages].
String designImageKey(String name, String size) =>
    '${normalizeDesignNameKey(name)}|${normalizeSizeKey(size)}';

class SupabaseDataService {

  // ── helpers ──────────────────────────────────────────────────────────────

  TileDesign _toDesign(Map<String, dynamic> d, {String? seqId}) {
    // Identity (surface/tile_type/stock_type/colour/pieces/weight/thickness/
    // finish/image) lives on the MASTER. Buyer reads (market_designs + RPCs)
    // expose it flat; the stockist's own direct `designs` reads embed it as a
    // nested `stockist_library` object. Source from the master when present.
    // (identity split)
    final lib = d['stockist_library'] is Map
        ? Map<String, dynamic>.from(d['stockist_library'] as Map)
        : null;
    final quality = (d['quality'] ?? 'Standard').toString();
    final baseStock = (lib?['stock_type'] ?? d['stock_type'] ?? 'Uncertain')
        .toString();
    final libImg = (lib?['image_url'] ?? '').toString();
    final faceImages = lib != null
        ? (libImg.isEmpty ? const <String>[] : [libImg])
        : List<String>.from(d['face_image_urls'] ?? const []);
    return TileDesign(
        id:           d['id'],
        name:         d['name'],
        size:         d['size'],
        boxQuantity:  d['box_quantity'] ?? 0,
        surfaceType:  (lib?['surface_type'] ?? d['surface_type'] ?? 'None')
            .toString(),
        finishLabel:  lib?['finish_label'] ?? d['finish_label'],
        piecesPerBox: (lib?['pieces_per_box'] ?? d['pieces_per_box'] ?? 0)
            as int,
        boxWeightKg:  ((lib?['box_weight_kg'] ?? d['box_weight_kg'] ?? 0) as num)
            .toDouble(),
        thicknessMm:  ((lib?['thickness_mm'] ?? d['thickness_mm'] ?? 0) as num)
            .toDouble(),
        colour:       (lib?['colour'] ?? d['colour'] ?? '').toString(),
        tileType:     (lib?['tile_type'] ?? d['tile_type'] ?? '').toString(),
        faceImageUrls: faceImages,
        // market_designs exposes a flat (already-masked) `stockist_key`; the
        // member/stockist `designs` join exposes the nested stockists row.
        stockistId:   d['stockist_key'] ??
            (d['stockists'] != null
                ? (d['stockists']['sequential_id'] ?? seqId ?? '')
                : (seqId ?? '')),
        // Already-masked seller name from market_designs (real or trade name).
        stockistName: d['stockist_display_name'] ??
            (d['stockists'] != null ? (d['stockists']['name'] ?? '') : ''),
        catalogId:    d['catalog_id'] as String?,
        catalogIds:   (d['catalog_ids'] as List?)?.map((e) => e.toString()).toList()
                        ?? const [],
        brandId:      (lib?['brand_id'] ?? d['brand_id'])?.toString(),
        // Brand the design is sold under (market_designs/my_private_designs);
        // masked to null for anonymous public listings. Empty for legacy rows.
        brandName:    d['brand_name'] ?? '',
        updatedAt:  DateTime.parse(d['updated_at']),
        quality:    quality,
        // Flat reads (market_designs/RPCs) already clamp stock_type in SQL; the
        // embedded-master case carries the base value, so clamp it here.
        stockType:  lib != null
            ? effectiveStockType(baseStock, quality)
            : baseStock,
        createdAt:  d['created_at'] != null
            ? DateTime.tryParse(d['created_at'].toString())
            : null,
        // priority comes from the stockists join (members) or the
        // public_designs view's stockist_priority column (guests).
        stockistPriority: ((d['stockists']?['priority'] ??
                d['stockist_priority'] ??
                0) as num)
            .toDouble(),
      );
  }

  // ── designs ───────────────────────────────────────────────────────────────

  // PostgREST embed of a stock row's identity master (designs.library_id ->
  // stockist_library). Identity attributes are read from here, not from the
  // (now dropped) per-row columns. (identity split)
  static const _identityEmbed =
      'stockist_library(surface_type,stock_type,tile_type,pieces_per_box,'
      'box_weight_kg,thickness_mm,colour,finish_label,image_url,brand_id)';

  Future<List<TileDesign>> getAllDesigns() async {
    try {
      // Both guests and members read the masked `market_designs` view: it
      // already filters to active stockists + in-stock, market-visible designs,
      // and exposes a masked `stockist_key`/`stockist_display_name` so an
      // anonymized stockist's real name/id never reaches the buyer client.
      final data = await supabase
          .from('market_designs')
          .select()
          .order('created_at', ascending: false);
      return data.map<TileDesign>((d) => _toDesign(d)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<TileDesign>> getDesignsByStockistSeqId(String seqId) async {
    try {
      // Buyer portfolio reads the masked `market_designs` view, keyed on the
      // (possibly masked) `stockist_key`. The view already filters to active
      // stockists + in-stock, market-visible (public) designs.
      final data = await supabase
          .from('market_designs')
          .select()
          .eq('stockist_key', seqId)
          .order('created_at', ascending: false);
      return data.map<TileDesign>((d) => _toDesign(d)).toList();
    } catch (_) {
      return [];
    }
  }

  /// [inStockOnly] true hides out-of-stock / 0-box designs (buyer portfolio).
  /// The stockist's own dashboard leaves it false so they can see & restock them.
  /// The CALLING stockist's own stock (holdings + identity + list memberships),
  /// via the my_stock RPC. The [stockistUUID] arg is retained for call-site
  /// compatibility but the RPC always scopes to the authenticated stockist.
  /// [inStockOnly] hides 0-box holdings. (stocklist-output)
  Future<List<TileDesign>> getDesignsByStockist(String stockistUUID,
      {bool inStockOnly = false}) async {
    try {
      final res = await supabase.rpc('my_stock');
      final list = (res as List?) ?? const [];
      var out = list
          .map((e) => _toStockDesign(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (inStockOnly) {
        out = out.where((d) => d.boxQuantity > 0).toList();
      }
      return out;
    } catch (e, st) {
      debugPrint('SupabaseDataService.getDesignsByStockist failed: $e\n$st');
      return [];
    }
  }

  // Maps a my_stock() row → TileDesign. Identity is flat here and stock_type is
  // the BASE value, so it's clamped by the holding's quality. (stocklist-output)
  TileDesign _toStockDesign(Map<String, dynamic> d) {
    final img = (d['image_url'] ?? '').toString();
    final quality = (d['quality'] ?? 'Standard').toString();
    return TileDesign(
      id:           d['id'],
      name:         d['name'] ?? d['master_design_name'] ?? '',
      size:         d['size'] ?? '',
      boxQuantity:  d['box_quantity'] ?? 0,
      controlQuantity: (d['control_quantity'] as num?)?.toInt() ?? 0,
      fStock:       (d['f_stock'] as num?)?.toInt(),
      surfaceType:  (d['surface_type'] ?? 'None').toString(),
      finishLabel:  d['finish_label'] as String?,
      piecesPerBox: (d['pieces_per_box'] ?? 0) as int,
      boxWeightKg:  ((d['box_weight_kg'] ?? 0) as num).toDouble(),
      thicknessMm:  ((d['thickness_mm'] ?? 0) as num).toDouble(),
      colour:       (d['colour'] ?? '').toString(),
      tileType:     (d['tile_type'] ?? '').toString(),
      faceImageUrls: img.isEmpty ? const [] : [img],
      stockistId:   (d['stockist_key'] ?? '').toString(),
      catalogIds:   (d['catalog_ids'] as List?)?.map((e) => e.toString()).toList()
                      ?? const [],
      brandId:      d['brand_id']?.toString(),
      libraryId:    (d['library_id'] ?? '').toString(),
      masterDesignName: (d['master_design_name'] ?? '').toString(),
      updatedAt:    DateTime.parse(d['updated_at']),
      quality:      quality,
      stockType:    effectiveStockType((d['stock_type'] ?? 'Uncertain').toString(), quality),
      createdAt:    d['created_at'] != null
          ? DateTime.tryParse(d['created_at'].toString())
          : null,
      stockistPriority: ((d['stockist_priority'] ?? 0) as num).toDouble(),
    );
  }

  /// Save C_Quantity (control / hold-back) for one or more holdings. [items] =
  /// list of {id, control_quantity}. Returns the number of rows updated. Owner
  /// enforced server-side. F_Stock is recomputed from this. (project_fstock_model)
  Future<int> setControlQuantities(
      List<({String id, int controlQuantity})> items) async {
    final payload = items
        .map((e) => {'id': e.id, 'control_quantity': e.controlQuantity})
        .toList();
    final res = await supabase
        .rpc('set_control_quantities', params: {'p_items': payload});
    return (res as num?)?.toInt() ?? 0;
  }

  Future<List<TileDesign>> searchDesigns({
    String? stockistSequentialId,
    List<String>? sizes,
    List<String>? surfaceTypes,
    List<String>? colours,
    List<String>? qualities,
    List<String>? tileTypes,
    String? stockType,
    int? minQty,
    int? maxQty,
  }) async {
    try {
      // Guests and members both read the masked `market_designs` view. Filter
      // by stockist on the masked `stockist_key` (no base-table UUID lookup —
      // that would leak the real id), which also accepts a masked public code.
      var query = supabase.from('market_designs').select();
      if (stockistSequentialId != null) {
        query = query.eq('stockist_key', stockistSequentialId);
      }
      if (sizes        != null && sizes.isNotEmpty)        query = query.inFilter('size',         sizes);
      if (surfaceTypes != null && surfaceTypes.isNotEmpty) query = query.inFilter('surface_type',  surfaceTypes);
      if (colours      != null && colours.isNotEmpty)      query = query.inFilter('colour',        colours);
      if (qualities    != null && qualities.isNotEmpty)    query = query.inFilter('quality',       qualities);
      if (tileTypes    != null && tileTypes.isNotEmpty)    query = query.inFilter('tile_type',     tileTypes);
      if (stockType    != null && stockType != 'All')      query = query.eq('stock_type',          stockType);
      if (minQty       != null)                            query = query.gte('box_quantity',        minQty);
      if (maxQty       != null)                            query = query.lte('box_quantity',        maxQty);

      final data = await query.order('created_at', ascending: false);
      return data.map<TileDesign>((d) => _toDesign(d)).toList();
    } catch (_) {
      return [];
    }
  }

  /// Adds stock for a Library design: upserts the holding by
  /// (stockist, library_id, quality), publishes it into [catalogId] (membership),
  /// and logs the stock-in. Identity lives on the master. (stocklist-output)
  Future<String?> addDesign({
    required String libraryId,
    required String quality,
    required int    boxQuantity,
    String? catalogId,
  }) async {
    try {
      final res = await supabase.rpc('stock_add_holding', params: {
        'p_library_id': libraryId,
        'p_quality':    quality,
        'p_qty':        boxQuantity,
        'p_catalog_id': catalogId,
      });
      return res?.toString();
    } catch (e, st) {
      debugPrint('SupabaseDataService.addDesign failed ($libraryId): $e\n$st');
      return null;
    }
  }

  Future<TileDesign?> getDesignById(String id) async {
    try {
      final data = await supabase
          .from('designs')
          .select('*, $_identityEmbed, stockists(sequential_id)')
          .eq('id', id)
          .single();
      return _toDesign(data);
    } catch (_) {
      return null;
    }
  }

  /// The lists a design is eligible for (every active list whose brand carries it)
  /// each with a `member` flag. Keyed by the holding id. (stocklist-output)
  Future<List<Map<String, dynamic>>> getDesignLists(String designId) async {
    try {
      final res = await supabase
          .rpc('design_lists', params: {'p_design_id': designId});
      return ((res as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e, st) {
      debugPrint('getDesignLists failed ($designId): $e\n$st');
      return [];
    }
  }

  /// Sets exactly which lists a design is published in (membership). Only the
  /// caller's own eligible lists are affected. (stocklist-output)
  Future<bool> setDesignLists(String designId, List<String> catalogIds) async {
    try {
      await supabase.rpc('set_design_lists',
          params: {'p_design_id': designId, 'p_catalog_ids': catalogIds});
      return true;
    } catch (e, st) {
      debugPrint('setDesignLists failed ($designId): $e\n$st');
      return false;
    }
  }

  Future<bool> updateDesign(String designId, Map<String, dynamic> data) async {
    try {
      await supabase.from('designs').update(data).eq('id', designId);
      return true;
    } catch (e, st) {
      debugPrint('SupabaseDataService.updateDesign failed ($designId): $e\n$st');
      return false;
    }
  }

  Future<bool> deleteDesign(String designId) async {
    try {
      await supabase.from('designs').delete().eq('id', designId);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── stock catalogs (Father & Child) ────────────────────────────────────────

  /// Log an anonymous enquiry made through a share link (login-free web
  /// catalog). Best-effort — silently ignores failures.
  Future<void> logLinkInquiry(String token, List<String> designIds) async {
    try {
      await supabase.rpc('log_link_inquiry',
          params: {'p_token': token, 'p_design_ids': designIds});
    } catch (e, st) {
      debugPrint('logLinkInquiry failed: $e\n$st');
    }
  }

  /// Per-catalog link-enquiry counts for a stockist (catalogId → count).
  /// Stockist-level link enquiries (no catalog) bucket under the key ''.
  Future<Map<String, int>> getCatalogInquiryCounts(String stockistUUID) async {
    try {
      final rows = await supabase
          .from('link_inquiries')
          .select('catalog_id')
          .eq('stockist_id', stockistUUID);
      final out = <String, int>{};
      for (final r in rows) {
        final k = (r['catalog_id'] as String?) ?? '';
        out[k] = (out[k] ?? 0) + 1;
      }
      return out;
    } catch (e, st) {
      debugPrint('getCatalogInquiryCounts failed: $e\n$st');
      return {};
    }
  }

  /// Whether this stockist may create PRIVATE catalogs (admin-granted).
  Future<bool> canCreatePrivate(String stockistUUID) async {
    try {
      final s = await supabase
          .from('stockists')
          .select('can_create_private_catalog')
          .eq('id', stockistUUID)
          .maybeSingle();
      return s?['can_create_private_catalog'] as bool? ?? false;
    } catch (_) {
      return false;
    }
  }

  /// The calling stockist's admin-set stock-list limit (per brand). Default 3.
  Future<int> myStockListLimit() async {
    try {
      final uid = supabase.auth.currentUser?.id;
      if (uid == null) return 3;
      final s = await supabase
          .from('stockists')
          .select('stock_list_limit')
          .eq('user_id', uid)
          .maybeSingle();
      return (s?['stock_list_limit'] as int?) ?? 3;
    } catch (_) {
      return 3;
    }
  }

  /// A stockist's stock lists (catalogs), in display order.
  Future<List<StockCatalog>> getCatalogs(String stockistUUID) async {
    try {
      final data = await supabase
          .from('stock_catalogs')
          .select()
          .eq('stockist_id', stockistUUID)
          .order('sort_order', ascending: true)
          .order('created_at', ascending: true);
      return data.map<StockCatalog>((c) => StockCatalog.fromJson(c)).toList();
    } catch (e, st) {
      debugPrint('getCatalogs failed ($stockistUUID): $e\n$st');
      return [];
    }
  }

  // ── brands (multi-brand) ────────────────────────────────────────────────────

  /// The calling stockist's brands (with catalogue counts).
  Future<List<Brand>> getMyBrands() async {
    try {
      final res = await supabase.rpc('my_brands');
      final list = (res as List?) ?? const [];
      return list
          .map((e) => Brand.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (e, st) {
      debugPrint('getMyBrands failed: $e\n$st');
      return [];
    }
  }

  /// Stockist creates a brand (server enforces the admin-set brand_limit).
  /// Returns the new brand id. Throws the server message on failure.
  Future<String> createBrand(String name) async {
    try {
      final res = await supabase.rpc('create_brand', params: {'p_name': name});
      return (res ?? '').toString();
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  Future<void> renameBrand(String id, String name) async {
    try {
      await supabase.rpc('rename_brand', params: {'p_id': id, 'p_name': name});
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  // ── stockist Design Library ─────────────────────────────────────────────────
  // Per-stockist master designs (image + per-brand design-name aliases). The
  // single source of truth for a design's identity/photo; never borrows across
  // stockists. (project_stockist_library)

  /// This stockist's full design library (masters + their per-brand aliases).
  Future<List<LibraryEntry>> getMyLibrary() async {
    try {
      final res = await supabase.rpc('my_library');
      final list = (res as List?) ?? const [];
      return list
          .map((e) => LibraryEntry.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (e, st) {
      debugPrint('getMyLibrary failed: $e\n$st');
      return [];
    }
  }

  /// Creates ([id] null) or updates a master design + replaces its per-brand
  /// aliases. [aliases] = brandId -> design name (blank names are dropped).
  /// Returns the master id. Throws the server message on failure.
  Future<String> upsertLibraryMaster({
    String? id,
    required String size,
    required String masterName,
    String imageUrl = '',
    String? brandId,
    Map<String, String> aliases = const {},
    // Identity attributes — pass to set/overwrite them on the master. Leave null
    // to keep the existing values (e.g. the Change-image flow). (identity split)
    String? surfaceType,
    String? stockType,
    String? tileType,
    int? piecesPerBox,
    double? boxWeightKg,
    double? thicknessMm,
    String? colour,
    String? finishLabel,
  }) async {
    final aliasJson = aliases.entries
        .where((e) => e.value.trim().isNotEmpty)
        .map((e) => {'brand_id': e.key, 'name': e.value.trim()})
        .toList();
    try {
      final res = await supabase.rpc('library_upsert_master', params: {
        'p_id': id,
        'p_size': size,
        'p_master_name': masterName,
        'p_image_url': imageUrl,
        'p_aliases': aliasJson,
        'p_brand_id': brandId,
        'p_surface': surfaceType,
        'p_stock_type': stockType,
        'p_tile_type': tileType,
        'p_pieces': piecesPerBox,
        'p_weight': boxWeightKg,
        'p_thickness': thicknessMm,
        'p_colour': colour,
        'p_finish': finishLabel,
      });
      return (res ?? '').toString();
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Admin-on-behalf library upsert for the bulk image-folder import. Creates or
  /// matches a master for stockist [seq] (sequential_id); always sets the brand
  /// alias = [masterName] under [brandId] (so the design carries its name in that
  /// brand). Admin-role enforced server-side (admin_library_upsert).
  Future<String> adminLibraryUpsert({
    required String seq,
    required String size,
    required String masterName,
    required String brandId,
    String imageUrl = '',
    String? surface,
    String? tileType,
    int? pieces,
    double? weight,
    double? thickness,
    Map<String, String>? aliases,
  }) async {
    final a = (aliases ?? {brandId: masterName})
        .entries
        .where((e) => e.value.trim().isNotEmpty)
        .map((e) => {'brand_id': e.key, 'name': e.value.trim()})
        .toList();
    try {
      final res = await supabase.rpc('admin_library_upsert', params: {
        'p_seq': seq,
        'p_size': size,
        'p_master_name': masterName,
        'p_brand_id': brandId,
        'p_image_url': imageUrl,
        'p_surface': surface,
        'p_tile_type': tileType,
        'p_pieces': pieces,
        'p_weight': weight,
        'p_thickness': thickness,
        'p_aliases': a,
      });
      return (res ?? '').toString();
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  Future<void> deleteLibraryMaster(String id) async {
    try {
      await supabase.rpc('library_delete_master', params: {'p_id': id});
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Merge two same-size library masters: [dropId]'s brand aliases, DNA and (if
  /// the kept one has none) image move onto [keepId], then [dropId] is deleted.
  /// Lossless — stock rows have no FK to masters so they're untouched. Throws the
  /// server message (e.g. size mismatch / not yours). See library_merge_masters.
  Future<void> mergeLibraryMasters(
      {required String keepId, required String dropId}) async {
    try {
      await supabase.rpc('library_merge_masters',
          params: {'p_keep_id': keepId, 'p_drop_id': dropId});
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Auto-fill lookup: this stockist's own master image for (brand, design name,
  /// size), or null when the design isn't in their library. Used by stock uploads
  /// so an image is only ever shown when the stockist owns it.
  Future<String?> libraryImageFor(
      String brandId, String name, String size) async {
    try {
      final res = await supabase.rpc('library_image_for',
          params: {'p_brand_id': brandId, 'p_name': name, 'p_size': size});
      final url = (res ?? '').toString();
      return url.isEmpty ? null : url;
    } catch (e) {
      debugPrint('libraryImageFor failed: $e');
      return null;
    }
  }

  /// Contributes a freshly-uploaded photo to THIS stockist's own library on a
  /// blank/new design add (PDF row or camera). First-writer-wins — an existing
  /// master image is never overwritten. Resolves/creates the master by the
  /// brand's design name + size and ensures the brand alias. Never borrows or
  /// touches another stockist's library. No-op on empty key/url.
  Future<void> libraryContribute({
    required String brandId,
    required String name,
    required String size,
    required String imageUrl,
  }) async {
    if (brandId.isEmpty || name.trim().isEmpty || size.trim().isEmpty) return;
    try {
      await supabase.rpc('library_contribute', params: {
        'p_brand_id': brandId,
        'p_name': name,
        'p_size': size,
        'p_image_url': imageUrl,
      });
    } catch (e) {
      debugPrint('libraryContribute failed ("$name"): $e');
    }
  }

  /// Mapping-Excel bulk hook: resolves/creates a master by (master name + size)
  /// and MERGES the given per-brand aliases (brandId -> design name) in without
  /// deleting existing ones. Returns the master id. Throws the server message.
  Future<String> libraryMapUpsert({
    required String size,
    required String masterName,
    Map<String, String> aliases = const {},
    // M box identity = master + surface; 'None' is a wildcard the server absorbs.
    String surface = 'None',
  }) async {
    final aliasJson = aliases.entries
        .where((e) => e.value.trim().isNotEmpty)
        .map((e) => {'brand_id': e.key, 'name': e.value.trim()})
        .toList();
    try {
      final res = await supabase.rpc('library_map_upsert', params: {
        'p_size': size,
        'p_master_name': masterName,
        'p_aliases': aliasJson,
        'p_surface': surface.trim().isEmpty ? 'None' : surface.trim(),
      });
      return (res ?? '').toString();
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Sets a brand's logo (Cloudinary URL); pass '' to clear.
  Future<void> setBrandLogo(String id, String logoUrl) async {
    try {
      await supabase
          .rpc('set_brand_logo', params: {'p_id': id, 'p_logo': logoUrl});
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  Future<void> setBrandActive(String id, bool active) async {
    try {
      await supabase
          .rpc('set_brand_active', params: {'p_id': id, 'p_active': active});
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Admin: set a stockist's brand limit (by display/sequential id).
  Future<void> setBrandLimit(String sequentialId, int limit) async {
    await supabase.rpc('admin_set_brand_limit',
        params: {'p_seq': sequentialId, 'p_limit': limit});
  }

  /// Admin: set how many stock lists per brand a stockist may create.
  /// (Stockist-wide; superseded by the per-brand limit below — kept for safety.)
  Future<void> setStockListLimit(String sequentialId, int limit) async {
    await supabase.rpc('admin_set_stock_list_limit',
        params: {'p_seq': sequentialId, 'p_limit': limit});
  }

  /// Admin: a stockist's brands with each brand's per-brand stock-list limit and
  /// its current list names. Rows: {id, name, is_default, stock_list_limit,
  /// list_count, list_names}.
  Future<List<Map<String, dynamic>>> adminStockistBrands(
      String sequentialId) async {
    try {
      final res = await supabase
          .rpc('admin_stockist_brands', params: {'p_seq': sequentialId});
      return ((res as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e, st) {
      debugPrint('adminStockistBrands failed: $e\n$st');
      return [];
    }
  }

  /// Admin: a target stockist's library keys (master name + size + brand) for the
  /// bulk-import preview's NEW vs already-in-library flag. Admin-role enforced.
  Future<List<Map<String, dynamic>>> adminStockistLibrary(
      String sequentialId) async {
    try {
      final res = await supabase
          .rpc('admin_stockist_library', params: {'p_seq': sequentialId});
      return ((res as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e, st) {
      debugPrint('adminStockistLibrary failed: $e\n$st');
      return [];
    }
  }

  /// Admin: set one brand's stock-list limit; the brand auto-fills its lists up
  /// to the new number (never deletes).
  Future<void> setBrandStockListLimit(String brandId, int limit) async {
    await supabase.rpc('admin_set_brand_stock_list_limit',
        params: {'p_brand_id': brandId, 'p_limit': limit});
  }

  /// Admin: set a brand's moderation status — 'live' (all see), 'correction'
  /// (stockist sees to fix, buyers don't) or 'off' (hidden; non-default only).
  Future<void> setBrandStatus(String brandId, String status) async {
    try {
      await supabase.rpc('admin_set_brand_status',
          params: {'p_brand_id': brandId, 'p_status': status});
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Admin: permanently delete a (non-default) brand + its stock lists; frees a
  /// brand slot.
  Future<void> deleteBrand(String brandId) async {
    try {
      await supabase.rpc('admin_delete_brand', params: {'p_brand_id': brandId});
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Stockist: hide/show their own NON-DEFAULT brand from buyers (they keep
  /// seeing + managing it). Showing also cancels any pending deletion.
  Future<void> setBrandHidden(String brandId, bool hidden) async {
    try {
      await supabase.rpc('stockist_set_brand_hidden',
          params: {'p_brand_id': brandId, 'p_hidden': hidden});
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Stockist: start the 24h deletion countdown on a hidden, non-default brand.
  /// Returns when it was scheduled (deletion runs 24h later; cancellable).
  Future<DateTime> scheduleBrandDelete(String brandId) async {
    try {
      final res = await supabase.rpc('stockist_schedule_brand_delete',
          params: {'p_brand_id': brandId});
      return DateTime.parse(res.toString()).toLocal();
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Stockist: cancel a pending brand deletion (the "last chance" stop).
  Future<void> cancelBrandDelete(String brandId) async {
    try {
      await supabase.rpc('stockist_cancel_brand_delete',
          params: {'p_brand_id': brandId});
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Stockist: hide/show one of their own stock lists from buyers (they keep
  /// managing it). Showing cancels any pending deletion.
  Future<void> setListHidden(String catalogId, bool hidden) async {
    try {
      await supabase.rpc('stockist_set_list_hidden',
          params: {'p_catalog_id': catalogId, 'p_hidden': hidden});
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Stockist: start the 24h deletion countdown on a hidden stock list. After it
  /// fires the list (and its stock) is wiped and an empty replacement is seeded.
  Future<DateTime> scheduleListDelete(String catalogId) async {
    try {
      final res = await supabase.rpc('stockist_schedule_list_delete',
          params: {'p_catalog_id': catalogId});
      return DateTime.parse(res.toString()).toLocal();
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Stockist: cancel a pending stock-list deletion (the "last chance" stop).
  Future<void> cancelListDelete(String catalogId) async {
    try {
      await supabase.rpc('stockist_cancel_list_delete',
          params: {'p_catalog_id': catalogId});
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Admin: add ONE brand to a stockist directly (the "+ Add brand" button).
  /// Blank name → server defaults to "Brand N". Returns the new brand id.
  Future<String> addBrandForStockist(String sequentialId, String name) async {
    try {
      final res = await supabase.rpc('admin_add_brand',
          params: {'p_seq': sequentialId, 'p_name': name});
      return (res ?? '').toString();
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Admin: set a brand's banner overlay config. [source] = pool | library |
  /// upload; [bgUrl] = library background or full uploaded banner; [companyLogoUrl]
  /// = uploaded brand logo (library path); [companyPos]/[tdPos] = placement keys.
  Future<void> setBrandBannerConfig(
    String brandId, {
    required String source,
    String bgUrl = '',
    String companyLogoUrl = '',
    String companyPos = 'none',
    String tdPos = 'footer',
  }) async {
    try {
      await supabase.rpc('admin_set_brand_banner_config', params: {
        'p_brand_id': brandId,
        'p_source': source,
        'p_bg_url': bgUrl,
        'p_company_logo_url': companyLogoUrl,
        'p_company_pos': companyPos,
        'p_td_pos': tdPos,
      });
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Stockist creates a stock list under a brand (server enforces the admin-set
  /// stock_list_limit per brand). Returns the new list id. Throws the server
  /// message on failure.
  Future<String> createStockList(String brandId, String name) async {
    try {
      final res = await supabase.rpc('create_stock_list',
          params: {'p_brand_id': brandId, 'p_name': name});
      return (res ?? '').toString();
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// The stockist's default public catalog (the one new uploads target by
  /// default) — the lowest-sorted public catalog.
  Future<StockCatalog?> defaultCatalog(String stockistUUID) async {
    final all = await getCatalogs(stockistUUID);
    for (final c in all) {
      if (!c.isPrivate && c.isActive) return c;
    }
    return all.isEmpty ? null : all.first;
  }

  Future<void> renameCatalog(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw 'Stock catalogue name cannot be empty.';
    await supabase.from('stock_catalogs').update({'name': trimmed}).eq('id', id);
  }

  /// Toggle a PUBLIC catalog's marketplace visibility (the "show in app" switch).
  Future<void> setCatalogMarketplace(String id, bool show) async {
    await supabase
        .from('stock_catalogs')
        .update({'show_in_marketplace': show}).eq('id', id);
  }

  /// Per-list anonymity: when this Discover list is shown publicly, wear the
  /// stockist's masked identity instead of the real name. Only meaningful for
  /// admin-eligible stockists' Discover lists (server enforces the full rule).
  Future<void> setCatalogAnonymous(String id, bool anonymous) async {
    await supabase
        .from('stock_catalogs')
        .update({'is_anonymous': anonymous}).eq('id', id);
  }

  // ── Catalog banners (admin-controlled) ──────────────────────────────────────
  /// Admin: the generic/anonymous banner pool (shown on anonymous lists + as the
  /// fallback, daily-rotated). Newest first.
  Future<List<Map<String, dynamic>>> getGenericBanners() async {
    try {
      final data = await supabase
          .from('banners')
          .select('id, image_url, is_active, created_at')
          .eq('kind', 'generic')
          .order('created_at', ascending: false);
      return data
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (e, st) {
      debugPrint('getGenericBanners failed: $e\n$st');
      return [];
    }
  }

  /// Admin: add a banner to the generic/anonymous pool (Cloudinary URL).
  Future<void> addGenericBanner(String imageUrl) async {
    await supabase
        .from('banners')
        .insert({'image_url': imageUrl, 'kind': 'generic'});
  }

  Future<void> setBannerActive(String id, bool active) async {
    await supabase.from('banners').update({'is_active': active}).eq('id', id);
  }

  Future<void> deleteBanner(String id) async {
    await supabase.from('banners').delete().eq('id', id);
  }

  /// Admin: a stockist's brands with each brand's assigned banner + settings.
  /// Returns {stockist_name, brands:[{brand_id,name,is_default,use_pool_banner,
  /// website_url,banner_url}]} or null if the stockist isn't found.
  Future<Map<String, dynamic>?> adminStockistBannerSlots(String seq) async {
    try {
      final res =
          await supabase.rpc('admin_stockist_banner_slots', params: {'p_seq': seq});
      if (res == null) return null;
      return Map<String, dynamic>.from(res as Map);
    } catch (e, st) {
      debugPrint('adminStockistBannerSlots($seq) failed: $e\n$st');
      return null;
    }
  }

  Future<void> adminSetBrandBanner(String brandId, String imageUrl) =>
      supabase.rpc('admin_set_brand_banner',
          params: {'p_brand_id': brandId, 'p_image_url': imageUrl});

  Future<void> adminClearBrandBanner(String brandId) =>
      supabase.rpc('admin_clear_brand_banner', params: {'p_brand_id': brandId});

  Future<void> adminSetBrandUsePool(String brandId, bool use) =>
      supabase.rpc('admin_set_brand_use_pool',
          params: {'p_brand_id': brandId, 'p_use': use});

  Future<void> adminSetBrandWebsite(String brandId, String url) =>
      supabase.rpc('admin_set_brand_website',
          params: {'p_brand_id': brandId, 'p_url': url});

  Future<void> setCatalogActive(String id, bool active) async {
    await supabase
        .from('stock_catalogs')
        .update({'is_active': active}).eq('id', id);
  }

  Future<void> deleteCatalog(String id) async {
    await supabase.from('stock_catalogs').delete().eq('id', id);
  }

  // ── Father & Child Phase 2: claim/bind (buyer's Closed Market) ──────────────

  /// Buyer claims a catalog from any share token (catalog / stockist permanent /
  /// create-on-demand link). On success the catalog binds into the buyer's
  /// Private (Closed Market) tab. Returns the claimed catalog summary; throws a
  /// plain message string on failure (invalid link, not a buyer, inactive).
  Future<Map<String, dynamic>> claimCatalog(String token) async {
    final t = token.trim();
    if (t.isEmpty) throw 'Paste a stock catalogue link first.';
    // Accept a full link (…/s/<token> or …/#/s/<token>) or a bare token.
    final match = RegExp(r'/s/([A-Za-z0-9]+)').firstMatch(t);
    final resolved = match != null ? match.group(1)! : t;
    try {
      final res = await supabase.rpc('claim_catalog', params: {'p_token': resolved});
      return Map<String, dynamic>.from(res as Map);
    } catch (e) {
      // Surface the RPC's raise-exception message cleanly to the UI.
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Buyer: the catalogs they've claimed (the Closed Market list).
  Future<List<ClaimedCatalog>> getMyClaimedCatalogs() async {
    try {
      final res = await supabase.rpc('my_claimed_catalogs');
      final list = (res as List?) ?? const [];
      return list
          .map((e) => ClaimedCatalog.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (e, st) {
      debugPrint('getMyClaimedCatalogs failed: $e\n$st');
      return [];
    }
  }

  /// Buyer: designs from all their claimed catalogs (the Private tab grid).
  /// Returned in the same masked shape as the open market, so anonymity holds.
  Future<List<TileDesign>> getMyPrivateDesigns() async {
    try {
      final res = await supabase.rpc('my_private_designs');
      final list = (res as List?) ?? const [];
      return list
          .map<TileDesign>((d) => _toDesign(Map<String, dynamic>.from(d as Map)))
          .toList();
    } catch (e, st) {
      debugPrint('getMyPrivateDesigns failed: $e\n$st');
      return [];
    }
  }

  /// Stockist: buyers who have claimed the calling stockist's catalogs.
  Future<List<CatalogClaimer>> getMyCatalogClaimers() async {
    try {
      final res = await supabase.rpc('my_catalog_claimers');
      final list = (res as List?) ?? const [];
      return list
          .map((e) => CatalogClaimer.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (e, st) {
      debugPrint('getMyCatalogClaimers failed: $e\n$st');
      return [];
    }
  }

  /// Stockist: revoke a buyer's access to one of the stockist's catalogs.
  Future<void> revokeCatalogAccess(String catalogId, String endUserId) async {
    await supabase.rpc('revoke_catalog_access',
        params: {'p_catalog_id': catalogId, 'p_end_user_id': endUserId});
  }

  /// Buyer: remove one of their own saved (claimed) catalogs from the Private
  /// market. Deactivates the access row; re-claiming the link restores it.
  Future<void> unclaimCatalog(String catalogId) async {
    await supabase.rpc('unclaim_catalog', params: {'p_catalog_id': catalogId});
  }

  // ── stockists ─────────────────────────────────────────────────────────────

  /// All stockists (admin only). [activeOnly] true keeps just active ones;
  /// admin management passes false to also see deactivated ones.
  ///
  /// Uses the admin-only `admin_list_stockists` RPC (mirrors end users) so each
  /// row carries the login [email] from auth.users — which the client can't
  /// read by querying the `stockists` table directly.
  Future<List<Stockist>> getAllStockists({bool activeOnly = true}) async {
    if (isGuest) return []; // guests never receive stockist data
    try {
      final res = await supabase.rpc('admin_list_stockists');
      final list = (res as List?) ?? const [];
      var stockists = list
          .map<Stockist>((s) => _toStockist(Map<String, dynamic>.from(s as Map)))
          .toList();
      if (activeOnly) {
        stockists = stockists.where((s) => s.isActive).toList();
      }
      return stockists;
    } catch (e, st) {
      debugPrint('getAllStockists failed: $e\n$st');
      return [];
    }
  }

  /// Buyer-facing stockist directory (masked). Reads the `buyer_stockists`
  /// view so an anonymized stockist surfaces as its trade name + public code;
  /// the real name/sequential id never reach the buyer. Buyer screens (groups,
  /// My Choice, portfolio, home, overview) use this instead of [getAllStockists].
  Future<List<Stockist>> getMarketStockists() async {
    if (isGuest) return [];
    try {
      final data = await supabase
          .from('buyer_stockists')
          .select()
          .eq('is_active', true)
          .order('sequential_id');
      return data.map<Stockist>((s) => _toStockist(s)).toList();
    } catch (_) {
      return [];
    }
  }

  /// Resolves a stockist key (a real sequential_id OR an anonymous public_code)
  /// to the stockist's stable uuid. Used to match saved keys (which may be a code
  /// or a real id depending on the market mode at save time) against the current
  /// display. Returns null if the key resolves to no stockist (e.g. deleted).
  Future<String?> resolveStockistKey(String key) async {
    try {
      final res = await supabase.rpc('resolve_stockist_key', params: {'p_key': key});
      final s = res?.toString() ?? '';
      return s.isEmpty ? null : s;
    } catch (_) {
      return null;
    }
  }

  /// Admin: update a stockist's editable fields (keyed by sequential id).
  Future<void> updateStockist({
    required String sequentialId,
    required String name,
    String phone = '',
    String countryCode = '+91',
    String city = '',
    String state = '',
    String address = '',
    String gstNumber = '',
    String stockistType = '',
    double priority = 0,
  }) async {
    await supabase.rpc('admin_update_stockist', params: {
      'p_seq':           sequentialId,
      'p_name':          name,
      'p_phone':         phone,
      'p_country_code':  countryCode,
      'p_city':          city,
      'p_state':         state,
      'p_address':       address,
      'p_gst':           gstNumber,
      'p_stockist_type': stockistType,
      'p_priority':      priority,
    });
  }

  /// Admin: hard-delete a stockist (must be deactivated first).
  Future<void> deleteStockist(String sequentialId) async {
    await supabase.rpc('admin_delete_stockist', params: {'p_seq': sequentialId});
  }

  /// Admin: set whether a stockist appears in the public in-app market
  /// (false = link-only / private; still reachable via their share link).
  Future<void> setStockistListed(String sequentialId, bool listed) async {
    await supabase.rpc('admin_set_stockist_listed',
        params: {'p_seq': sequentialId, 'p_is_listed': listed});
  }

  /// Admin: set a stockist's business / actor type ('M' Manufacturer/Author,
  /// 'T' Trader, 'W' Wholesaler). Decides the upload behaviour (author vs
  /// importer). Separate from the tier in [updateStockist]'s stockistType.
  Future<void> setStockistBusinessType(String sequentialId, String type) async {
    await supabase.rpc('admin_set_business_type',
        params: {'p_seq': sequentialId, 'p_type': type});
  }

  // ── Design DNA (dynamic searchable attributes) ──────────────────────────────

  /// The whole DNA catalog: attributes (active) each with their active values.
  Future<List<DnaAttribute>> dnaCatalog() async {
    try {
      final res = await supabase.rpc('dna_catalog');
      final list = (res as List?) ?? const [];
      return list
          .map((a) => DnaAttribute.fromJson(Map<String, dynamic>.from(a as Map)))
          .toList();
    } catch (e) {
      debugPrint('dnaCatalog failed: $e');
      return [];
    }
  }

  Future<void> adminDnaAddAttribute(String name,
      {bool isMulti = false, bool isFreeText = false}) async {
    await supabase.rpc('admin_dna_add_attribute', params: {
      'p_name': name,
      'p_is_multi': isMulti,
      'p_is_free_text': isFreeText,
    });
  }

  Future<void> adminDnaUpdateAttribute(String id,
      {String? name, bool? isActive}) async {
    await supabase.rpc('admin_dna_update_attribute',
        params: {'p_id': id, 'p_name': name, 'p_is_active': isActive});
  }

  Future<void> adminDnaDeleteAttribute(String id) async {
    await supabase.rpc('admin_dna_delete_attribute', params: {'p_id': id});
  }

  Future<void> adminDnaAddValue(String attributeId, String name) async {
    await supabase.rpc('admin_dna_add_value',
        params: {'p_attribute_id': attributeId, 'p_name': name});
  }

  Future<void> adminDnaUpdateValue(String id,
      {String? name, bool? isActive}) async {
    await supabase.rpc('admin_dna_update_value',
        params: {'p_id': id, 'p_name': name, 'p_is_active': isActive});
  }

  Future<void> adminDnaDeleteValue(String id) async {
    await supabase.rpc('admin_dna_delete_value', params: {'p_id': id});
  }

  /// The calling stockist's own words per canonical value: { valueId: [words] }.
  Future<Map<String, List<String>>> dnaMyWords() async {
    try {
      final res = await supabase.rpc('dna_my_words');
      final map = res is Map ? Map<String, dynamic>.from(res) : {};
      return map.map((k, v) => MapEntry(
          k, ((v as List?) ?? const []).map((e) => e.toString()).toList()));
    } catch (e) {
      debugPrint('dnaMyWords failed: $e');
      return {};
    }
  }

  /// Replace the stockist's words for one canonical value.
  Future<void> dnaSetValueWords(String valueId, List<String> words) async {
    await supabase.rpc('dna_set_value_words',
        params: {'p_value_id': valueId, 'p_words': words});
  }

  /// Learn/repoint ONE import alias: next time this stockist's import contains
  /// [rawText] under [attributeId], it auto-resolves to [valueId]. Non-destructive
  /// (leaves the value's other words intact) — the twin of [upsertSurfaceAlias]
  /// for Design DNA, used by the importer's Map-DNA step.
  Future<void> dnaLearnAlias(
      String attributeId, String rawText, String valueId) async {
    await supabase.rpc('dna_learn_alias', params: {
      'p_attribute_id': attributeId,
      'p_raw': rawText,
      'p_value_id': valueId,
    });
  }

  /// Set (replace) a design's values for one attribute (single or multi).
  Future<void> dnaSetDesign(
      String libraryId, String attributeId, List<String> valueIds) async {
    await supabase.rpc('dna_set_design', params: {
      'p_library_id': libraryId,
      'p_attribute_id': attributeId,
      'p_value_ids': valueIds,
    });
  }

  /// Set (replace) a FREE-TEXT attribute's values on a design (e.g. Range). Each
  /// text is found-or-created as a stockist-scoped value, then linked. The server
  /// enforces the attribute is free-text + the design is the caller's.
  Future<void> dnaSetDesignText(
      String libraryId, String attributeId, List<String> texts) async {
    await supabase.rpc('dna_set_design_text', params: {
      'p_library_id': libraryId,
      'p_attribute_id': attributeId,
      'p_texts': texts,
    });
  }

  /// A design's current DNA: { attributeId: [ {id,name}, … ] }.
  Future<Map<String, List<DnaValue>>> dnaForDesign(String libraryId) async {
    try {
      final res = await supabase
          .rpc('dna_for_design', params: {'p_library_id': libraryId});
      final map = res is Map ? Map<String, dynamic>.from(res) : {};
      return map.map((k, v) => MapEntry(
          k,
          ((v as List?) ?? const [])
              .map((e) => DnaValue.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList()));
    } catch (e) {
      debugPrint('dnaForDesign failed: $e');
      return {};
    }
  }

  /// Bulk DNA tags for the stockist's whole library, in THEIR own words:
  /// { libraryId: ["Glossy", "Marble", …] }. One call for the library list.
  Future<Map<String, List<String>>> dnaMyLibraryTags() async {
    try {
      final res = await supabase.rpc('dna_my_library_tags');
      final map = res is Map ? Map<String, dynamic>.from(res) : {};
      return map.map((k, v) => MapEntry(
          k, ((v as List?) ?? const []).map((e) => e.toString()).toList()));
    } catch (e) {
      debugPrint('dnaMyLibraryTags failed: $e');
      return {};
    }
  }

  /// A single (buyer-visible) design's DNA tags for display, in the design's
  /// OWN stockist's word: [ {attribute, label}, … ] grouped/ordered server-side.
  Future<List<({String attribute, String label})>> designDnaTags(
      String designId) async {
    try {
      final res = await supabase
          .rpc('design_dna_tags', params: {'p_design_id': designId});
      final list = (res as List?) ?? const [];
      return list.map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return (
          attribute: (m['attribute'] ?? '').toString(),
          label: (m['label'] ?? '').toString(),
        );
      }).toList();
    } catch (e) {
      debugPrint('designDnaTags failed: $e');
      return [];
    }
  }

  /// Canonical DNA value_ids per design, for buyer faceted search/filter:
  /// { designId: {valueId, …} }.
  Future<Map<String, Set<String>>> designsDnaValues(
      List<String> designIds) async {
    if (designIds.isEmpty) return {};
    try {
      final res = await supabase
          .rpc('designs_dna_values', params: {'p_design_ids': designIds});
      final map = res is Map ? Map<String, dynamic>.from(res) : {};
      return map.map((k, v) => MapEntry(
          k, ((v as List?) ?? const []).map((e) => e.toString()).toSet()));
    } catch (e) {
      debugPrint('designsDnaValues failed: $e');
      return {};
    }
  }

  /// Find-or-create the Library master id for a stock design (so the dashboard
  /// DNA dot can open the editor even for designs not yet in the Library).
  /// Returns null on failure.
  Future<String?> libraryEnsureForDesign(String designId) async {
    try {
      final res = await supabase
          .rpc('library_ensure_for_design', params: {'p_design_id': designId});
      final id = res?.toString() ?? '';
      return id.isEmpty ? null : id;
    } catch (e) {
      debugPrint('libraryEnsureForDesign failed: $e');
      return null;
    }
  }

  /// Atomic, all-or-nothing bulk import. Sends the whole batch + a client
  /// [batchId] (idempotency key) to one DB transaction: it builds library
  /// masters/images, creates/finds designs and adds stock together. If the call
  /// is interrupted (network/power loss) the DB rolls the whole thing back —
  /// never a half-import. Re-sending the SAME [batchId] returns the prior result
  /// instead of double-adding. Each row: {name,size,quality,surface,qty,
  /// image_url,stock_type,tile_type,pieces_per_box,box_weight_kg,thickness_mm}.
  /// Returns the summary (masters/created/updated/stock_rows/skipped/
  /// already_applied). Throws the server message on failure.
  Future<Map<String, dynamic>> importStockBatch({
    required String batchId,
    required String? catalogId,
    required String? brandId,
    required String pdfFilename,
    required List<Map<String, dynamic>> rows,
    String mode = 'add', // 'add' | 'replace_all' (fully new) | 'replace_keep'
  }) async {
    try {
      final res = await supabase.rpc('import_stock_batch', params: {
        'p_batch_id': batchId,
        'p_catalog_id': catalogId,
        'p_brand_id': brandId,
        'p_pdf_filename': pdfFilename,
        'p_rows': rows,
        'p_mode': mode,
      });
      return res is Map
          ? Map<String, dynamic>.from(res)
          : <String, dynamic>{};
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Super-admin "go live" switch — reads the single app_settings flag that
  /// gates the public market + anonymity across the whole app. Safe for anyone.
  Future<bool> getPublicMarketEnabled() async {
    final res = await supabase.rpc('get_public_market_enabled');
    return res == true;
  }

  /// Flips the go-live switch. Server enforces super-admin-only (throws otherwise).
  Future<bool> setPublicMarketEnabled(bool enabled) async {
    final res = await supabase
        .rpc('set_public_market_enabled', params: {'p_enabled': enabled});
    return res == true;
  }

  /// Admin: grant/revoke a stockist's permission to create PRIVATE catalogs
  /// (the Father & Child gate — also the hook for paid/special features).
  Future<void> setStockistPrivateCatalog(
      String sequentialId, bool allowed) async {
    await supabase.rpc('admin_set_private_catalog',
        params: {'p_seq': sequentialId, 'p_allowed': allowed});
  }

  /// Admin: turn public anonymity on/off for a stockist. When on, a trade name
  /// is required and a masked public code is minted on first enable. Returns
  /// the live public code (or null when turned off).
  Future<String?> setStockistAnonymous(
      String sequentialId, bool on, String displayName) async {
    final res = await supabase.rpc('admin_set_anonymous', params: {
      'p_seq': sequentialId,
      'p_on': on,
      'p_display_name': displayName,
    });
    return res as String?;
  }

  /// Admin: set a stockist's catalogue accent colour + Google-Maps link for the
  /// public catalog page. Logo/banner/tagline editing was retired — the
  /// share-link banner is admin-controlled via the Catalog Banners screen
  /// (project_admin_banner_system). Blank values clear the field.
  Future<void> setStockistBranding(
    String sequentialId, {
    String brandColor = '',
    String mapUrl = '',
  }) async {
    await supabase.rpc('admin_set_branding', params: {
      'p_seq': sequentialId,
      'p_brand_color': brandColor,
      'p_map_url': mapUrl,
    });
  }

  /// Admin: mint a fresh masked public code (retires the old one to history).
  Future<String?> regeneratePublicCode(String sequentialId) async {
    final res = await supabase
        .rpc('admin_regenerate_public_code', params: {'p_seq': sequentialId});
    return res as String?;
  }

  /// Admin: set a user's concurrent-device limit. [role] is 'stockist' (key =
  /// sequential id) or 'end_user' (key = end-user UUID). 0 = unlimited.
  Future<void> setDeviceLimit(String role, String key, int limit) async {
    await supabase.rpc('admin_set_device_limit',
        params: {'p_role': role, 'p_key': key, 'p_limit': limit});
  }

  /// Admin: clear all registered devices for a user (frees every slot). Returns
  /// how many were removed.
  Future<int> clearUserDevices(String role, String key) async {
    final res = await supabase.rpc('admin_clear_user_devices',
        params: {'p_role': role, 'p_key': key});
    return (res as int?) ?? 0;
  }

  /// Admin: how many devices the user currently has registered.
  Future<int> userDeviceCount(String role, String key) async {
    try {
      final res = await supabase.rpc('admin_user_device_count',
          params: {'p_role': role, 'p_key': key});
      return (res as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Admin: reverse-lookup a (live or retired) public code → real stockist(s).
  Future<List<Map<String, dynamic>>> resolvePublicCode(String code) async {
    try {
      final res = await supabase
          .rpc('admin_resolve_public_code', params: {'p_code': code});
      return (res as List?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          [];
    } catch (_) {
      return [];
    }
  }

  /// The stockist UUID for a sequential id (catalogs are keyed by UUID, but
  /// admin screens work in sequential ids).
  Future<String?> stockistUuidForSeq(String sequentialId) async {
    try {
      final s = await supabase
          .from('stockists')
          .select('id')
          .eq('sequential_id', sequentialId)
          .maybeSingle();
      return s?['id'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Public (no login): a stockist's catalog by share token, for the web link.
  /// Returns null if the token is invalid or the stockist is inactive.
  Future<Map<String, dynamic>?> getPublicCatalog(String token) async {
    try {
      final res =
          await supabase.rpc('public_catalog', params: {'p_token': token});
      if (res == null) return null;
      return Map<String, dynamic>.from(res as Map);
    } catch (e, st) {
      debugPrint('getPublicCatalog failed ($token): $e\n$st');
      return null;
    }
  }

  // ── Stockist share links (permanent + create-on-demand, optional expiry) ────

  /// A specific catalog's links: its always-on Permanent link plus every active
  /// timed link bound to that catalog. Works for public AND private catalogs.
  Future<List<ShareLink>> getCatalogShareLinks(String catalogId) async {
    try {
      final res = await supabase
          .rpc('catalog_share_links', params: {'p_catalog_id': catalogId});
      final list = (res as List?) ?? const [];
      return list
          .map((e) => ShareLink.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (e, st) {
      debugPrint('getCatalogShareLinks($catalogId) failed: $e\n$st');
      return [];
    }
  }

  /// Creates a timed link for one catalog. [duration] is one of
  /// '1week','1month','3month','6month','1year' (Permanent is always-on, not
  /// created here). Returns true on success.
  Future<bool> createCatalogShareLink(String catalogId, String duration) async {
    try {
      await supabase.rpc('create_catalog_share_link',
          params: {'p_catalog_id': catalogId, 'p_duration': duration});
      return true;
    } catch (e, st) {
      debugPrint('createCatalogShareLink($catalogId,$duration) failed: $e\n$st');
      return false;
    }
  }

  /// Creates a timed link for one stock list valid for [days] days. Returns the
  /// new token on success, or null on failure.
  Future<String?> createCatalogShareLinkDays(String catalogId, int days) async {
    try {
      final res = await supabase.rpc('create_catalog_share_link_days',
          params: {'p_catalog_id': catalogId, 'p_days': days});
      final map = res is Map ? Map<String, dynamic>.from(res) : null;
      return map?['token'] as String?;
    } catch (e, st) {
      debugPrint('createCatalogShareLinkDays($catalogId,$days) failed: $e\n$st');
      return null;
    }
  }

  /// Revokes (deactivates) one of the calling stockist's create-on-demand links.
  Future<bool> revokeShareLink(String id) async {
    try {
      await supabase.rpc('revoke_share_link', params: {'p_id': id});
      return true;
    } catch (e, st) {
      debugPrint('revokeShareLink($id) failed: $e\n$st');
      return false;
    }
  }

  /// Admin: update an end user's editable fields (keyed by row uuid).
  Future<void> updateEndUser({
    required String uuid,
    required String companyName,
    String contactPerson = '',
    String phone = '',
    String countryCode = '+91',
    String city = '',
    String gstNumber = '',
    String endUserType = '',
    double priority = 0,
    bool canClaimPrivate = false,
  }) async {
    await supabase.rpc('admin_update_end_user', params: {
      'p_id':           uuid,
      'p_company':      companyName,
      'p_contact':      contactPerson,
      'p_phone':        phone,
      'p_country_code': countryCode,
      'p_city':         city,
      'p_gst':          gstNumber,
      'p_enduser_type': endUserType,
      'p_priority':     priority,
      'p_can_claim_private': canClaimPrivate,
    });
  }

  /// Admin: hard-delete an end user (must be deactivated first).
  Future<void> deleteEndUser(String uuid) async {
    await supabase.rpc('admin_delete_end_user', params: {'p_id': uuid});
  }

  /// Admin: set a stockist's listing controls — priority (in-tier order) and
  /// tier (Platinum/Gold/Silver). Keyed by sequential id. Drives buyer order.
  Future<void> updateStockistListing(
      String sequentialId, double priority, String stockistType) async {
    await supabase.rpc('admin_set_stockist_listing', params: {
      'p_seq':           sequentialId,
      'p_priority':      priority,
      'p_stockist_type': stockistType,
    });
  }

  /// Activate / deactivate a stockist by its display (sequential) ID.
  Future<bool> setStockistActive(String sequentialId, bool active) async {
    try {
      await supabase
          .from('stockists')
          .update({'is_active': active})
          .eq('sequential_id', sequentialId);
      return true;
    } catch (e, st) {
      debugPrint('setStockistActive failed ($sequentialId): $e\n$st');
      return false;
    }
  }

  Future<Stockist?> getStockistBySequentialId(String seqId) async {
    try {
      // Buyer-facing: masked view, keyed on the (possibly masked) public key.
      final s = await supabase
          .from('buyer_stockists')
          .select()
          .eq('sequential_id', seqId)
          .single();
      return _toStockist(s);
    } catch (_) {
      return null;
    }
  }

  Stockist _toStockist(Map<String, dynamic> s) => Stockist(
        id:        s['sequential_id'],
        uuid:      s['uuid'] ?? '',
        name:      s['name'],
        email:     s['email'] ?? '', // present only via admin_list_stockists
        phone:     s['phone'],
        countryCode: s['country_code'] ?? '+91',
        city:      s['city'],
        state:     s['state'],
        address:   s['address'] ?? '',
        priority:  (s['priority'] as num?)?.toDouble() ?? 0,
        gstNumber: s['gst_number'] ?? '',
        stockistType: s['stockist_type'] ?? '',
        businessType: (s['business_type'] as String?)?.trim().isNotEmpty == true
            ? s['business_type'] as String
            : 'M',
        isActive:  s['is_active'] ?? true,
        isListed:  s['is_listed'] ?? true,
        shareToken: s['share_token'] ?? '',
        canCreatePrivateCatalog: s['can_create_private_catalog'] ?? false,
        isAnonymous: s['is_anonymous'] ?? false,
        publicDisplayName: s['public_display_name'] ?? '',
        publicCode: s['public_code'] ?? '',
        deviceLimit: s['device_limit'] ?? 1,
        deviceCount: s['device_count'] ?? 0,
        brandLimit: s['brand_limit'] ?? 1,
        brandCount: s['brand_count'] ?? 0,
        stockListLimit: s['stock_list_limit'] ?? 3,
        logoUrl:    s['logo_url'] ?? '',
        bannerUrl:  s['banner_url'] ?? '',
        tagline:    s['tagline'] ?? '',
        brandColor: s['brand_color'] ?? '',
        mapUrl:     s['map_url'] ?? '',
        createdAt: DateTime.tryParse(s['created_at']?.toString() ?? '') ??
            DateTime.now(),
      );

  /// Creates a single stockist (auth login + profile + stockist row) via the
  /// admin-only RPC. The sequential ID is auto-generated (A01, A02, …) when
  /// [sequentialId] is left null/blank. Returns the generated/used sequential
  /// ID on success, or throws with the server message on failure.
  Future<String> addStockist({
    required String name,
    required String email,
    required String password,
    String phone = '',
    String countryCode = '+91',
    String city = '',
    String state = '',
    String address = '',
    double priority = 0,
    String gstNumber = '',
    String stockistType = '',
    String? sequentialId,
  }) async {
    final res = await supabase.rpc('create_user_from_excel', params: {
      'p_email':         email,
      'p_password':      password,
      'p_role':          'stockist',
      'p_sequential_id': (sequentialId == null || sequentialId.trim().isEmpty)
          ? null
          : sequentialId.trim(),
      'p_name':          name,
      'p_phone':         phone,
      'p_country_code':  countryCode,
      'p_city':          city,
      'p_state':         state,
      'p_address':       address,
      'p_priority':      priority,
      'p_gst_number':    gstNumber.trim().isEmpty ? null : gstNumber.trim(),
      'p_stockist_type': stockistType.trim().isEmpty ? null : stockistType.trim(),
    });
    // RPC returns jsonb { id, email, role, sequential_id }.
    final map = res is Map ? res : <String, dynamic>{};
    return (map['sequential_id'] as String?) ?? '';
  }

  // ── end users ─────────────────────────────────────────────────────────────

  /// All end users (admin view), including their login email. [activeOnly]
  /// false includes deactivated. Uses an admin-only RPC because the email
  /// lives in auth.users, which the client can't read directly.
  Future<List<EndUser>> getAllEndUsers({bool activeOnly = false}) async {
    try {
      final res = await supabase.rpc('admin_list_end_users');
      final list = (res as List?) ?? const [];
      var users = list
          .map<EndUser>((e) => EndUser.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      if (activeOnly) users = users.where((u) => u.isActive).toList();
      return users;
    } catch (e, st) {
      debugPrint('getAllEndUsers failed: $e\n$st');
      return [];
    }
  }

  /// Creates a single end user (auth login + profile + end_users row) via the
  /// admin-only RPC. The unique ID is auto-generated (01A, 02A, …) when
  /// [sequentialId] is null/blank. Returns the generated/used ID.
  Future<String> addEndUser({
    required String companyName,
    required String email,
    required String password,
    String contactPerson = '',
    String phone = '',
    String countryCode = '+91',
    String city = '',
    String gstNumber = '',
    double priority = 0,
    String endUserType = '',
    String? sequentialId,
  }) async {
    final res = await supabase.rpc('create_user_from_excel', params: {
      'p_email':         email,
      'p_password':      password,
      'p_role':          'end_user',
      'p_sequential_id': (sequentialId == null || sequentialId.trim().isEmpty)
          ? null
          : sequentialId.trim(),
      'p_company_name':  companyName,
      'p_contact_person': contactPerson,
      'p_phone':         phone,
      'p_country_code':  countryCode,
      'p_city':          city,
      'p_priority':      priority,
      'p_gst_number':    gstNumber.trim().isEmpty ? null : gstNumber.trim(),
      'p_enduser_type':  endUserType.trim().isEmpty ? null : endUserType.trim(),
    });
    final map = res is Map ? res : <String, dynamic>{};
    return (map['sequential_id'] as String?) ?? '';
  }

  /// Activate / deactivate an end user by its row UUID.
  Future<bool> setEndUserActive(String uuid, bool active) async {
    try {
      await supabase
          .from('end_users')
          .update({'is_active': active})
          .eq('id', uuid);
      return true;
    } catch (e, st) {
      debugPrint('setEndUserActive failed ($uuid): $e\n$st');
      return false;
    }
  }

  // ── stockist inquiries (buyer My-Choice interest in own designs) ───────────

  /// For the logged-in stockist: aggregated buyer interest in their designs,
  /// as { designId : (buyers, boxes) }. Empty unless the caller is a stockist.
  Future<Map<String, ({int buyers, int boxes})>> getMyDesignInquiries() async {
    try {
      final res = await supabase.rpc('my_design_inquiries');
      final list = (res as List?) ?? const [];
      return {
        for (final e in list)
          (e['design_id'] as String): (
            buyers: (e['buyers'] as num).toInt(),
            boxes: (e['total_boxes'] as num).toInt(),
          )
      };
    } catch (e, st) {
      debugPrint('getMyDesignInquiries failed: $e\n$st');
      return {};
    }
  }

  /// For the logged-in stockist: a flat list of every buyer interest (My Choice)
  /// in their designs — one row per (buyer, design) with company/contact/phone/
  /// city, design name/size, boxes and updated_at. The Inquiries screen groups
  /// these by buyer / date / design. Empty unless the caller is a stockist.
  Future<List<Map<String, dynamic>>> getMyInquiryList() async {
    try {
      final res = await supabase.rpc('my_inquiry_list');
      final list = (res as List?) ?? const [];
      return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (e, st) {
      debugPrint('getMyInquiryList failed: $e\n$st');
      return [];
    }
  }

  // ── tokenised orders (inquiries) ────────────────────────────────────────────

  /// Buyer: my own orders (one per stockist I'm ordering from), each with token,
  /// lifecycle status and Generated/Modified times. Empty for guests.
  Future<List<InquiryOrder>> getMyOrders() async {
    if (currentEndUserId.isEmpty) return [];
    try {
      final res = await supabase.rpc('my_orders');
      final list = (res as List?) ?? const [];
      return list
          .map((e) => InquiryOrder.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (e, st) {
      debugPrint('getMyOrders failed: $e\n$st');
      return [];
    }
  }

  /// Buyer: my dispatch history — every dispatch note a supplier shipped to me
  /// (truck/invoice details + per-design boxes), newest first. Stockist name is
  /// anonymity-masked by the RPC. Empty for guests.
  Future<List<DispatchRecord>> getMyDispatches() async {
    if (currentEndUserId.isEmpty) return [];
    try {
      final res = await supabase.rpc('my_dispatches');
      final list = (res as List?) ?? const [];
      return list
          .map((e) => DispatchRecord.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (e, st) {
      debugPrint('getMyDispatches failed: $e\n$st');
      return [];
    }
  }

  /// Stockist: orders placed with me (token, buyer, status, timestamps, totals).
  Future<List<InquiryOrder>> getMyInquiries() async {
    try {
      final res = await supabase.rpc('my_inquiries');
      final list = (res as List?) ?? const [];
      return list
          .map((e) => InquiryOrder.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (e, st) {
      debugPrint('getMyInquiries failed: $e\n$st');
      return [];
    }
  }

  /// One order's header + lines (caller must be its buyer, stockist or admin).
  /// Lines come from the live basket while draft/confirmed, else the frozen items.
  Future<Map<String, dynamic>?> getInquiryDetail(String id) async {
    try {
      final res = await supabase.rpc('inquiry_detail', params: {'p_id': id});
      return res == null ? null : Map<String, dynamic>.from(res as Map);
    } catch (e, st) {
      debugPrint('getInquiryDetail failed ($id): $e\n$st');
      return null;
    }
  }

  /// Buyer marks their inquiry as Sent when they send it to the stockist
  /// (draft -> sent; re-send just bumps Modified). Fire-and-forget.
  Future<void> markInquirySent(String id) async {
    try {
      await supabase.rpc('mark_inquiry_sent', params: {'p_id': id});
    } catch (e, st) {
      debugPrint('markInquirySent failed ($id): $e\n$st');
    }
  }

  /// Stockist confirms an order (locks it): freezes the buyer out and snapshots
  /// the lines. (Shown to the stockist as "Confirm Order".)
  Future<void> lockInquiry(String id) async {
    try {
      await supabase.rpc('lock_inquiry', params: {'p_id': id});
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Stockist reopens a locked (not yet dispatched) order so the buyer can edit.
  Future<void> unlockInquiry(String id) async {
    try {
      await supabase.rpc('unlock_inquiry', params: {'p_id': id});
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Stockist rejects a whole order: marks it rejected and clears the buyer's
  /// basket lines for this stockist.
  Future<void> rejectOrder(String id) async {
    try {
      await supabase.rpc('reject_order', params: {'p_id': id});
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Dispatch a locked order by token. [lines] is the full current line set —
  /// each `{ 'design_id': <uuid>, 'dispatch': <boxes> }`; omitted designs are
  /// removed, new design_ids are added. Over-stock dispatch is allowed (system
  /// stock clamps at 0). The note metadata (invoice/vehicle/transporter/date)
  /// is saved as a Dispatch Note so a report can be sent to the buyer. Returns
  /// the new status, outstanding/dispatched totals and the dispatch_no.
  Future<Map<String, dynamic>> dispatchInquiry(
    String id,
    List<Map<String, dynamic>> lines, {
    String invoiceNo = '',
    String vehicleNo = '',
    String transporter = '',
    String note = '',
    DateTime? date,
  }) async {
    try {
      final res = await supabase.rpc('dispatch_inquiry', params: {
        'p_inquiry': id,
        'p_lines': lines,
        'p_invoice': invoiceNo,
        'p_vehicle': vehicleNo,
        'p_transporter': transporter,
        'p_note': note,
        'p_date': (date ?? DateTime.now()).toIso8601String().substring(0, 10),
      });
      return Map<String, dynamic>.from(res as Map);
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Per-buyer breakdown for one of the stockist's designs: each entry has
  /// end_user_id, company, contact, phone, boxes. Empty unless the design
  /// belongs to caller.
  Future<List<Map<String, dynamic>>> getDesignBuyers(String designId) async {
    try {
      final res = await supabase
          .rpc('my_design_buyers', params: {'p_design_id': designId});
      final list = (res as List?) ?? const [];
      return list.map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (e, st) {
      debugPrint('getDesignBuyers failed ($designId): $e\n$st');
      return [];
    }
  }

  /// After dispatching to a buyer, reduce that buyer's My-Choice (inquiry) for
  /// the design by [quantity], clearing it once fulfilled. No-op server-side if
  /// the caller doesn't own the design.
  Future<void> fulfillChoice(
      String designId, String endUserId, int quantity) async {
    try {
      await supabase.rpc('fulfill_choice', params: {
        'p_design_id':   designId,
        'p_end_user_id': endUserId,
        'p_quantity':    quantity,
      });
    } catch (e, st) {
      debugPrint('fulfillChoice failed ($designId/$endUserId): $e\n$st');
    }
  }

  /// Admin: all buyer inquiries across stockists (stockist, design, buyer,
  /// city, boxes).
  Future<List<Map<String, dynamic>>> getInquiryReport() async {
    try {
      final res = await supabase.rpc('admin_inquiry_report');
      final list = (res as List?) ?? const [];
      return list.map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (e, st) {
      debugPrint('getInquiryReport failed: $e\n$st');
      return [];
    }
  }

  // ── pending stock approval (big-stock workflow) ────────────────────────────

  /// Admin: per-stockist summary of stock awaiting approval.
  Future<List<Map<String, dynamic>>> getPendingStock() async {
    try {
      final res = await supabase.rpc('admin_pending_stock');
      final list = (res as List?) ?? const [];
      return list.map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (e, st) {
      debugPrint('getPendingStock failed: $e\n$st');
      return [];
    }
  }

  /// Admin: approve or reject ALL pending stock for one stockist.
  Future<int> setPendingStock(String stockistId, bool approve) async {
    try {
      final res = await supabase.rpc('set_pending_stock',
          params: {'p_stockist_id': stockistId, 'p_approve': approve});
      return (res as int?) ?? 0;
    } catch (e, st) {
      debugPrint('setPendingStock failed ($stockistId): $e\n$st');
      rethrow;
    }
  }

  /// Stockist: total of my own boxes awaiting admin approval.
  Future<int> myPendingStockBoxes() async {
    try {
      final res = await supabase.rpc('my_pending_stock_boxes');
      return (res as int?) ?? 0;
    } catch (e, st) {
      debugPrint('myPendingStockBoxes failed: $e\n$st');
      return 0;
    }
  }

  // ── notifications ───────────────────────────────────────────────────────────

  /// The signed-in user's notifications, newest first (RLS limits to own).
  Future<List<AppNotification>> getNotifications() async {
    try {
      final res = await supabase
          .from('notifications')
          .select()
          .order('created_at', ascending: false)
          .limit(100);
      return (res as List)
          .map((e) => AppNotification.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (e, st) {
      debugPrint('getNotifications failed: $e\n$st');
      return [];
    }
  }

  Future<int> getUnreadNotificationCount() async {
    try {
      final res = await supabase
          .from('notifications')
          .select('id')
          .eq('is_read', false);
      return (res as List).length;
    } catch (e, st) {
      debugPrint('getUnreadNotificationCount failed: $e\n$st');
      return 0;
    }
  }

  Future<void> markNotificationRead(String id) async {
    try {
      await supabase.from('notifications').update({'is_read': true}).eq('id', id);
    } catch (e, st) {
      debugPrint('markNotificationRead failed ($id): $e\n$st');
    }
  }

  Future<void> markAllNotificationsRead() async {
    try {
      await supabase
          .from('notifications')
          .update({'is_read': true})
          .eq('is_read', false);
    } catch (e, st) {
      debugPrint('markAllNotificationsRead failed: $e\n$st');
    }
  }

  Future<void> deleteNotification(String id) async {
    try {
      await supabase.from('notifications').delete().eq('id', id);
    } catch (e, st) {
      debugPrint('deleteNotification failed ($id): $e\n$st');
    }
  }

  /// Delete ALL of the signed-in user's notifications (the inbox "Clear all").
  /// RLS limits the delete to the caller's own rows.
  Future<void> clearMyNotifications() async {
    try {
      final uid = supabase.auth.currentUser?.id;
      if (uid == null) return;
      await supabase.from('notifications').delete().eq('recipient_id', uid);
    } catch (e, st) {
      debugPrint('clearMyNotifications failed: $e\n$st');
    }
  }

  /// Buyer → stockist alert ("New inquiry" with the buyer's name/phone/city).
  /// Fired automatically when the buyer contacts the stockist on WhatsApp.
  Future<void> notifyStockist(String stockistSeqId) async {
    try {
      await supabase
          .rpc('notify_stockist', params: {'p_stockist_seq': stockistSeqId});
    } catch (e, st) {
      debugPrint('notifyStockist failed ($stockistSeqId): $e\n$st');
    }
  }

  /// Stockist → buyer: dispatch confirmation (buyer picked from inquiry list).
  Future<void> notifyDispatch(
      String designId, String endUserId, int quantity) async {
    try {
      await supabase.rpc('notify_dispatch', params: {
        'p_design_id':   designId,
        'p_end_user_id': endUserId,
        'p_quantity':    quantity,
      });
    } catch (e, st) {
      debugPrint('notifyDispatch failed ($designId/$endUserId): $e\n$st');
    }
  }

  /// Admin → picked stockists / end-users (or everyone of a role). Returns the
  /// stockist recipient count (best-effort).
  Future<int> adminSendNotification({
    required String title,
    required String body,
    List<String>? stockistSeqIds,
    List<String>? endUserIds,
    bool allStockists = false,
    bool allEndUsers = false,
  }) async {
    try {
      final res = await supabase.rpc('admin_send_notification', params: {
        'p_title':            title,
        'p_body':             body,
        'p_stockist_seq_ids': stockistSeqIds,
        'p_end_user_ids':     endUserIds,
        'p_all_stockists':    allStockists,
        'p_all_end_users':    allEndUsers,
      });
      return (res as int?) ?? 0;
    } catch (e, st) {
      debugPrint('adminSendNotification failed: $e\n$st');
      rethrow;
    }
  }

  /// All dispatches for the current stockist, newest first. Each row has the
  /// design name plus quantity, buyer, notes and timestamp.
  Future<List<Map<String, dynamic>>> getAllDispatches() async {
    try {
      final res = await supabase
          .from('dispatches')
          .select(
              'id, quantity_dispatched, buyer_name, notes, created_at, designs(name)')
          .eq('stockist_id', currentStockistUUID)
          .order('created_at', ascending: false);
      return (res as List).map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (e, st) {
      debugPrint('getAllDispatches failed: $e\n$st');
      return [];
    }
  }

  /// Rejects one buyer's inquiry for a design by deleting their My-Choice.
  /// Server-side no-op if the caller doesn't own the design.
  Future<void> rejectInquiry(String designId, String endUserId) async {
    try {
      await supabase.rpc('reject_inquiry', params: {
        'p_design_id':   designId,
        'p_end_user_id': endUserId,
      });
    } catch (e, st) {
      debugPrint('rejectInquiry failed ($designId/$endUserId): $e\n$st');
    }
  }

  /// Rejects every buyer's inquiry for a design (clears all My-Choice rows).
  Future<void> rejectDesignInquiries(String designId) async {
    try {
      await supabase.rpc('reject_design_inquiries',
          params: {'p_design_id': designId});
    } catch (e, st) {
      debugPrint('rejectDesignInquiries failed ($designId): $e\n$st');
    }
  }

  // ── my choices (per end user) ──────────────────────────────────────────────

  /// This end user's saved choices as { designId : quantity }.
  Future<Map<String, int>> getMyChoices() async {
    if (currentEndUserId.isEmpty) return {};
    try {
      final data = await supabase
          .from('my_choices')
          .select('design_id, quantity')
          .eq('end_user_id', currentEndUserId);
      return {
        for (final r in data) r['design_id'] as String: (r['quantity'] as int)
      };
    } catch (e, st) {
      debugPrint('getMyChoices failed: $e\n$st');
      return {};
    }
  }

  /// Upserts a chosen quantity, or removes the row when [quantity] <= 0.
  Future<void> upsertChoice(String designId, int quantity) async {
    if (currentEndUserId.isEmpty) return;
    try {
      if (quantity <= 0) {
        await supabase
            .from('my_choices')
            .delete()
            .eq('end_user_id', currentEndUserId)
            .eq('design_id', designId);
      } else {
        await supabase.from('my_choices').upsert({
          'end_user_id': currentEndUserId,
          'design_id':   designId,
          'quantity':    quantity,
          'updated_at':  DateTime.now().toIso8601String(),
        }, onConflict: 'end_user_id,design_id');
      }
    } catch (e, st) {
      debugPrint('upsertChoice failed ($designId): $e\n$st');
    }
  }

  /// Clears all of this end user's saved choices.
  Future<void> clearChoices() async {
    if (currentEndUserId.isEmpty) return;
    try {
      await supabase
          .from('my_choices')
          .delete()
          .eq('end_user_id', currentEndUserId);
    } catch (e, st) {
      debugPrint('clearChoices failed: $e\n$st');
    }
  }

  // ── stockist groups (per end user) ─────────────────────────────────────────

  /// This end user's saved groups (empty for guests / not-logged-in).
  Future<List<Map<String, dynamic>>> getMyGroups() async {
    if (currentEndUserId.isEmpty) return [];
    try {
      final data = await supabase
          .from('stockist_groups')
          .select()
          .eq('end_user_id', currentEndUserId)
          .order('created_at');
      return data.map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (e, st) {
      debugPrint('getMyGroups failed: $e\n$st');
      return [];
    }
  }

  /// Creates an empty group; returns its new id (or null on failure).
  Future<String?> createGroup(String name) async {
    if (currentEndUserId.isEmpty) return null;
    try {
      final row = await supabase.from('stockist_groups').insert({
        'end_user_id':  currentEndUserId,
        'name':         name,
        'stockist_ids': <String>[],
      }).select().single();
      return row['id'] as String?;
    } catch (e, st) {
      debugPrint('createGroup failed: $e\n$st');
      return null;
    }
  }

  Future<bool> renameGroup(String id, String name) async {
    try {
      await supabase.from('stockist_groups').update({
        'name': name,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', id);
      return true;
    } catch (e, st) {
      debugPrint('renameGroup failed ($id): $e\n$st');
      return false;
    }
  }

  Future<bool> setGroupMembers(String id, List<String> stockistIds) async {
    try {
      await supabase.from('stockist_groups').update({
        'stockist_ids': stockistIds,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', id);
      return true;
    } catch (e, st) {
      debugPrint('setGroupMembers failed ($id): $e\n$st');
      return false;
    }
  }

  Future<bool> deleteGroup(String id) async {
    try {
      await supabase.from('stockist_groups').delete().eq('id', id);
      return true;
    } catch (e, st) {
      debugPrint('deleteGroup failed ($id): $e\n$st');
      return false;
    }
  }

  // ── registration requests (self-signup → admin approval) ───────────────────

  /// Public: submit a self-registration request (creates NO login). Throws the
  /// server message on failure (e.g. email already exists / pending).
  Future<void> submitRegistrationRequest({
    required String email,
    required String password,
    required String companyName,
    required String contactPerson,
    String phone = '',
    String countryCode = '+91',
    String city = '',
    String? gstNumber,
  }) async {
    await supabase.rpc('submit_registration_request', params: {
      'p_email':          email,
      'p_password':       password,
      'p_company_name':   companyName,
      'p_contact_person': contactPerson,
      'p_phone':          phone,
      'p_country_code':   countryCode,
      'p_city':           city,
      'p_gst_number':     (gstNumber == null || gstNumber.trim().isEmpty)
          ? null
          : gstNumber.trim(),
    });
  }

  /// Admin: list pending registration requests.
  Future<List<Map<String, dynamic>>> getRegistrationRequests() async {
    try {
      final res = await supabase.rpc('admin_list_registration_requests');
      final list = (res as List?) ?? const [];
      return list.map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (e, st) {
      debugPrint('getRegistrationRequests failed: $e\n$st');
      return [];
    }
  }

  /// Admin: approve a request → creates the end-user account (auto ID). Returns
  /// the new sequential ID. Throws the server message on failure.
  Future<String> approveRegistrationRequest(
    String id, {
    double priority = 0,
    String endUserType = '',
  }) async {
    final res = await supabase.rpc('approve_registration_request', params: {
      'p_id':           id,
      'p_priority':     priority,
      'p_enduser_type': endUserType.trim().isEmpty ? null : endUserType.trim(),
    });
    final map = res is Map ? res : <String, dynamic>{};
    return (map['sequential_id'] as String?) ?? '';
  }

  /// Admin: reject (delete) a request.
  Future<bool> rejectRegistrationRequest(String id) async {
    try {
      await supabase.rpc('reject_registration_request', params: {'p_id': id});
      return true;
    } catch (e, st) {
      debugPrint('rejectRegistrationRequest failed ($id): $e\n$st');
      return false;
    }
  }

  // ── admins (super-admin only) ──────────────────────────────────────────────

  /// Lists admin accounts (email + active + super flag). Returns [] unless the
  /// caller is the super admin (enforced server-side).
  Future<List<Map<String, dynamic>>> getAllAdmins() async {
    try {
      final res = await supabase.rpc('admin_list_admins');
      final list = (res as List?) ?? const [];
      return list.map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (e, st) {
      debugPrint('getAllAdmins failed: $e\n$st');
      return [];
    }
  }

  /// Creates a sub-admin (super-admin only; enforced server-side). Returns the
  /// new user's email on success; throws the server message on failure.
  Future<String> addAdmin({
    required String email,
    required String password,
  }) async {
    final res = await supabase.rpc('create_user_from_excel', params: {
      'p_email':    email,
      'p_password': password,
      'p_role':     'admin',
    });
    final map = res is Map ? res : <String, dynamic>{};
    return (map['email'] as String?) ?? '';
  }

  /// Activate / deactivate a sub-admin by UUID (super-admin only; the super
  /// admin itself cannot be deactivated — enforced server-side).
  Future<bool> setAdminActive(String uuid, bool active) async {
    try {
      await supabase.rpc('set_admin_active',
          params: {'p_uuid': uuid, 'p_active': active});
      return true;
    } catch (e, st) {
      debugPrint('setAdminActive failed ($uuid): $e\n$st');
      return false;
    }
  }

  // ── inquiries ─────────────────────────────────────────────────────────────

  Future<bool> sendInquiry({
    required String stockistSequentialId,
    String? designId,
    String? message,
  }) async {
    try {
      if (currentEndUserId.isEmpty) return false;

      // Masked view → accepts the real id or the public code, and is the only
      // stockist source buyers may read.
      final stockist = await supabase
          .from('buyer_stockists')
          .select('uuid')
          .eq('sequential_id', stockistSequentialId)
          .single();

      final today = DateTime.now().toIso8601String().substring(0, 10);
      final eu = await supabase
          .from('end_users')
          .select('id, inquiries_today, last_inquiry_date')
          .eq('id', currentEndUserId)
          .single();

      final lastDate     = eu['last_inquiry_date'] ?? '';
      final todayCount   = lastDate == today ? (eu['inquiries_today'] as int) : 0;
      if (todayCount >= 10) return false;

      await supabase.from('inquiries').insert({
        'end_user_id': currentEndUserId,
        'stockist_id': stockist['uuid'],
        'design_id':   designId,
        'message':     message,
      });

      await supabase.from('end_users').update({
        'inquiries_today':   todayCount + 1,
        'last_inquiry_date': today,
      }).eq('id', currentEndUserId);

      return true;
    } catch (_) {
      return false;
    }
  }

  Future<int> getRemainingInquiries() async {
    try {
      if (currentEndUserId.isEmpty) return 10;
      final eu = await supabase
          .from('end_users')
          .select('inquiries_today, last_inquiry_date')
          .eq('id', currentEndUserId)
          .single();
      final today    = DateTime.now().toIso8601String().substring(0, 10);
      final lastDate = eu['last_inquiry_date'] ?? '';
      final count    = lastDate == today ? (eu['inquiries_today'] as int) : 0;
      return 10 - count;
    } catch (_) {
      return 10;
    }
  }

  Future<List<Map<String, dynamic>>> getInquiriesForStockist(String stockistUUID) async {
    try {
      final data = await supabase
          .from('inquiries')
          .select('*, end_users(company_name, contact_person, phone, city), designs(name, size)')
          .eq('stockist_id', stockistUUID)
          .order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(data);
    } catch (_) {
      return [];
    }
  }

  // ── surface types (admin master list of finishes) ──────────────────────────
  // These throw on failure so the admin sees the real error instead of a silent
  // no-op (same rationale as the auth error-surfacing change).

  Future<List<SurfaceType>> getSurfaceTypes({bool activeOnly = false}) async {
    var query = supabase.from('surface_types').select();
    if (activeOnly) query = query.eq('is_active', true);
    // ascending: true is REQUIRED — supabase-dart .order() defaults to
    // DESCENDING, which reversed the finish order everywhere (filters, overview
    // columns, dropdowns) vs the admin Manage Finishes sequence.
    final data = await query.order('sort_order', ascending: true);
    return data.map<SurfaceType>((s) => SurfaceType.fromJson(s)).toList();
  }

  /// Active finish names in the admin-defined order — used so the finish lists
  /// in buyer filters match the Manage Finishes sequence. Falls back to the
  /// built-in kFinishes order on failure.
  Future<List<String>> getActiveFinishNames() async {
    try {
      final types = await getSurfaceTypes(activeOnly: true);
      final names = types.map((t) => t.name).toList();
      return names.isEmpty ? List<String>.from(kFinishes) : names;
    } catch (_) {
      return List<String>.from(kFinishes);
    }
  }

  // ── tile sizes (admin-managed master) ───────────────────────────────────────

  Future<List<TileSize>> getTileSizes({bool activeOnly = false}) async {
    var query = supabase.from('tile_sizes').select();
    if (activeOnly) query = query.eq('is_active', true);
    // ascending: true required — see getSurfaceTypes; .order() defaults to DESC.
    final data = await query.order('sort_order', ascending: true);
    return data.map<TileSize>((s) => TileSize.fromJson(s)).toList();
  }

  /// Active size names in the admin-defined order (fallback to kAllowedSizes).
  Future<List<String>> getActiveSizeNames() async {
    try {
      final sizes = await getTileSizes(activeOnly: true);
      final names = sizes.map((s) => s.name).toList();
      return names.isEmpty ? List<String>.from(kAllowedSizes) : names;
    } catch (_) {
      return List<String>.from(kAllowedSizes);
    }
  }

  Future<void> addTileSize(String name, {List<String> aliases = const []}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw 'Size cannot be empty.';
    final existing = await supabase
        .from('tile_sizes')
        .select('sort_order')
        .order('sort_order', ascending: false)
        .limit(1);
    final nextOrder =
        (existing.isEmpty ? 0 : (existing.first['sort_order'] as int)) + 10;
    await supabase.from('tile_sizes').insert({
      'name': trimmed,
      'sort_order': nextOrder,
      'aliases': _cleanAliases(aliases),
    });
  }

  /// Replace a size's alias list (alternate inch/feet trade names).
  Future<void> setTileSizeAliases(String id, List<String> aliases) async {
    await supabase
        .from('tile_sizes')
        .update({'aliases': _cleanAliases(aliases)}).eq('id', id);
  }

  List<String> _cleanAliases(List<String> raw) {
    final seen = <String>{};
    final out = <String>[];
    for (final a in raw) {
      final t = a.trim();
      if (t.isEmpty || !seen.add(t.toLowerCase())) continue;
      out.add(t);
    }
    return out;
  }

  Future<void> renameTileSize(String id, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) throw 'Size cannot be empty.';
    await supabase.from('tile_sizes').update({'name': trimmed}).eq('id', id);
  }

  Future<void> setTileSizeActive(String id, bool active) async {
    await supabase.from('tile_sizes').update({'is_active': active}).eq('id', id);
  }

  Future<void> deleteTileSize(String id) async {
    await supabase.from('tile_sizes').delete().eq('id', id);
  }

  Future<void> reorderTileSizes(List<String> orderedIds) async {
    await supabase.rpc('reorder_tile_sizes', params: {'p_ids': orderedIds});
  }

  /// Set a size's explicit sort number (lower shows first).
  Future<void> setTileSizeOrder(String id, int order) async {
    await supabase.from('tile_sizes').update({'sort_order': order}).eq('id', id);
  }

  Future<void> addSurfaceType(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw 'Finish name cannot be empty.';
    // Place new finishes just before the system 'None' fallback.
    final existing = await supabase
        .from('surface_types')
        .select('sort_order')
        .eq('is_system', false)
        .order('sort_order', ascending: false)
        .limit(1);
    final nextOrder =
        (existing.isEmpty ? 0 : (existing.first['sort_order'] as int)) + 10;
    await supabase.from('surface_types').insert({
      'name':       trimmed,
      'sort_order': nextOrder,
    });
  }

  Future<void> renameSurfaceType(String id, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) throw 'Finish name cannot be empty.';
    await supabase.from('surface_types').update({'name': trimmed}).eq('id', id);
  }

  Future<void> setSurfaceActive(String id, bool active) async {
    await supabase.from('surface_types').update({'is_active': active}).eq('id', id);
  }

  /// Set a finish's explicit sort number (lower shows first).
  Future<void> setSurfaceOrder(String id, int order) async {
    await supabase
        .from('surface_types')
        .update({'sort_order': order}).eq('id', id);
  }

  /// Persists a new ordering. [orderedIds] is the full list top-to-bottom;
  /// each row's sort_order is rewritten to its index * 10.
  Future<void> reorderSurfaceTypes(List<String> orderedIds) async {
    for (var i = 0; i < orderedIds.length; i++) {
      await supabase
          .from('surface_types')
          .update({'sort_order': i * 10})
          .eq('id', orderedIds[i]);
    }
  }

  /// Number of designs currently using [name] as their surface_type. The admin
  /// screen uses this to block deleting an in-use finish. Surface now lives on
  /// the design identity (the master), so the count is taken there. (identity split)
  Future<int> countDesignsUsingSurface(String name) async {
    final data = await supabase
        .from('stockist_library')
        .select('id')
        .eq('surface_type', name);
    return (data as List).length;
  }

  Future<void> deleteSurfaceType(SurfaceType s) async {
    if (s.isSystem) throw 'The "${s.name}" fallback cannot be deleted.';
    final inUse = await countDesignsUsingSurface(s.name);
    if (inUse > 0) {
      throw '"${s.name}" is used by $inUse design(s). '
          'Hide it instead of deleting.';
    }
    await supabase.from('surface_types').delete().eq('id', s.id);
  }

  // ── surface aliases (per-stockist learned PDF-word → finish mapping) ────────

  /// This stockist's surface words grouped by admin finish: { finishName : [raw
  /// words] }. The inverse view of [getSurfaceAliases], for the My Words screen
  /// where each admin finish shows the stockist's own words mapped to it.
  Future<Map<String, List<String>>> getSurfaceWordsByFinish(
      String stockistUUID) async {
    final flat = await getSurfaceAliases(stockistUUID); // {raw : finish}
    final out = <String, List<String>>{};
    flat.forEach((raw, finish) {
      (out[finish] ??= <String>[]).add(raw);
    });
    for (final list in out.values) {
      list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    }
    return out;
  }

  /// Replace this stockist's surface words for one admin finish [surfaceName]:
  /// removes dropped words, upserts the rest (keyed on the normalised raw word,
  /// repointing a word that was on another finish). The surface twin of
  /// [dnaSetValueWords]. No-ops silently if [surfaceName] isn't a known finish.
  Future<void> setSurfaceWords(
      String stockistUUID, String surfaceName, List<String> words) async {
    try {
      final st = await supabase
          .from('surface_types')
          .select('id')
          .eq('name', surfaceName)
          .maybeSingle();
      if (st == null) return;
      final stId = st['id'];
      final keys = <String>{};
      for (final w in words) {
        final k = normalizeSurfaceRaw(w);
        if (k.isNotEmpty) keys.add(k);
      }
      // Drop this stockist's existing words for this finish that are gone now.
      final existing = await supabase
          .from('surface_aliases')
          .select('id, raw_text')
          .eq('stockist_id', stockistUUID)
          .eq('surface_type_id', stId);
      for (final row in existing) {
        if (!keys.contains(row['raw_text'] as String)) {
          await supabase.from('surface_aliases').delete().eq('id', row['id']);
        }
      }
      // Upsert each remaining word → this finish (repoints if it sat elsewhere).
      for (final k in keys) {
        await supabase.from('surface_aliases').upsert({
          'stockist_id': stockistUUID,
          'raw_text': k,
          'surface_type_id': stId,
        }, onConflict: 'stockist_id,raw_text');
      }
    } catch (e, stk) {
      debugPrint('setSurfaceWords failed ("$surfaceName"): $e\n$stk');
    }
  }

  /// Returns this stockist's learned aliases as { normalisedRaw : finishName }.
  /// Used during PDF upload to auto-align a raw surface word to the official
  /// finish the stockist previously chose for it.
  Future<Map<String, String>> getSurfaceAliases(String stockistUUID) async {
    try {
      final data = await supabase
          .from('surface_aliases')
          .select('raw_text, surface_types(name)')
          .eq('stockist_id', stockistUUID);
      final map = <String, String>{};
      for (final row in data) {
        final st = row['surface_types'];
        if (st != null && st['name'] != null) {
          map[row['raw_text'] as String] = st['name'] as String;
        }
      }
      return map;
    } catch (e, st) {
      debugPrint('getSurfaceAliases failed ($stockistUUID): $e\n$st');
      return {};
    }
  }

  /// Learns/updates an alias: the next time this stockist's PDF contains
  /// [rawText], it will auto-align to [surfaceName]. Keyed on the normalised
  /// raw word so spacing/punctuation variants collapse together. Silently
  /// no-ops if [surfaceName] isn't a known finish.
  Future<void> upsertSurfaceAlias(
      String stockistUUID, String rawText, String surfaceName) async {
    final key = normalizeSurfaceRaw(rawText);
    if (key.isEmpty) return;
    try {
      final st = await supabase
          .from('surface_types')
          .select('id')
          .eq('name', surfaceName)
          .maybeSingle();
      if (st == null) return;
      await supabase.from('surface_aliases').upsert({
        'stockist_id':     stockistUUID,
        'raw_text':        key,
        'surface_type_id': st['id'],
      }, onConflict: 'stockist_id,raw_text');
    } catch (e, stk) {
      debugPrint('upsertSurfaceAlias failed ("$rawText"->"$surfaceName"): $e\n$stk');
    }
  }

  // The old cross-stockist shared design-image library (`design_images`) was
  // retired in [[project_stockist_library]] Phase 2: auto-fill now comes only
  // from each stockist's own library (libraryImageFor / libraryContribute), never
  // borrowed. designImageKey / normalizeDesignNameKey above remain in use purely
  // as in-memory (name|size) map keys in the import previews.
}
