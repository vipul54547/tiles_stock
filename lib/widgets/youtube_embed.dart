// Conditional export: a raw YouTube <iframe> embed for Flutter web, and a
// harmless stub elsewhere. On web, youtube_player_iframe's player throws (whole
// route renders as the release gray error widget), so the web build embeds a
// plain iframe via HtmlElementView instead. Mobile keeps using
// youtube_player_iframe (native webview), which works.
export 'youtube_embed_stub.dart'
    if (dart.library.js_interop) 'youtube_embed_web.dart';
