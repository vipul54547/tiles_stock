import 'package:flutter/material.dart';

/// A SLIM one-line bar (not a big thumbnail strip) that opens a small sheet
/// listing the videos — keeps the feature discoverable without eating a third
/// of the screen. Used on the buyer home and the in-app supplier portfolio.
/// Empty list = renders nothing.
class LearningVideoStrip extends StatelessWidget {
  const LearningVideoStrip({
    super.key,
    required this.videos,
    required this.onPlay,
    this.title = 'Learn how to use this',
  });

  final List<Map<String, dynamic>> videos;
  final void Function(Map<String, dynamic> video) onPlay;

  /// Bar label (buyer home = "Learn how to use this"; a portfolio = "Videos").
  final String title;

  static const _navy = Color(0xFF1B4F72);

  @override
  Widget build(BuildContext context) {
    if (videos.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: Material(
        color: _navy.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _openList(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.play_circle_outline, size: 20, color: _navy),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('$title · ${videos.length}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: _navy)),
                ),
                const Icon(Icons.chevron_right, size: 20, color: _navy),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openList(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.play_circle_outline, size: 20, color: _navy),
                  const SizedBox(width: 8),
                  Text(title,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: _navy)),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: videos.length,
                itemBuilder: (_, i) => _row(sheetCtx, videos[i]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext sheetCtx, Map<String, dynamic> v) {
    final thumb = (v['thumbnail'] ?? '').toString();
    final title = (v['title'] ?? '').toString().trim();
    final subtitle = (v['subtitle'] ?? '').toString().trim();
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 72,
          height: 44,
          child: Stack(
            fit: StackFit.expand,
            children: [
              thumb.isEmpty
                  ? Container(color: Colors.grey.shade300)
                  : Image.network(thumb,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          Container(color: Colors.grey.shade300)),
              const Center(
                child: Icon(Icons.play_arrow_rounded,
                    color: Colors.white, size: 22),
              ),
            ],
          ),
        ),
      ),
      title: Text(title.isEmpty ? 'Watch' : title,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12)),
      onTap: () {
        Navigator.of(sheetCtx).pop();
        onPlay(v);
      },
    );
  }
}
