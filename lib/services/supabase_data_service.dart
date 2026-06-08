import 'package:flutter/foundation.dart'; // debugPrint
import '../models/tile_design.dart';
import '../models/stockist.dart';
import '../models/end_user.dart';
import '../models/surface_type.dart';
import 'supabase_auth_service.dart';
import '../models/choice_state.dart';
import '../main.dart';

/// Normalises a raw PDF surface word for alias matching: uppercase, strip
/// everything but A–Z/0–9. So "Punch Ghr.", "PUNCH-GHR" and "punchghr" all
/// collapse to the same key. Shared by the alias lookup and the learn path.
String normalizeSurfaceRaw(String raw) =>
    raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

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
        faceImageUrls: List<String>.from(d['face_image_urls'] ?? []),
        stockistId:   d['stockists'] != null
            ? (d['stockists']['sequential_id'] ?? seqId ?? '')
            : (seqId ?? ''),
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
          .select('*, stockists!inner(sequential_id, is_active, priority)')
          .eq('stockists.is_active', true)
          .neq('status', 'out_of_stock')
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
      return getDesignsByStockist(s['id'] as String);
    } catch (_) {
      return [];
    }
  }

  Future<List<TileDesign>> getDesignsByStockist(String stockistUUID) async {
    try {
      final data = await supabase
          .from('designs')
          .select('*, stockists(sequential_id)')
          .eq('stockist_id', stockistUUID)
          .order('created_at', ascending: false);
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
              .select('*, stockists!inner(sequential_id, is_active, priority)')
              .eq('stockists.is_active', true)
              .neq('status', 'out_of_stock');

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
    required List<String> faceImageUrls,
    String? finishLabel,
  }) async {
    try {
      final row = await supabase.from('designs').insert({
        'stockist_id':   stockistUUID,
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
        city:      s['city'],
        state:     s['state'],
        address:   s['address'] ?? '',
        priority:  (s['priority'] as num?)?.toDouble() ?? 0,
        gstNumber: s['gst_number'] ?? '',
        stockistType: s['stockist_type'] ?? '',
        isActive:  s['is_active'] ?? true,
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

  // ── registration requests (self-signup → admin approval) ───────────────────

  /// Public: submit a self-registration request (creates NO login). Throws the
  /// server message on failure (e.g. email already exists / pending).
  Future<void> submitRegistrationRequest({
    required String email,
    required String password,
    required String companyName,
    required String contactPerson,
    String phone = '',
    String city = '',
    String? gstNumber,
  }) async {
    await supabase.rpc('submit_registration_request', params: {
      'p_email':          email,
      'p_password':       password,
      'p_company_name':   companyName,
      'p_contact_person': contactPerson,
      'p_phone':          phone,
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
    final data = await query.order('sort_order');
    return data.map<SurfaceType>((s) => SurfaceType.fromJson(s)).toList();
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
}
