import 'dart:async';
import 'package:flutter/material.dart';

/// The top banner slot that alternates between the shop-identity banner (the
/// [child] — the existing BannerView) and a Banner Video promo card, with a
/// smooth crossfade. Shop identity is the default/home state and always
/// returns, so the banner never stops doing its identity job. Zero extra
/// height: both states share the same 2.5:1 slot, so tiles are never pushed
/// down. Tapping the video state (or the persistent ▶ badge) calls [onPlay].
///
/// If [videos] is empty this is a perfect no-op — it just returns [child].
class AlternatingBanner extends StatefulWidget {
  const AlternatingBanner({
    super.key,
    required this.child,
    required this.videos,
    required this.onPlay,
    this.brandColor = const Color(0xFF1B4F72),
  });

  final Widget child;
  final List<Map<String, dynamic>> videos;
  final void Function(Map<String, dynamic> video) onPlay;
  final Color brandColor;

  @override
  State<AlternatingBanner> createState() => _AlternatingBannerState();
}

class _AlternatingBannerState extends State<AlternatingBanner> {
  static const _identityDwell = Duration(seconds: 5);
  static const _videoDwell = Duration(seconds: 4);

  Timer? _timer;
  bool _showingVideo = false;
  int _videoIdx = 0;

  @override
  void initState() {
    super.initState();
    if (widget.videos.isNotEmpty) _scheduleNext();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _scheduleNext() {
    _timer?.cancel();
    _timer = Timer(_showingVideo ? _videoDwell : _identityDwell, () {
      if (!mounted) return;
      setState(() {
        if (_showingVideo) {
          // video → identity, queue the next video for its next turn
          _showingVideo = false;
          _videoIdx = (_videoIdx + 1) % widget.videos.length;
        } else {
          _showingVideo = true;
        }
      });
      _scheduleNext();
    });
  }

  Map<String, dynamic> get _current => widget.videos[_videoIdx];

  @override
  Widget build(BuildContext context) {
    // No videos → the banner behaves exactly as before.
    if (widget.videos.isEmpty) return widget.child;

    return LayoutBuilder(
      builder: (context, c) {
        // Same height rule as BannerView (width / 2.5, capped) so the slot is
        // identical whether identity or video is showing — zero extra height.
        final h = (c.maxWidth / 2.5).clamp(0.0, 200.0);
        return SizedBox(
          width: double.infinity,
          height: h,
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 550),
                child: _showingVideo
                    ? _videoCard(_current, h, key: ValueKey('vid_$_videoIdx'))
                    : KeyedSubtree(
                        key: const ValueKey('identity'), child: widget.child),
              ),
              // Persistent ▶ badge during the identity state — teaches that the
              // banner is watchable and is tappable any time.
              if (!_showingVideo)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: _playBadge(
                      onTap: () => widget.onPlay(widget.videos[_videoIdx])),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _playBadge({required VoidCallback onTap}) => Material(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.play_arrow_rounded, color: Colors.white, size: 18),
                SizedBox(width: 3),
                Text('Watch',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
      );

  Widget _videoCard(Map<String, dynamic> v, double h, {required Key key}) {
    final thumb = (v['thumbnail'] ?? '').toString();
    final kind = (v['kind'] ?? 'tutorial').toString();
    final title = (v['title'] ?? '').toString().trim();
    final lead = kind == 'collection' ? 'New Series' : 'Watch';
    final label = title.isEmpty
        ? (kind == 'collection' ? 'New Series' : 'How to use this catalogue')
        : '$lead · $title';

    return GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onPlay(v),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (thumb.isNotEmpty)
            Image.network(thumb, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _gradient())
          else
            _gradient(),
          // Legibility veil.
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.center,
                  colors: [Colors.black87, Colors.black26],
                ),
              ),
            ),
          ),
          // Centre play glyph.
          Center(
            child: Container(
              width: (h * 0.28).clamp(34.0, 56.0),
              height: (h * 0.28).clamp(34.0, 56.0),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white70, width: 2),
              ),
              child: const Icon(Icons.play_arrow_rounded,
                  color: Colors.white, size: 30),
            ),
          ),
          // Bottom label.
          Positioned(
            left: 12,
            right: 12,
            bottom: 10,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.play_arrow_rounded,
                    color: Colors.white, size: 18),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        shadows: [Shadow(blurRadius: 4, color: Colors.black87)]),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _gradient() => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              widget.brandColor,
              Color.lerp(widget.brandColor, Colors.black, 0.35)!
            ],
          ),
        ),
      );
}
