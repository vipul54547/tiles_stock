import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';

/// 🖼️ Uploads a Pano2VR 360 bundle FOLDER to the public `portfolio-360`
/// Storage bucket, preserving its structure, and returns the public URL of its
/// `index.html`. Windows-only (walks a directory tree with `dart:io`, like the
/// image-folder import). (project_media_portfolio_ddpi P2)
///
/// [prefix] is the object path prefix, e.g. `<stockist_id>/<bundle_id>`. Files
/// land at `<prefix>/<relative path>`, so the bundle's own relative links
/// (`tiles/…`, `pano2vr_player.js`) resolve correctly under the served URL.
class PanoUpload {
  static const _bucket = 'portfolio-360';

  /// Returns the index.html public URL. Throws if the folder has no index.html.
  static Future<String> uploadBundle(
    String dirPath, {
    required String prefix,
    void Function(int done, int total)? onProgress,
  }) async {
    final dir = Directory(dirPath);
    final root = dir.path;
    final files = dir
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .toList();
    if (files.isEmpty) throw 'That folder is empty.';
    final hasIndex =
        files.any((f) => _base(f.path).toLowerCase() == 'index.html');
    if (!hasIndex) {
      throw 'No index.html — pick the Pano2VR bundle folder (the one with '
          'index.html, pano.xml and the tiles).';
    }

    final storage = Supabase.instance.client.storage.from(_bucket);
    var done = 0;
    // Upload in small concurrent batches — 1600+ files, one request each.
    const batch = 8;
    for (var i = 0; i < files.length; i += batch) {
      final slice = files.sublist(i, (i + batch).clamp(0, files.length));
      await Future.wait(slice.map((f) async {
        final rel = _rel(f.path, root); // Storage keys use forward slashes
        await storage.uploadBinary(
          '$prefix/$rel',
          f.readAsBytesSync(),
          fileOptions: FileOptions(
              contentType: _mime(f.path), upsert: true, cacheControl: '3600'),
        );
      }));
      done += slice.length;
      onProgress?.call(done, files.length);
    }
    return storage.getPublicUrl('$prefix/index.html');
  }

  static String _base(String path) =>
      path.replaceAll('\\', '/').split('/').last;

  // Path relative to [root], normalised to forward slashes with no leading sep.
  static String _rel(String path, String root) {
    var rel = path.substring(root.length);
    rel = rel.replaceAll('\\', '/');
    while (rel.startsWith('/')) {
      rel = rel.substring(1);
    }
    return rel;
  }

  static String _mime(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot < 0 ? '' : path.substring(dot).toLowerCase();
    switch (ext) {
      case '.html':
      case '.htm':
        return 'text/html';
      case '.js':
        return 'text/javascript';
      case '.xml':
        return 'application/xml';
      case '.css':
        return 'text/css';
      case '.json':
        return 'application/json';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.svg':
        return 'image/svg+xml';
      default:
        return 'application/octet-stream';
    }
  }
}
