// dart:html is the pragmatic way to embed an <iframe srcdoc> on Flutter web;
// this file is web-only via the conditional export in pano_embed.dart.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// 🌐 Embeds a hosted Pano2VR 360 bundle INLINE on the web build.
///
/// Supabase Storage serves `.html` (and `.xml`) as `text/plain`, so the bundle's
/// `index.html` can't be opened directly. Instead we fetch its HTML, add a
/// `<base href>` pointing at the bundle folder in Storage, and render it via an
/// iframe `srcdoc` — so OUR page provides the HTML context while the player.js,
/// pano.xml and tiles load straight from Storage (CORS is open). (media #9 / P2)
Widget panoEmbed(String indexUrl) => _PanoEmbed(indexUrl);

int _seq = 0; // unique platform-view type per embed

class _PanoEmbed extends StatefulWidget {
  final String indexUrl;
  const _PanoEmbed(this.indexUrl);
  @override
  State<_PanoEmbed> createState() => _PanoEmbedState();
}

class _PanoEmbedState extends State<_PanoEmbed> {
  final String _viewType = 'pano-${_seq++}';
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final u = widget.indexUrl;
      final base = u.substring(0, u.lastIndexOf('/') + 1);
      final resp = await http.get(Uri.parse(u));
      if (resp.statusCode != 200) throw 'HTTP ${resp.statusCode}';
      var doc = resp.body;
      // Absolute base → the bundle's relative refs resolve to Storage.
      doc = doc.contains('<head>')
          ? doc.replaceFirst('<head>', '<head><base href="$base">')
          : '<!doctype html><head><base href="$base"></head>$doc';
      ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) {
        final el = html.IFrameElement()
          ..srcdoc = doc
          ..allowFullscreen = true
          ..style.border = '0'
          ..style.width = '100%'
          ..style.height = '100%';
        return el;
      });
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
          child: Text('Could not load 360: $_error',
              style: const TextStyle(color: Colors.white70)));
    }
    if (!_ready) return const Center(child: CircularProgressIndicator());
    return HtmlElementView(viewType: _viewType);
  }
}
