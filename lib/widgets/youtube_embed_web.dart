import 'dart:ui_web' as ui_web;
import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

// One registration per video id (registerViewFactory throws if the same
// viewType is registered twice).
final Set<String> _registered = {};

/// Web-only: a plain YouTube `<iframe>` embedded as a platform view. Reliable on
/// Flutter web, where youtube_player_iframe's player throws. Fills its parent.
Widget buildYoutubeEmbed(String videoId) {
  final viewType = 'yt-iframe-$videoId';
  if (_registered.add(viewType)) {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) {
      final el = web.document.createElement('iframe') as web.HTMLIFrameElement;
      el.src =
          'https://www.youtube.com/embed/$videoId?autoplay=1&playsinline=1&rel=0&modestbranding=1';
      el.allow = 'autoplay; encrypted-media; picture-in-picture; fullscreen';
      el.allowFullscreen = true;
      el.style.border = 'none';
      el.style.width = '100%';
      el.style.height = '100%';
      return el;
    });
  }
  return HtmlElementView(viewType: viewType);
}
