import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

/// Opens a Banner Video in a closable in-app window OVER the catalogue — the
/// dealer never leaves the site. Same on app (native webview) and web (iframe).
///
/// Presented as a full-screen OPAQUE route (not a dialog barrier): on Flutter
/// web the YouTube player is a platform-view `<iframe>`, and platform views
/// rendered inside a translucent dialog/overlay paint blank. A solid route
/// hosts the iframe reliably on both web and app.
///
/// [video] is one item from `public_list_videos` / `global_videos`:
/// {youtube_id, video_url, title, kind, ...}.
Future<void> showVideoLightbox(BuildContext context, Map<String, dynamic> video) {
  return Navigator.of(context).push(PageRouteBuilder(
    opaque: true,
    fullscreenDialog: true,
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (_, __, ___) => _VideoScreen(video: video),
    transitionsBuilder: (_, anim, __, child) =>
        FadeTransition(opacity: anim, child: child),
  ));
}

class _VideoScreen extends StatefulWidget {
  const _VideoScreen({required this.video});
  final Map<String, dynamic> video;
  @override
  State<_VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<_VideoScreen> {
  late final YoutubePlayerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = YoutubePlayerController.fromVideoId(
      videoId: (widget.video['youtube_id'] ?? '').toString(),
      autoPlay: true,
      params: const YoutubePlayerParams(
        showControls: true,
        showFullscreenButton: false,
        mute: false,
        enableCaption: false,
        strictRelatedVideos: true,
      ),
    );
  }

  @override
  void dispose() {
    _controller.close();
    super.dispose();
  }

  Future<void> _openOnYouTube() async {
    final url = (widget.video['video_url'] ?? '').toString();
    if (url.isEmpty) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // 9:16 player, sized to fit the screen.
            Center(
              child: LayoutBuilder(
                builder: (context, c) {
                  final maxH = c.maxHeight * 0.88;
                  final maxW = c.maxWidth * 0.98;
                  var w = maxH * 9 / 16;
                  if (w > maxW) w = maxW;
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: SizedBox(
                      width: w,
                      child: YoutubePlayer(
                        controller: _controller,
                        aspectRatio: 9 / 16,
                      ),
                    ),
                  );
                },
              ),
            ),
            // Fallback for un-embeddable/blocked videos.
            Positioned(
              left: 0,
              right: 0,
              bottom: 6,
              child: Center(
                child: TextButton.icon(
                  onPressed: _openOnYouTube,
                  icon: const Icon(Icons.open_in_new,
                      size: 16, color: Colors.white70),
                  label: const Text('Open in YouTube',
                      style: TextStyle(color: Colors.white70)),
                ),
              ),
            ),
            // Close (✕) — top-right, clear of the status bar via SafeArea.
            Positioned(
              top: 4,
              right: 8,
              child: Material(
                color: Colors.black38,
                shape: const CircleBorder(),
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
