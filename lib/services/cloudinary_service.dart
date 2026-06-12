import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart'; // debugPrint + Uint8List
import 'package:http/http.dart' as http;
import '../config/app_config.dart';

/// Result of a Cloudinary upload attempt.
///
/// On success [url] holds the `secure_url`; on failure [error] holds a
/// human-readable reason (so callers can surface it instead of guessing).
class CloudinaryResult {
  final String? url;
  final String? error;

  const CloudinaryResult.success(this.url) : error = null;
  const CloudinaryResult.failure(this.error) : url = null;

  bool get ok => url != null;
}

class CloudinaryService {
  /// Upload from a local file path. Returns the secure URL, or null on failure.
  static Future<String?> uploadImage(String filePath) async {
    try {
      final bytes = await File(filePath).readAsBytes();
      final res = await uploadImageBytes(bytes,
          filename: filePath.split(Platform.pathSeparator).last);
      return res.url;
    } catch (e, st) {
      debugPrint('CloudinaryService.uploadImage failed for "$filePath": $e\n$st');
      return null;
    }
  }

  /// Upload from raw bytes (e.g. JPEG extracted from PDF).
  ///
  /// Returns a [CloudinaryResult] describing success (with the secure URL) or
  /// failure (with the error message Cloudinary returned). Never throws.
  ///
  /// Transient network failures (connection dropped/timed out) are retried up
  /// to [maxAttempts] times with a short backoff, since a flaky mobile/WiFi
  /// connection should not permanently lose a photo. A genuine Cloudinary
  /// rejection (non-200 with an error message) is *not* retried — it would
  /// fail again the same way.
  static Future<CloudinaryResult> uploadImageBytes(
    Uint8List bytes, {
    String filename = 'tile.jpg',
    int maxAttempts = 3,
  }) async {
    if (bytes.isEmpty) {
      return const CloudinaryResult.failure('Empty image bytes');
    }
    final uri = Uri.parse(
      'https://api.cloudinary.com/v1_1/${AppConfig.cloudinaryCloudName}/image/upload',
    );

    String lastError = 'Upload failed';
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final request = http.MultipartRequest('POST', uri)
          ..fields['upload_preset'] = AppConfig.cloudinaryUploadPreset
          ..files.add(
              http.MultipartFile.fromBytes('file', bytes, filename: filename));

        final streamed = await request.send();
        final body = await streamed.stream.bytesToString();

        if (streamed.statusCode == 200) {
          final json = jsonDecode(body) as Map<String, dynamic>;
          final url = json['secure_url'] as String?;
          if (url == null) {
            debugPrint('Cloudinary 200 but no secure_url: $body');
            return const CloudinaryResult.failure('No secure_url in response');
          }
          return CloudinaryResult.success(url);
        }

        // Non-200: pull Cloudinary's error message out of the body if present.
        String message = 'HTTP ${streamed.statusCode}';
        try {
          final json = jsonDecode(body) as Map<String, dynamic>;
          final err = json['error'];
          if (err is Map && err['message'] is String) {
            message = err['message'] as String;
          }
        } catch (_) {}
        debugPrint('Cloudinary upload failed ($filename): '
            '${streamed.statusCode} — $message');
        // 5xx is server-side and may be transient → retry; 4xx won't change.
        if (streamed.statusCode >= 500 && attempt < maxAttempts) {
          lastError = message;
          await Future.delayed(_backoff(attempt));
          continue;
        }
        return CloudinaryResult.failure(message);
      } catch (e, st) {
        // Network-level failure (connection abort/timeout/DNS) — retry.
        debugPrint('Cloudinary upload threw ($filename), '
            'attempt $attempt/$maxAttempts: $e\n$st');
        lastError = e.toString();
        if (attempt < maxAttempts) {
          await Future.delayed(_backoff(attempt));
          continue;
        }
      }
    }
    return CloudinaryResult.failure(lastError);
  }

  // Exponential-ish backoff between retry attempts: 500ms, 1s, 1.5s …
  static Duration _backoff(int attempt) =>
      Duration(milliseconds: 500 * attempt);

  /// Rewrites a Cloudinary delivery URL into a resized/compressed **thumbnail**
  /// for grids — `c_limit` scales the WHOLE image down to [width] (never crops,
  /// never upscales), `q_auto`+`f_auto` compress and pick a modern format. The
  /// original upload is untouched, so detail/zoom views still get full quality.
  ///
  /// Non-Cloudinary, asset, empty, or already-transformed URLs are returned
  /// unchanged, so this is safe to call on any image URL.
  static String thumbUrl(String url, {int width = 600}) {
    if (url.isEmpty) return url;
    const marker = '/image/upload/';
    final i = url.indexOf(marker);
    if (i < 0) return url; // not a Cloudinary delivery URL
    final insertAt = i + marker.length;
    final rest = url.substring(insertAt);
    // Already has a transformation (e.g. "w_..", "c_..") → leave it alone.
    if (RegExp(r'^[a-z]{1,3}_').hasMatch(rest)) return url;
    return '${url.substring(0, insertAt)}w_$width,c_limit,q_auto,f_auto/$rest';
  }

  /// Rewrites a Cloudinary URL into a **logo-safe** delivery for the branded
  /// catalog page. Stockists upload logos at wildly different sizes/shapes, so
  /// we normalise WITHOUT distorting or recolouring:
  ///   • `c_fit` into a [size]×[size] box → scales DOWN preserving aspect ratio,
  ///     never crops, never stretches (a wide logo stays wide, square stays
  ///     square). `dpr_auto` keeps it crisp on retina.
  ///   • Colour-safe: `q_100` (no lossy colour shift) and we DON'T use `f_auto`
  ///     (which can flatten a transparent PNG onto white). PNG/transparency is
  ///     preserved by leaving the format as uploaded.
  /// Non-Cloudinary/empty URLs are returned unchanged.
  static String logoUrl(String url, {int size = 240}) {
    if (url.isEmpty) return url;
    const marker = '/image/upload/';
    final i = url.indexOf(marker);
    if (i < 0) return url;
    final insertAt = i + marker.length;
    final rest = url.substring(insertAt);
    if (RegExp(r'^[a-z]{1,3}_').hasMatch(rest)) return url; // already transformed
    return '${url.substring(0, insertAt)}'
        'c_fit,w_$size,h_$size,q_100,dpr_auto/$rest';
  }
}
