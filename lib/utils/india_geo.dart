import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

/// Structured India location for the stockist profile.
///
/// State→district lists ship **inside the app** (`assets/geo/in_districts.json`,
/// ~722 districts) so the profile dropdowns work fully offline. A pincode lookup
/// rides the free India Post API for the "type pincode, auto-fill the rest"
/// convenience — it degrades gracefully to manual entry on any failure.
class PincodeResult {
  final String state;
  final String district;
  final String city; // sensible default; the stockist can edit it
  const PincodeResult(this.state, this.district, this.city);
}

class IndiaGeo {
  static Map<String, List<String>>? _cache;

  static Future<Map<String, List<String>>> _data() async {
    if (_cache != null) return _cache!;
    final raw = await rootBundle.loadString('assets/geo/in_districts.json');
    final m = jsonDecode(raw) as Map<String, dynamic>;
    _cache = m.map(
        (k, v) => MapEntry(k, (v as List).map((e) => e.toString()).toList()));
    return _cache!;
  }

  /// All states/UTs, alphabetical.
  static Future<List<String>> states() async =>
      (await _data()).keys.toList()..sort();

  /// Districts for a state (empty if the state isn't in the bundle).
  static Future<List<String>> districts(String state) async =>
      (await _data())[state] ?? const [];

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  /// Maps a loose state name (e.g. from the pincode API) to the exact bundled
  /// key so the dropdown can pre-select it. Falls back to the input unchanged.
  static Future<String> canonicalState(String s) async {
    if (s.isEmpty) return s;
    final n = _norm(s);
    for (final k in (await _data()).keys) {
      final kn = _norm(k);
      if (kn == n || kn.startsWith(n)) return k;
    }
    return s;
  }

  /// Maps a loose district name to the exact bundled key within [state].
  static Future<String> canonicalDistrict(String state, String d) async {
    if (d.isEmpty) return d;
    final n = _norm(d);
    for (final k in await districts(state)) {
      if (_norm(k) == n) return k;
    }
    return d;
  }

  /// Look up state/district/city for a 6-digit pincode. Returns null on any
  /// failure (offline, invalid pin, unexpected shape) → caller falls back to
  /// manual entry, so nothing ever blocks on this.
  static Future<PincodeResult?> lookupPincode(String pin) async {
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) return null;
    try {
      final res = await http
          .get(Uri.parse('https://api.postalpincode.in/pincode/$pin'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body);
      if (body is! List || body.isEmpty) return null;
      final first = body.first as Map<String, dynamic>;
      if (first['Status'] != 'Success') return null;
      final offices = first['PostOffice'];
      if (offices is! List || offices.isEmpty) return null;
      final po = offices.first as Map<String, dynamic>;
      final state = (po['State'] ?? '').toString().trim();
      final district = (po['District'] ?? '').toString().trim();
      final block = (po['Block'] ?? '').toString().trim();
      // City default: the Block (taluka town) is the actual locality — often more
      // accurate than the administrative District (e.g. 363641 → Block "Morbi",
      // District "Rajkot"). Fall back to District, then the post-office Name. The
      // stockist can always edit it.
      final city = block.isNotEmpty
          ? block
          : (district.isNotEmpty ? district : (po['Name'] ?? '').toString().trim());
      final cState = await canonicalState(state);
      final cDist = await canonicalDistrict(cState, district);
      return PincodeResult(cState, cDist, city);
    } catch (e) {
      debugPrint('pincode lookup failed ($pin): $e');
      return null;
    }
  }
}
