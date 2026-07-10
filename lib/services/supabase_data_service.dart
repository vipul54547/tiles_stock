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
        surfaceLabel: (d['surface_label'] ?? lib?['surface_label'] ?? '')
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
        libraryId:    (d['library_id'] ?? '').toString(),
        familyKey:    (d['family_key'] ?? '').toString(),
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
      heldQuantity: (d['held_quantity'] as num?)?.toInt() ?? 0,
      fStock:       (d['f_stock'] as num?)?.toInt(),
      surfaceType:  (d['surface_type'] ?? 'None').toString(),
      surfaceLabel: (d['surface_label'] ?? '').toString(),
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
      familyKey:    (d['family_key'] ?? '').toString(),
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
  // ── Unified dispatch (order-less "walk-in") + opt-in customers ──────────────

  /// Order-less dispatch: reduces stock, makes one dispatch note (optionally tied
  /// to a saved customer), logs dispatches. Each line: {design_id, dispatch}.
  /// Returns {dispatch_no, total}. (project_unified_dispatch_customers)
  Future<Map<String, dynamic>> dispatchWalkin(
    List<Map<String, dynamic>> lines, {
    String? customerId,
    String customerName = '',
    String invoice = '',
    String vehicle = '',
    String transporter = '',
    String note = '',
    DateTime? date,
    bool reduceStock = true,
  }) async {
    try {
      final res = await supabase.rpc('dispatch_walkin', params: {
        'p_lines': lines,
        'p_customer_id': customerId,
        'p_customer_name': customerName,
        'p_invoice': invoice,
        'p_vehicle': vehicle,
        'p_transporter': transporter,
        'p_note': note,
        'p_date': (date ?? DateTime.now()).toIso8601String().split('T').first,
        'p_reduce_stock': reduceStock,
      });
      return Map<String, dynamic>.from(res as Map);
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// The stockist's saved customers (empty when the feature is off / none saved).
  Future<List<Map<String, dynamic>>> listCustomers() async {
    try {
      final res = await supabase.rpc('list_customers');
      return (res as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e, st) {
      debugPrint('listCustomers failed: $e\n$st');
      return [];
    }
  }

  /// Save (or reuse) a customer — only works when the stockist is customers_enabled.
  /// Returns its id.
  Future<String?> upsertCustomer({
    String? id,
    required String name,
    String? phone,
    String countryCode = '+91',
    String? state,
    String? district,
    String? pincode,
    String? city,
  }) async {
    try {
      final res = await supabase.rpc('upsert_customer', params: {
        'p_id': id,
        'p_name': name,
        'p_phone': phone,
        'p_country_code': countryCode,
        'p_state': state,
        'p_district': district,
        'p_pincode': pincode,
        'p_city': city,
      });
      return res?.toString();
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Commit a batch of manual-stock entries in one atomic call. Each entry:
  /// {library_id, quality, quantity, brand_id?, surface}. Adds to P_Stock only
  /// (no stock list). Returns {count, boxes}.
  Future<Map<String, dynamic>> addInventoryBatch(
      List<Map<String, dynamic>> entries) async {
    try {
      final res = await supabase
          .rpc('add_inventory_batch', params: {'p_entries': entries});
      return Map<String, dynamic>.from(res as Map);
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  Future<String?> addDesign({
    required String libraryId,
    required String quality,
    required int    boxQuantity,
    String? catalogId,
    String? brandId,
    String? surface,
  }) async {
    try {
      final res = await supabase.rpc('stock_add_holding', params: {
        'p_library_id': libraryId,
        'p_quality':    quality,
        'p_qty':        boxQuantity,
        'p_catalog_id': catalogId,
        if (surface != null) 'p_surface': surface,
        'p_brand_id':   brandId,
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

  /// A login-free web enquiry with selected designs becomes a real saved order
  /// (source='web', no buyer account). Returns `{token, connection_code}` for the
  /// WhatsApp message, or null if it couldn't be created (e.g. no valid lines).
  /// (project_dispatch_order_redesign · Phase B)
  Future<Map<String, dynamic>?> createWebOrder(
      String token, List<Map<String, dynamic>> lines) async {
    try {
      final res = await supabase.rpc('create_web_order',
          params: {'p_token': token, 'p_lines': lines});
      return res == null ? null : Map<String, dynamic>.from(res as Map);
    } catch (e, st) {
      debugPrint('createWebOrder failed: $e\n$st');
      return null;
    }
  }

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

  /// The logged-in stockist's own editable profile fields (RLS: read-own).
  /// Returns null if not signed in as a stockist.
  Future<Map<String, dynamic>?> getMyProfile() async {
    try {
      final uid = supabase.auth.currentUser?.id;
      if (uid == null) return null;
      return await supabase
          .from('stockists')
          .select(
              'name, logo_url, brand_color, tagline, pincode, state, district, city, customers_enabled, surface_mode, business_type')
          .eq('user_id', uid)
          .maybeSingle();
    } catch (e, st) {
      debugPrint('getMyProfile failed: $e\n$st');
      return null;
    }
  }

  /// The logged-in BUYER's own editable profile fields (RLS: read-own).
  /// Returns null if not signed in as an end user.
  Future<Map<String, dynamic>?> getMyEndUserProfile() async {
    try {
      final uid = supabase.auth.currentUser?.id;
      if (uid == null) return null;
      return await supabase
          .from('end_users')
          .select(
              'company_name, contact_person, phone, country_code, city, gst_number, state, district, pincode')
          .eq('user_id', uid)
          .maybeSingle();
    } catch (e, st) {
      debugPrint('getMyEndUserProfile failed: $e\n$st');
      return null;
    }
  }

  /// Self-service BUYER profile save (SECURITY DEFINER RPC scoped to auth.uid()).
  /// Company is never blanked; other fields may be cleared with ''.
  Future<void> updateMyEndUserProfile({
    required String company,
    required String contact,
    required String phone,
    required String countryCode,
    required String city,
    required String gst,
    String state = '',
    String district = '',
    String pincode = '',
  }) async {
    await supabase.rpc('end_user_update_profile', params: {
      'p_company':      company,
      'p_contact':      contact,
      'p_phone':        phone,
      'p_country_code': countryCode,
      'p_city':         city,
      'p_gst':          gst,
      'p_state':        state,
      'p_district':     district,
      'p_pincode':      pincode,
    });
  }

  /// Whether the admin has enabled the TilesDesign mark for the current
  /// stockist (`stockists.td_show`). Gates the banner editor's TD-position UI:
  /// stockists only choose WHERE the mark sits, and only once admin turns it on.
  Future<bool> getMyTdShow() async {
    try {
      final uid = supabase.auth.currentUser?.id;
      if (uid == null) return false;
      final row = await supabase
          .from('stockists')
          .select('td_show')
          .eq('user_id', uid)
          .maybeSingle();
      return (row?['td_show'] as bool?) ?? false;
    } catch (e) {
      debugPrint('getMyTdShow failed: $e');
      return false;
    }
  }

  /// Self-service profile save (SECURITY DEFINER RPC scoped to auth.uid()).
  /// State/district slugs are computed server-side for SEO. Pass '' to clear
  /// logo/tagline; blank name/brand_color are ignored server-side.
  Future<void> updateMyProfile({
    required String name,
    required String logoUrl,
    required String brandColor,
    required String tagline,
    required String pincode,
    required String state,
    required String district,
    required String city,
  }) async {
    await supabase.rpc('stockist_update_profile', params: {
      'p_name': name,
      'p_logo_url': logoUrl,
      'p_brand_color': brandColor,
      'p_tagline': tagline,
      'p_pincode': pincode,
      'p_state': state,
      'p_district': district,
      'p_city': city,
    });
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

  /// Create a brand-free stock list ([id] null) or rename/edit an existing one.
  /// Returns the list id. Per-stockist limit enforced server-side. (stocklists v2)
  Future<String> saveStockList({
    String? id,
    required String name,
    String description = '',
    String listType = 'permanent',
    List<String> filterBrandIds = const [],
    List<String> filterQualities = const [],
    List<String> filterSurfaces = const [],
    List<String> filterSizes = const [],
    List<String> filterTileTypes = const [],
    List<String> filterStockTypes = const [],
    int? filterBoxMin,
    int? filterBoxMax,
  }) async {
    final res = await supabase.rpc('stock_list_save', params: {
      'p_id': id,
      'p_name': name,
      'p_description': description,
      'p_list_type': listType,
      'p_filter_brand_ids':   filterBrandIds,
      'p_filter_qualities':   filterQualities,
      'p_filter_surfaces':    filterSurfaces,
      'p_filter_sizes':       filterSizes,
      'p_filter_tile_types':  filterTileTypes,
      'p_filter_stock_types': filterStockTypes,
      'p_filter_box_min':     filterBoxMin,
      'p_filter_box_max':     filterBoxMax,
    });
    return (res ?? '').toString();
  }

  /// Set (or clear, with '') a brand-free list's own banner image. (stocklists v2)
  Future<void> setListBanner(String catalogId, String bannerUrl) async {
    await supabase.rpc('set_list_banner',
        params: {'p_catalog_id': catalogId, 'p_banner_url': bannerUrl});
  }

  /// Set a list's full banner layout (parity with the brand banner). [source] =
  /// pool | library | upload; an empty [source] clears it back to the brand
  /// banner. [bgUrl] = library background or full uploaded banner; [companyLogoUrl]
  /// = uploaded logo (library path); [companyPos]/[tdPos] = placement keys.
  /// (project_session_resume #6)
  Future<void> setListBannerConfig(
    String catalogId, {
    required String source,
    String bgUrl = '',
    String companyLogoUrl = '',
    String companyPos = 'none',
    String tdPos = 'top-right',
    String heading = '',
    String message = '',
    String headingSize = '',
    String headingColor = '',
    String msgSize = '',
    String msgColor = '',
    String textAlign = '',
    String textValign = '',
  }) async {
    await supabase.rpc('set_list_banner_config', params: {
      'p_catalog_id': catalogId,
      'p_source': source,
      'p_bg_url': bgUrl,
      'p_company_logo_url': companyLogoUrl,
      'p_company_pos': companyPos,
      'p_td_pos': tdPos,
      'p_heading': heading,
      'p_message': message,
      'p_heading_size': headingSize,
      'p_heading_color': headingColor,
      'p_msg_size': msgSize,
      'p_msg_color': msgColor,
      'p_text_align': textAlign,
      'p_text_valign': textValign,
    });
  }

  /// Replace a list's membership with [libraryIds] (the master/library ids of the
  /// chosen designs). Returns the resulting member count. (stocklists v2)
  Future<int> setListDesigns(String catalogId, List<String> libraryIds) async {
    final res = await supabase.rpc('set_list_designs', params: {
      'p_catalog_id': catalogId,
      'p_library_ids': libraryIds,
    });
    return (res as num?)?.toInt() ?? 0;
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

  /// Admin sets a brand's surface mode ('attribute' | 'in_name').
  /// (project_per_brand_surface_mode)
  Future<void> setBrandSurfaceMode(String brandId, String mode) async {
    try {
      await supabase.rpc('admin_set_brand_surface_mode',
          params: {'p_brand_id': brandId, 'p_mode': mode});
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

  /// Stockist creates a stock list under a brand (server enforces the admin-set
  /// stockist-wide stock_list_limit). Returns the new list id. Throws the server
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

  // ── Catalog banners (admin-controlled) ──────────────────────────────────────
  /// Admin: the generic/anonymous banner pool (shown on anonymous lists + as the
  /// fallback, daily-rotated). Newest first.
  /// [kind] = 'generic' (decorative pool) or 'text' (clean backgrounds for the
  /// Library message-banner mode).
  Future<List<Map<String, dynamic>>> getGenericBanners(
      {String kind = 'generic'}) async {
    try {
      final data = await supabase
          .from('banners')
          .select('id, image_url, is_active, created_at')
          .eq('kind', kind)
          .order('created_at', ascending: false);
      return data
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (e, st) {
      debugPrint('getGenericBanners failed: $e\n$st');
      return [];
    }
  }

  /// Admin: add a banner (Cloudinary URL). [kind] 'generic' = decorative pool,
  /// 'text' = clean background for message banners.
  Future<void> addGenericBanner(String imageUrl, {String kind = 'generic'}) async {
    await supabase
        .from('banners')
        .insert({'image_url': imageUrl, 'kind': kind});
  }

  Future<void> setBannerActive(String id, bool active) async {
    await supabase.from('banners').update({'is_active': active}).eq('id', id);
  }

  Future<void> deleteBanner(String id) async {
    await supabase.from('banners').delete().eq('id', id);
  }

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
      {bool isMulti = false,
      bool isFreeText = false,
      bool showInFacets = false}) async {
    await supabase.rpc('admin_dna_add_attribute', params: {
      'p_name': name,
      'p_is_multi': isMulti,
      'p_is_free_text': isFreeText,
      'p_show_in_facets': showInFacets,
    });
  }

  Future<void> adminDnaUpdateAttribute(String id,
      {String? name, bool? isActive, bool? showInFacets}) async {
    await supabase.rpc('admin_dna_update_attribute', params: {
      'p_id': id,
      'p_name': name,
      'p_is_active': isActive,
      'p_show_in_facets': showInFacets,
    });
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

  /// Rename one of the calling stockist's own private values (e.g. a Series
  /// they created). Fails if they don't own it or the name is already used
  /// by another of their own values on that attribute.
  Future<void> dnaRenameMyValue(String valueId, String newName) async {
    await supabase.rpc('dna_rename_my_value',
        params: {'p_value_id': valueId, 'p_new_name': newName});
  }

  /// Delete one of the calling stockist's own private values. Cascades:
  /// every design tagged with it loses that tag.
  Future<void> dnaDeleteMyValue(String valueId) async {
    await supabase.rpc('dna_delete_my_value', params: {'p_value_id': valueId});
  }

  /// The calling stockist's own private values for one attribute, each with
  /// how many designs currently carry it — for a manage/rename/delete screen.
  Future<List<Map<String, dynamic>>> dnaMyValuesWithUsage(
      String attributeId) async {
    try {
      final res = await supabase.rpc('dna_my_values_with_usage',
          params: {'p_attribute_id': attributeId});
      final list = (res as List?) ?? const [];
      return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (e) {
      debugPrint('dnaMyValuesWithUsage failed: $e');
      return [];
    }
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

  /// Buyer-wide DNA facet catalog (every active attribute + value, id+name),
  /// across all stockists. Anonymous-callable — for DNA chips/filter/search on
  /// any buyer surface. Returns [{id,name,is_multi,values:[{id,name}]}].
  Future<List<Map<String, dynamic>>> publicDnaCatalog() async {
    try {
      final res = await supabase.rpc('public_dna_catalog');
      return ((res as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      debugPrint('publicDnaCatalog failed: $e');
      return [];
    }
  }

  /// The logged-in stockist's pickable surface options for the Add Stock picker:
  /// each alias word with its admin canonical, plus admin finishes they have no
  /// word for. The picker shows the word, stores word + canonical. (surface_label)
  Future<List<({String label, String canonical})>> getMySurfaceOptions() async {
    try {
      final res = await supabase.rpc('my_surface_options');
      return ((res as List?) ?? const [])
          .map((e) {
            final m = Map<String, dynamic>.from(e as Map);
            return (
              label: (m['label'] ?? '').toString(),
              canonical: (m['canonical'] ?? '').toString(),
            );
          })
          .where((o) => o.label.isNotEmpty && o.canonical.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('getMySurfaceOptions failed: $e');
      return [];
    }
  }

  /// The logged-in stockist's OWN word per canonical finish, for the stock-list
  /// "Edit conditions" chips: { canonicalFinishName : displayWord }. The chips
  /// show the word but store the canonical. (project_per_brand_surface_mode)
  Future<Map<String, String>> getMySurfaceLabels() async {
    try {
      final res = await supabase.rpc('my_surface_labels');
      final m = res is Map ? Map<String, dynamic>.from(res) : {};
      return m.map((k, v) => MapEntry(k.toString(), (v ?? '').toString()));
    } catch (e) {
      debugPrint('getMySurfaceLabels failed: $e');
      return {};
    }
  }

  /// The buyer-facing DNA catalog as typed [DnaAttribute]s, for buyer screens
  /// still built around the DnaAttribute model (My Suppliers). Same buyer-wide
  /// source as [publicDnaCatalog]: it returns free-text facet values (Series,
  /// Punch Look) regardless of which stockist created them — unlike the stockist
  /// [dnaCatalog], which scopes free-text values to the logged-in stockist and so
  /// hides them from buyers.
  Future<List<DnaAttribute>> publicDnaCatalogAttrs() async {
    final maps = await publicDnaCatalog();
    return maps.map(DnaAttribute.fromJson).toList();
  }

  // ── Design "family" (concept grouping) ─────────────────────────────────────

  /// The family (concept) a design belongs to — every sibling variant (same
  /// stockist + size + name-root), each with live F_stock (0 = out of stock).
  /// Empty when the design has no siblings. Buyer-facing (anon-safe).
  Future<List<Map<String, dynamic>>> designFamily(String designId) async {
    try {
      final res =
          await supabase.rpc('design_family', params: {'p_design_id': designId});
      return ((res as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      debugPrint('designFamily failed: $e');
      return [];
    }
  }

  /// Stockist's own view of a master's family (incl. just itself, incl.
  /// out-of-stock members): { 'family_key': String, 'members': [ … ] }.
  Future<Map<String, dynamic>> myFamilyFor(String libraryId) async {
    try {
      final res =
          await supabase.rpc('my_family_for', params: {'p_library_id': libraryId});
      return res is Map ? Map<String, dynamic>.from(res) : {};
    } catch (e) {
      debugPrint('myFamilyFor failed: $e');
      return {};
    }
  }

  /// Correction: attach a master to a family key (add-to-family), or — by
  /// passing its own id as the key — pull it out to stand alone (remove).
  Future<void> familySetOverride(String libraryId, String familyKey) async {
    await supabase.rpc('family_set_override',
        params: {'p_library_id': libraryId, 'p_family_key': familyKey});
  }

  /// Reset a master back to automatic grouping (drop the correction).
  Future<void> familyClearOverride(String libraryId) async {
    await supabase
        .rpc('family_clear_override', params: {'p_library_id': libraryId});
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
    // Only meaningful with mode 'replace_all'. Precedence: wipeAllBrands (every
    // brand) > wipeBrandIds (just these — a per-row multi-brand file) > brandId
    // (single-brand upload).
    bool wipeAllBrands = false,
    List<String>? wipeBrandIds,
    // M PDF import: build the library (+ images) only, create NO stock rows.
    bool libraryOnly = false,
  }) async {
    try {
      final res = await supabase.rpc('import_stock_batch', params: {
        'p_batch_id': batchId,
        'p_catalog_id': catalogId,
        'p_brand_id': brandId,
        'p_pdf_filename': pdfFilename,
        'p_rows': rows,
        'p_mode': mode,
        'p_wipe_all_brands': wipeAllBrands,
        'p_wipe_brand_ids': wipeBrandIds,
        'p_library_only': libraryOnly,
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

  /// Admin: toggle whether the TilesDesign mark shows on a stockist's banners
  /// (the stockist controls only its position). (td mark admin gate)
  Future<void> setStockistTd(String sequentialId, bool show) async {
    await supabase.rpc('admin_set_stockist_td',
        params: {'p_seq': sequentialId, 'p_show': show});
  }

  /// Admin: opt a stockist into saving customers on dispatch. OFF (default) =
  /// the Customer field is plain text and nothing is stored.
  /// (project_unified_dispatch_customers)
  Future<void> setStockistCustomers(String sequentialId, bool enabled) async {
    await supabase.rpc('admin_set_stockist_customers',
        params: {'p_seq': sequentialId, 'p_enabled': enabled});
  }

  /// Admin: an M stockist's surface convention ('attribute' | 'in_name'). M IS
  /// the factory, so the convention is company-wide; T/W keeps it per brand
  /// (`setBrandSurfaceMode`). (project_per_brand_surface_mode)
  Future<void> setStockistSurfaceMode(String sequentialId, String mode) async {
    try {
      await supabase.rpc('admin_set_stockist_surface_mode',
          params: {'p_seq': sequentialId, 'p_mode': mode});
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  // ─── Banner Video (admin) ───────────────────────────────────────────────
  // A "▶ Watch" video system shown in the top banner of a stockist's /s/ page.
  // Admin manages GLOBAL learning videos + sets each stockist's 4-step display
  // mode (off | admin | mixed | stockist). (project_tutorial_videos_plan)

  /// Admin: the global (admin/owner) learning videos, INCLUDING hidden ones so
  /// the admin can toggle them. Excludes soft-deleted.
  Future<List<Map<String, dynamic>>> adminListVideos() async {
    final res = await supabase.rpc('admin_list_videos');
    return ((res as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// Admin: every active stockist with its current video mode + own-video
  /// counts ({seq, name, city, mode, active_count, lib_count}).
  Future<List<Map<String, dynamic>>> adminStockistVideoModes() async {
    final res = await supabase.rpc('admin_stockist_video_modes');
    return ((res as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// Admin: create ([id] null) or edit a video. [stockistId] null = global.
  /// The server derives the YouTube id from any link form; returns the row id.
  Future<String> adminSaveVideo({
    String? id,
    required String kind, // 'tutorial' | 'collection'
    required String title,
    required String subtitle,
    required String url,
    int sortOrder = 0,
    bool isActive = true,
    String? stockistId,
  }) async {
    final res = await supabase.rpc('admin_save_video', params: {
      'p_id': id,
      'p_kind': kind,
      'p_title': title,
      'p_subtitle': subtitle,
      'p_url': url,
      'p_sort_order': sortOrder,
      'p_is_active': isActive,
      'p_stockist_id': stockistId,
    });
    return res as String;
  }

  /// Admin: show/hide a video (server enforces the 5-active cap for stockist
  /// rows; global rows are uncapped).
  Future<void> adminSetVideoActive(String id, bool active) async {
    await supabase
        .rpc('admin_set_video_active', params: {'p_id': id, 'p_active': active});
  }

  /// Admin: soft-delete a video (24h grace) / restore it within the grace.
  Future<void> adminDeleteVideo(String id) async {
    await supabase.rpc('admin_delete_video', params: {'p_id': id});
  }

  Future<void> adminRestoreVideo(String id) async {
    await supabase.rpc('admin_restore_video', params: {'p_id': id});
  }

  /// Admin: set a stockist's 4-step display mode.
  Future<void> adminSetStockistVideoMode(String sequentialId, String mode) async {
    await supabase.rpc('admin_set_stockist_video_mode',
        params: {'p_seq': sequentialId, 'p_mode': mode});
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

  /// Public (no login): the Banner Video list for a stockist's `/s/` page,
  /// resolved by the same share token. The server applies the stockist's
  /// 4-step mode (off/admin/mixed/stockist) + the mixed 2:1 interleave, so the
  /// client just renders what comes back. Each item:
  /// {id, kind, title, subtitle, youtube_id, video_url, thumbnail, owner}.
  /// Returns [] for mode `off`, an invalid token, or any error.
  Future<List<Map<String, dynamic>>> getPublicVideos(String token) async {
    try {
      final res =
          await supabase.rpc('public_list_videos', params: {'p_token': token});
      return ((res as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e, st) {
      debugPrint('getPublicVideos failed ($token): $e\n$st');
      return [];
    }
  }

  /// The global admin learning videos for the buyer home (no token). Same item
  /// shape as [getPublicVideos]. Returns [] on any error.
  Future<List<Map<String, dynamic>>> getGlobalVideos() async {
    try {
      final res = await supabase.rpc('global_videos');
      return ((res as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e, st) {
      debugPrint('getGlobalVideos failed: $e\n$st');
      return [];
    }
  }

  /// A supplier's Banner Video list for the in-app portfolio, resolved by the
  /// stockist's sequential id (applies the 4-step mode + interleave). Same item
  /// shape as [getPublicVideos]. Returns [] on any error.
  Future<List<Map<String, dynamic>>> getStockistVideos(String sequentialId) async {
    try {
      final res = await supabase
          .rpc('stockist_public_videos', params: {'p_seq': sequentialId});
      return ((res as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e, st) {
      debugPrint('getStockistVideos failed ($sequentialId): $e\n$st');
      return [];
    }
  }

  // ─── Banner Video (stockist "My Videos") ─────────────────────────────────
  // A stockist manages their OWN collection/promo videos; whether they display
  // is governed by the admin-set mode. Each RPC auto-scopes to the caller.

  /// The caller stockist's own videos (INCLUDING hidden).
  Future<List<Map<String, dynamic>>> stockistMyVideos() async {
    final res = await supabase.rpc('stockist_my_videos');
    return ((res as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// The admin-set display mode for the caller stockist (off|admin|mixed|stockist).
  Future<String> stockistMyVideoMode() async {
    final res = await supabase.rpc('stockist_my_video_mode');
    return (res as String?) ?? 'mixed';
  }

  /// Create ([id] null) or edit one of the caller's own videos. Server derives
  /// the YouTube id and enforces the 50-library / 5-active caps.
  Future<String> stockistSaveVideo({
    String? id,
    required String kind,
    required String title,
    required String subtitle,
    required String url,
    int sortOrder = 0,
    bool isActive = true,
  }) async {
    final res = await supabase.rpc('stockist_save_video', params: {
      'p_id': id,
      'p_kind': kind,
      'p_title': title,
      'p_subtitle': subtitle,
      'p_url': url,
      'p_sort_order': sortOrder,
      'p_is_active': isActive,
    });
    return res as String;
  }

  Future<void> stockistSetVideoActive(String id, bool active) async {
    await supabase.rpc('stockist_set_video_active',
        params: {'p_id': id, 'p_active': active});
  }

  Future<void> stockistDeleteVideo(String id) async {
    await supabase.rpc('stockist_delete_video', params: {'p_id': id});
  }

  Future<void> stockistRestoreVideo(String id) async {
    await supabase.rpc('stockist_restore_video', params: {'p_id': id});
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
        tdShow:     s['td_show'] ?? false,
        customersEnabled: s['customers_enabled'] ?? false,
        surfaceMode: (s['surface_mode'] ?? 'in_name').toString(),
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

  /// Buyer: push a finished order's leftover (ordered − dispatched) back into
  /// their basket (my_choices) as a fresh selection AND finalize the old order
  /// (moves it to My Dispatch). Returns how many leftover designs were added.
  /// (project_order_remaining_model — Phase 3 re-order)
  Future<int> reorderRemaining(String inquiryId) async {
    final res = await supabase
        .rpc('reorder_remaining', params: {'p_inquiry': inquiryId});
    return (res as num?)?.toInt() ?? 0;
  }

  /// Buyer closes a completed-short order without re-ordering (they don't want
  /// the rest) → finalizes it into the My Dispatch record.
  Future<void> buyerCloseOrder(String inquiryId) async {
    await supabase
        .rpc('buyer_close_order', params: {'p_inquiry': inquiryId});
  }

  /// Buyer SENDS their basket to a supplier: freezes the order lines, marks it
  /// sent (notifies the stockist), and clears those designs out of My Choice.
  /// [stockistKey] is the supplier's display id (sequential id / public code).
  /// Returns the order token. (project_order_remaining_model — My Choice↔Order split)
  Future<String?> sendOrderToStockist(String stockistKey) async {
    final res = await supabase
        .rpc('send_order_to_stockist', params: {'p_stockist_key': stockistKey});
    return (Map<String, dynamic>.from(res as Map)['token'])?.toString();
  }


  /// Stockist HOLDS a whole order: every line's held_qty = its ordered quantity.
  /// Held boxes (H_Quantity) drop off the buyer-facing F_Stock and stay held until
  /// the stockist un-holds or dispatches. Sets the order to 'locked' (ready to
  /// dispatch). (project_fstock_model — Hold-Quantity model)
  Future<void> holdOrder(String id) async {
    try {
      await supabase.rpc('hold_order', params: {'p_id': id});
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Stockist holds SELECTED quantities per design. [items] = list of
  /// {design_id, held_qty}; each is clamped to that line's ordered quantity.
  Future<void> holdOrderItems(String id, List<Map<String, dynamic>> items) async {
    try {
      await supabase.rpc('hold_order_items',
          params: {'p_id': id, 'p_items': items});
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Stockist releases a held order: clears every line's held_qty (H drops, F is
  /// restored) and returns the order to 'sent'. Keeps the order's items intact.
  Future<void> unholdOrder(String id) async {
    try {
      await supabase.rpc('unhold_order', params: {'p_id': id});
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

  /// Stockist permanently deletes a REJECTED order (removes it from the inquiry
  /// list to keep it clean). Cascades its items + share-link rows.
  Future<void> deleteInquiry(String id) async {
    try {
      await supabase.rpc('delete_inquiry', params: {'p_id': id});
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
  /// [close] decides the fate of any remaining (ordered − dispatched) boxes:
  ///   true  → close the order ('completed'), release the remaining hold →
  ///           the buyer re-orders the rest if they still want it.
  ///   false → keep the order open ('dispatching', a "Part-N"), the remaining
  ///           stays reserved/held → the buyer just waits for the next lot.
  /// (project_dispatch_order_redesign — "order remaining" model)
  ///
  /// [prune] says whether [lines] is the WHOLE order or just this truck.
  ///   true  → lines is the complete order; anything missing from it is deleted
  ///           from the order.
  ///   false → lines is only what is being dispatched now; untouched order lines
  ///           stay on the order with their remaining intact.
  /// ManualDispatchScreen — the one dispatch screen — always passes false: its
  /// rows are "what's on the truck", so true would silently delete the order's
  /// un-dispatched lines. Order lines are edited in Inquiries, not here. No
  /// caller passes true today; the default stays for safety.
  /// (project_unified_dispatch_customers — attach-order)
  Future<Map<String, dynamic>> dispatchInquiry(
    String id,
    List<Map<String, dynamic>> lines, {
    String invoiceNo = '',
    String vehicleNo = '',
    String transporter = '',
    String note = '',
    DateTime? date,
    bool reduceStock = true,
    bool close = true,
    bool prune = true,
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
        'p_reduce_stock': reduceStock,
        'p_close': close,
        'p_prune': prune,
      });
      return Map<String, dynamic>.from(res as Map);
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Stockist sets/clears the free-text customer hint on one of their orders
  /// (who the order is for — no customer profile). (project_dispatch_order_redesign)
  Future<void> setInquiryHint(String inquiryId, String hint) async {
    try {
      await supabase.rpc('set_inquiry_hint',
          params: {'p_id': inquiryId, 'p_hint': hint});
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Stockist creates their own order for a (possibly non-app) customer:
  /// [hint] = customer name/note, [lines] = `[{design_id, quantity}]` from
  /// their F_Stock. Returns `{id, token, connection_code}`.
  /// (project_dispatch_order_redesign)
  Future<Map<String, dynamic>> createStockistOrder(
      String hint, List<Map<String, dynamic>> lines) async {
    try {
      final res = await supabase.rpc('create_stockist_order',
          params: {'p_hint': hint, 'p_lines': lines});
      return Map<String, dynamic>.from(res as Map);
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  // ── Dispatch link (login-free, read-only dispatch receipt on the web) ───────

  /// Stockist mints (or reuses) a share link for one dispatch note; returns its
  /// token. Build the URL as `<shareBaseUrl>/d/<token>`. [days] null = no expiry.
  Future<String?> createDispatchLink(String dispatchNoteId, {int? days}) async {
    try {
      final res = await supabase.rpc('create_dispatch_link',
          params: {'p_note': dispatchNoteId, 'p_days': days});
      return (Map<String, dynamic>.from(res as Map)['token'])?.toString();
    } catch (e) {
      throw '$e'.replaceAll('PostgrestException:', '').split(',').first.trim();
    }
  }

  /// Login-free, read-only view of a dispatch behind a dispatch-link token.
  Future<Map<String, dynamic>?> publicDispatch(String token) async {
    try {
      final res =
          await supabase.rpc('public_dispatch', params: {'p_token': token});
      return res == null ? null : Map<String, dynamic>.from(res as Map);
    } catch (e, st) {
      debugPrint('publicDispatch failed ($token): $e\n$st');
      return null;
    }
  }

  /// Edit an OPEN, no-buyer order: replace its line items + customer hint. Blocked
  /// once held/dispatched or for app-buyer orders. (project_dispatch_order_redesign)
  Future<void> updateStockistOrder(
      String id, String hint, List<Map<String, dynamic>> lines) async {
    try {
      await supabase.rpc('update_order_items',
          params: {'p_id': id, 'p_hint': hint, 'p_lines': lines});
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
              'id, quantity_dispatched, buyer_name, notes, created_at, dispatch_note_id, '
              'designs(name), '
              'dispatch_notes(dispatch_no, invoice_no, vehicle_no, transporter, dispatched_on)')
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
    String state = '',
    String district = '',
    String pincode = '',
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
      'p_state':          state,
      'p_district':       district,
      'p_pincode':        pincode,
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
    try {
      final data = await supabase
          .from('surface_aliases')
          .select('raw_text, display_text, surface_types(name)')
          .eq('stockist_id', stockistUUID);
      final out = <String, List<String>>{};
      for (final row in data) {
        final st = row['surface_types'];
        if (st == null || st['name'] == null) continue;
        final disp = (row['display_text'] as String?)?.trim();
        final word = (disp != null && disp.isNotEmpty)
            ? disp
            : (row['raw_text'] as String);
        (out[st['name'] as String] ??= <String>[]).add(word);
      }
      for (final list in out.values) {
        list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      }
      return out;
    } catch (e, st) {
      debugPrint('getSurfaceWordsByFinish failed ($stockistUUID): $e\n$st');
      return {};
    }
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
      // raw_text (normalised, for import matching) → original word (for display).
      final byKey = <String, String>{};
      for (final w in words) {
        final k = normalizeSurfaceRaw(w);
        if (k.isNotEmpty) byKey.putIfAbsent(k, () => w.trim());
      }
      // Drop this stockist's existing words for this finish that are gone now.
      final existing = await supabase
          .from('surface_aliases')
          .select('id, raw_text')
          .eq('stockist_id', stockistUUID)
          .eq('surface_type_id', stId);
      for (final row in existing) {
        if (!byKey.containsKey(row['raw_text'] as String)) {
          await supabase.from('surface_aliases').delete().eq('id', row['id']);
        }
      }
      // Upsert each remaining word → this finish (repoints if it sat elsewhere).
      // display_text keeps the original casing/spacing buyers + the picker show.
      for (final entry in byKey.entries) {
        await supabase.from('surface_aliases').upsert({
          'stockist_id': stockistUUID,
          'raw_text': entry.key,
          'surface_type_id': stId,
          'display_text': entry.value,
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
        'display_text':    rawText.trim(),
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
