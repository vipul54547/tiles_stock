import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// A stable, per-install identifier used to enforce the per-user device limit.
/// Generated once on first use and persisted, so it survives logout/login on
/// the same install (a reinstall produces a new id = a new "device").
class DeviceId {
  static const _key = 'device_id';
  static String? _cached;

  static Future<String> get() async {
    if (_cached != null) return _cached!;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_key);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await prefs.setString(_key, id);
    }
    _cached = id;
    return id;
  }
}
