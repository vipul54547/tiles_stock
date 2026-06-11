import 'package:flutter/foundation.dart'; // debugPrint
import '../models/tile_design.dart';
import '../models/stockist.dart';
import '../models/end_user.dart';
import '../models/surface_type.dart';
import '../models/app_notification.dart';
import '../models/tile_size.dart';
import '../models/stock_catalog.dart';
import '../models/share_link.dart';
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

  TileDesign _toDesign(Map<String, dynamic> d, {String? seqId}) => TileDesign(
        id:           d['id'],
        name:         d['name'],
        size:         d['size'],
        boxQuantity:  d['box_quantity'] ?? 0,
        surfaceType:  d['surface_type'],
        finishLabel:  d['finish_label'],
        piecesPerBox: d['pieces_per_box'] ?? 0,
        boxWeightKg:  (d['box_weight_kg']  ?? 0).toDouble(),
        thicknessMm:  (d['thickness_mm']   ?? 0).toDouble(),
        colour:       d['colour']    ?? '',
        boxPrice:     (d['box_price'] ?? 0).toDouble(),
        tileType:     d['tile_type'] ?? '',
        faceImageUrls: List<String>.from(d['face_image_urls'] ?? []),
        stockistId:   d['stockists'] != null
            ? (d['stockists']['sequential_id'] ?? seqId ?? '')
            : (seqId ?? ''),
        catalogId:    d['catalog_id'] as String?,
        updatedAt:  DateTime.parse(d['updated_at']),
        quality:    d['quality']    ?? 'Standard',
        stockType:  d['stock_type'] ?? 'Regular',
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

  // ── designs ───────────────────────────────────────────────────────────────

  Future<List<TileDesign>> getAllDesigns() async {
    try {
      // Guests read the stockist-free `public_designs` view (they can't read the
      // stockists table). Members get the normal join (drops deactivated
      // stockists via the inner-join is_active filter).
      if (isGuest) {
        final data = await supabase
            .from('public_designs')
            .select()
            .order('created_at', ascending: false);
        return data.map<TileDesign>((d) => _toDesign(d)).toList();
      }
      final data = await supabase
          .from('designs')
          .select('*, stockists!inner(sequential_id, is_active, is_listed, priority)')
          .eq('stockists.is_active', true)
          .eq('is_market_visible', true) // only public-catalog stock in the market
          .neq('status', 'out_of_stock')
          .gt('box_quantity', 0) // never show 0-stock to buyers
          .order('created_at', ascending: false);
      return data.map<TileDesign>((d) => _toDesign(d)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<TileDesign>> getDesignsByStockistSeqId(String seqId) async {
    try {
      // Deactivated stockist → no portfolio for buyers.
      final s = await supabase
          .from('stockists')
          .select('id')
          .eq('sequential_id', seqId)
          .eq('is_active', true)
          .single();
      // Buyer portfolio → only in-stock designs.
      return getDesignsByStockist(s['id'] as String, inStockOnly: true);
    } catch (_) {
      return [];
    }
  }

  /// [inStockOnly] true hides out-of-stock / 0-box designs (buyer portfolio).
  /// The stockist's own dashboard leaves it false so they can see & restock them.
  Future<List<TileDesign>> getDesignsByStockist(String stockistUUID,
      {bool inStockOnly = false}) async {
    try {
      var query = supabase
          .from('designs')
          .select('*, stockists(sequential_id)')
          .eq('stockist_id', stockistUUID);
      if (inStockOnly) {
        // Buyer view of a stockist's portfolio: in-stock AND public-catalog only
        // (private-catalog designs are reachable only via their own link).
        query = query
            .neq('status', 'out_of_stock')
            .gt('box_quantity', 0)
            .eq('is_market_visible', true);
      }
      final data = await query.order('created_at', ascending: false);
      return data.map<TileDesign>((d) => _toDesign(d)).toList();
    } catch (e, st) {
      debugPrint('SupabaseDataService.getDesignsByStockist failed ($stockistUUID): $e\n$st');
      return [];
    }
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
      // Guests query the stockist-free view; members get the active-stockist
      // join. (Guests can't filter by stockist — they have no stockist info.)
      var query = isGuest
          ? supabase.from('public_designs').select()
          : supabase
              .from('designs')
              .select('*, stockists!inner(sequential_id, is_active, is_listed, priority)')
              .eq('stockists.is_active', true)
              .eq('is_market_visible', true) // only public-catalog stock in market
              .neq('status', 'out_of_stock')
              .gt('box_quantity', 0); // never show 0-stock to buyers

      // If filtering by stockist, look up UUID first (members only).
      if (!isGuest && stockistSequentialId != null) {
        final s = await supabase
            .from('stockists')
            .select('id')
            .eq('sequential_id', stockistSequentialId)
            .single();
        query = query.eq('stockist_id', s['id']);
      }
      if (sizes        != null && sizes.isNotEmpty)        query = query.inFilter('size',         sizes);
      if (surfaceTypes != null && surfaceTypes.isNotEmpty) query = query.inFilter('surface_type',  surfaceTypes);
      if (colours      != null && colours.isNotEmpty)      query = query.inFilter('colour',        colours);
      if (qualities    != null && qualities.isNotEmpty)    query = query.inFilter('quality',       qualities);
      if (tileTypes    != null && tileTypes.isNotEmpty)    query = query.inFilter('tile_type',     tileTypes);
      if (stockType    != null && stockType != 'Both')     query = query.eq('stock_type',          stockType);
      if (minQty       != null)                            query = query.gte('box_quantity',        minQty);
      if (maxQty       != null)                            query = query.lte('box_quantity',        maxQty);

      final data = await query.order('created_at', ascending: false);
      return data.map<TileDesign>((d) => _toDesign(d)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<String?> addDesign({
    required String stockistUUID,
    required String name,
    required String size,
    required String surfaceType,
    required String quality,
    required String colour,
    required String stockType,
    required int    boxQuantity,
    required int    piecesPerBox,
    required double boxWeightKg,
    required double thicknessMm,
    required double boxPrice,
    String tileType = '',
    required List<String> faceImageUrls,
    String? finishLabel,
    String? catalogId,
  }) async {
    try {
      final row = await supabase.from('designs').insert({
        'stockist_id':   stockistUUID,
        'catalog_id':    catalogId,
        'name':          name,
        'size':          size,
        'surface_type':  surfaceType,
        'finish_label':  finishLabel,
        'quality':       quality,
        'colour':        colour,
        'stock_type':    stockType,
        'box_quantity':  boxQuantity,
        'pieces_per_box': piecesPerBox,
        'box_weight_kg': boxWeightKg,
        'thickness_mm':  thicknessMm,
        'box_price':     boxPrice,
        'tile_type':     tileType,
        'face_image_urls': faceImageUrls,
      }).select().single();
      return row['id'] as String?;
    } catch (e, st) {
      debugPrint('SupabaseDataService.addDesign failed ("$name"): $e\n$st');
      return null;
    }
  }

  Future<TileDesign?> getDesignById(String id) async {
    try {
      final data = await supabase
          .from('designs')
          .select('*, stockists(sequential_id)')
          .eq('id', id)
          .single();
      return _toDesign(data);
    } catch (_) {
      return null;
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

  /// A stockist's catalogs (public + private), in display order.
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

  /// The stockist's default public catalog (the one new uploads target by
  /// default) — the lowest-sorted public catalog.
  Future<StockCatalog?> defaultCatalog(String stockistUUID) async {
    final all = await getCatalogs(stockistUUID);
    for (final c in all) {
      if (!c.isPrivate && c.isActive) return c;
    }
    return all.isEmpty ? null : all.first;
  }

  /// Create a catalog. Private creation is gated by the stockist's admin-granted
  /// `can_create_private_catalog` (enforced here and by RLS on the column).
  Future<String?> addCatalog(String stockistUUID, String name,
      {bool private = false}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw 'Catalog name cannot be empty.';
    try {
      final existing = await supabase
          .from('stock_catalogs')
          .select('sort_order')
          .eq('stockist_id', stockistUUID)
          .order('sort_order', ascending: false)
          .limit(1);
      final nextOrder =
          (existing.isEmpty ? 0 : (existing.first['sort_order'] as int)) + 10;
      final row = await supabase
          .from('stock_catalogs')
          .insert({
            'stockist_id': stockistUUID,
            'name': trimmed,
            'visibility': private ? 'private' : 'public',
            'show_in_marketplace': !private, // private never in marketplace
            'sort_order': nextOrder,
          })
          .select('id')
          .single();
      return row['id'] as String?;
    } catch (e, st) {
      debugPrint('addCatalog failed ($name): $e\n$st');
      rethrow;
    }
  }

  Future<void> renameCatalog(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw 'Catalog name cannot be empty.';
    await supabase.from('stock_catalogs').update({'name': trimmed}).eq('id', id);
  }

  /// Toggle a PUBLIC catalog's marketplace visibility (the "show in app" switch).
  Future<void> setCatalogMarketplace(String id, bool show) async {
    await supabase
        .from('stock_catalogs')
        .update({'show_in_marketplace': show}).eq('id', id);
  }

  Future<void> setCatalogActive(String id, bool active) async {
    await supabase
        .from('stock_catalogs')
        .update({'is_active': active}).eq('id', id);
  }

  Future<void> deleteCatalog(String id) async {
    await supabase.from('stock_catalogs').delete().eq('id', id);
  }

  // ── stockists ─────────────────────────────────────────────────────────────

  /// All stockists. [activeOnly] true (the default) keeps the public/portfolio
  /// behaviour; admin management passes false to also see deactivated ones.
  Future<List<Stockist>> getAllStockists({bool activeOnly = true}) async {
    if (isGuest) return []; // guests never receive stockist data
    try {
      var query = supabase.from('stockists').select();
      if (activeOnly) query = query.eq('is_active', true);
      final data = await query.order('sequential_id');
      return data.map<Stockist>((s) => _toStockist(s)).toList();
    } catch (_) {
      return [];
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

  /// Admin: grant/revoke a stockist's permission to create PRIVATE catalogs
  /// (the Father & Child gate — also the hook for paid/special features).
  Future<void> setStockistPrivateCatalog(
      String sequentialId, bool allowed) async {
    await supabase.rpc('admin_set_private_catalog',
        params: {'p_seq': sequentialId, 'p_allowed': allowed});
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

  /// The calling stockist's share links: the always-on Permanent (from
  /// share_token) first, then any active create-on-demand links.
  Future<List<ShareLink>> getMyShareLinks() async {
    try {
      final res = await supabase.rpc('my_share_links');
      final list = (res as List?) ?? const [];
      return list
          .map((e) => ShareLink.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (e, st) {
      debugPrint('getMyShareLinks failed: $e\n$st');
      return [];
    }
  }

  /// Creates a new share link for the calling stockist. [duration] is one of
  /// 'permanent','1week','1month','3month','6month','1year'. Returns true on
  /// success.
  Future<bool> createShareLink(String duration) async {
    try {
      await supabase.rpc('create_share_link', params: {'p_duration': duration});
      return true;
    } catch (e, st) {
      debugPrint('createShareLink($duration) failed: $e\n$st');
      return false;
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
      final s = await supabase
          .from('stockists')
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
        name:      s['name'],
        email:     '',
        phone:     s['phone'],
        countryCode: s['country_code'] ?? '+91',
        city:      s['city'],
        state:     s['state'],
        address:   s['address'] ?? '',
        priority:  (s['priority'] as num?)?.toDouble() ?? 0,
        gstNumber: s['gst_number'] ?? '',
        stockistType: s['stockist_type'] ?? '',
        isActive:  s['is_active'] ?? true,
        isListed:  s['is_listed'] ?? true,
        shareToken: s['share_token'] ?? '',
        canCreatePrivateCatalog: s['can_create_private_catalog'] ?? false,
        createdAt: DateTime.parse(s['created_at']),
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

      final stockist = await supabase
          .from('stockists')
          .select('id')
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
        'stockist_id': stockist['id'],
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
  /// screen uses this to block deleting an in-use finish.
  Future<int> countDesignsUsingSurface(String name) async {
    final data =
        await supabase.from('designs').select('id').eq('surface_type', name);
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

  // ── shared design-image library ────────────────────────────────────────────
  //
  // A canonical photo per (design name, size), shared across stockists, so an
  // Excel import or an image-less PDF row can auto-fill a picture and the same
  // photo isn't re-uploaded twice. First contributor wins; the library never
  // overwrites an existing image (admins curate). It is an IMAGE lookup only —
  // each stockist still owns their own stock rows.

  /// Looks up library images for a batch of (name, size) pairs. Returns a map
  /// keyed by [designImageKey] → image URL; designs absent from the library
  /// simply don't appear. Used before saving an import to fill blank photos.
  Future<Map<String, String>> lookupDesignImages(
      List<(String name, String size)> items) async {
    final nameKeys = <String>{};
    for (final it in items) {
      final nk = normalizeDesignNameKey(it.$1);
      if (nk.isNotEmpty) nameKeys.add(nk);
    }
    if (nameKeys.isEmpty) return {};
    final out = <String, String>{};
    try {
      final list = nameKeys.toList();
      for (var i = 0; i < list.length; i += 200) {
        final chunk = list.sublist(i, (i + 200).clamp(0, list.length));
        final rows = await supabase
            .from('design_images')
            .select('name_key,size_key,image_url')
            .inFilter('name_key', chunk);
        for (final r in rows) {
          out['${r['name_key']}|${r['size_key']}'] = r['image_url'] as String;
        }
      }
    } catch (e, st) {
      debugPrint('lookupDesignImages failed: $e\n$st');
    }
    return out;
  }

  /// Contributes a single image to the library for (name, size). First writer
  /// wins — an existing canonical image is never overwritten. No-op on an empty
  /// key/url. Used by the in-design camera/gallery save.
  Future<void> contributeDesignImage({
    required String name,
    required String size,
    required String imageUrl,
    String? source,
    String? stockistUUID,
  }) async {
    final nk = normalizeDesignNameKey(name);
    if (nk.isEmpty || imageUrl.isEmpty) return;
    try {
      await supabase.from('design_images').upsert({
        'name_key': nk,
        'size_key': normalizeSizeKey(size),
        'image_url': imageUrl,
        'source': source,
        'contributed_by': stockistUUID,
      }, onConflict: 'name_key,size_key', ignoreDuplicates: true);
    } catch (e, st) {
      debugPrint('contributeDesignImage failed ("$name"): $e\n$st');
    }
  }

  /// Bulk variant for a PDF import: contributes many freshly-uploaded photos in
  /// one insert-or-ignore. Deduped by key within the batch. First writer wins.
  Future<void> contributeDesignImages(
      List<({String name, String size, String url})> items,
      {String? source, String? stockistUUID}) async {
    final seen = <String>{};
    final rows = <Map<String, dynamic>>[];
    for (final it in items) {
      final nk = normalizeDesignNameKey(it.name);
      if (nk.isEmpty || it.url.isEmpty) continue;
      final sk = normalizeSizeKey(it.size);
      if (!seen.add('$nk|$sk')) continue;
      rows.add({
        'name_key': nk,
        'size_key': sk,
        'image_url': it.url,
        'source': source,
        'contributed_by': stockistUUID,
      });
    }
    if (rows.isEmpty) return;
    try {
      await supabase.from('design_images').upsert(rows,
          onConflict: 'name_key,size_key', ignoreDuplicates: true);
    } catch (e, st) {
      debugPrint('contributeDesignImages failed: $e\n$st');
    }
  }
}
