import 'package:flutter/material.dart';

/// A compact horizontal strip of admin learning videos for the buyer home.
/// Each card is a thumbnail with a ▶ overlay + title; tapping calls [onPlay]
/// (which opens the closable in-app player). Empty list = renders nothing.
class LearningVideoStrip extends StatelessWidget {
  const LearningVideoStrip({
    super.key,
    required this.videos,
    required this.onPlay,
    this.title = 'Learn how to use this',
  });

  final List<Map<String, dynamic>> videos;
  final void Function(Map<String, dynamic> video) onPlay;

  /// Section heading (buyer home = "Learn how to use this"; a supplier
  /// portfolio = e.g. "Videos").
  final String title;

  static const _navy = Color(0xFF1B4F72);

  @override
  Widget build(BuildContext context) {
    if (videos.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
            child: Row(
              children: [
                const Icon(Icons.play_circle_outline, size: 18, color: _navy),
                const SizedBox(width: 6),
                Text(title,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: _navy)),
              ],
            ),
          ),
          SizedBox(
            height: 116,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: videos.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, i) => _card(videos[i]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(Map<String, dynamic> v) {
    final thumb = (v['thumbnail'] ?? '').toString();
    final title = (v['title'] ?? '').toString().trim();
    return GestureDetector(
      onTap: () => onPlay(v),
      child: SizedBox(
        width: 168,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                children: [
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: thumb.isEmpty
                        ? Container(color: Colors.grey.shade300)
                        : Image.network(thumb,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                Container(color: Colors.grey.shade300)),
                  ),
                  Positioned.fill(
                    child: Center(
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.play_arrow_rounded,
                            color: Colors.white, size: 22),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              title.isEmpty ? 'Watch' : title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, height: 1.2),
            ),
          ],
        ),
      ),
    );
  }
}
