import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;

/// True on the Windows desktop build only.
///
/// Uses `defaultTargetPlatform` rather than `dart:io`'s `Platform` on purpose: `dart:io` is not
/// available on web, and this is read from screens that the web build also compiles.
///
/// 🔑 Gate anything that reads a FOLDER TREE on this. Folder import needs `dart:io` to walk a
/// directory, which rules web out entirely, and Android's scoped storage means a directory the
/// user picked is often not readable by `dart:io` anyway — it would fail on the device, silently,
/// after he had already done the work of selecting it. The stockist's images live on his PC.
bool get isWindowsDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
