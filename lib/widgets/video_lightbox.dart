import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

/// Opens a Banner Video in a closable in-app window OVER the catalogue — the
/// dealer never leaves the site. Same on app (native webview) and web (iframe).
/// [video] is one item from `public_list_videos` / `global_videos`:
/// {youtube_id, video_url, title, kind, ...}.
Future<void> showVideoLightbox(BuildContext context, Map<String, dynamic> video) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close video',
    barrierColor: Colors.black.withValues(alpha: 0.88),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (_, __, ___) => _VideoLightbox(video: video),
    transitionBuilder: (_, anim, __, child) =>
        FadeTransition(opacity: anim, child: child),
  );
}

class _VideoLightbox extends StatefulWidget {
  const _VideoLightbox({required this.video});
  final Map<String, dynamic> video;
  @override
  State<_VideoLightbox> createState() => _VideoLightboxState();
}

class _VideoLightboxState extends State<_VideoLightbox> {
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
    final size = MediaQuery.sizeOf(context);
    // 9:16 vertical; fit within the screen, leaving room for close + fallback.
    final maxH = size.height * 0.80;
    final maxW = size.width * 0.94;
    var w = maxH * 9 / 16;
    if (w > maxW) w = maxW;

    return SafeArea(
      child: Stack(
        children: [
          // Tap the backdrop to dismiss.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(
                    width: w,
                    child: YoutubePlayer(
                      controller: _controller,
                      aspectRatio: 9 / 16,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // Fallback for un-embeddable/blocked videos.
                TextButton.icon(
                  onPressed: _openOnYouTube,
                  icon: const Icon(Icons.open_in_new,
                      size: 16, color: Colors.white70),
                  label: const Text('Open in YouTube',
                      style: TextStyle(color: Colors.white70)),
                ),
              ],
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
    );
  }
}
