import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/cloudinary_service.dart';
import '../widgets/pano_embed.dart';

/// 🖼️ Buyer-facing PORTFOLIO browser, opened from the login-free `/s/` page
/// (project_media_portfolio_ddpi #14). Stock-blind — design identity + media
/// only, no price/stock/quality.
///
/// Type tabs (Mockup · Aligning · Close-look · 360 · Video, only the present
/// ones) → a gallery grid → tap → a full-screen viewer that walks that type's
/// items with ‹ Prev / Next ›. Images show inline; 360 / video open their link.
///
/// Feeds straight off `public_portfolio`'s `assets` — each asset is one photo /
/// clip carrying the designs it shows ("+N variants").
class PortfolioViewScreen extends StatefulWidget {
  final List<Map<String, dynamic>> assets;
  final Color brandColor;
  final String title;

  const PortfolioViewScreen({
    super.key,
    required this.assets,
    required this.brandColor,
    required this.title,
  });

  @override
  State<PortfolioViewScreen> createState() => _PortfolioViewScreenState();
}

const _order = ['mockup', 'aligning', 'closelook', 'faces', '360', 'video'];
const _typeLabel = {
  'mockup': 'Mockup',
  'aligning': 'Aligning',
  'closelook': 'Close-look',
  'faces': 'Faces',
  '360': '360',
  'video': 'Video',
};
// Types whose asset.url is a still image shown inline (vs a 360/video link-out).
bool _isImageType(String type) =>
    type == 'mockup' ||
    type == 'aligning' ||
    type == 'closelook' ||
    type == 'faces';

/// Open the full-screen media viewer for a set of assets (e.g. one design's
/// media, from a stock card's "View" button). Orders them in canonical type
/// order so ‹ Prev / Next › walks mockup → aligning → close-look → 360 → video.
void openPortfolioViewer(BuildContext context,
    {required List<Map<String, dynamic>> assets, required Color brandColor}) {
  if (assets.isEmpty) return;
  final ordered = [...assets]..sort((a, b) {
      final ta = _order.indexOf(a['type'] as String? ?? '');
      final tb = _order.indexOf(b['type'] as String? ?? '');
      if (ta != tb) return ta.compareTo(tb);
      return ((a['sort_order'] as num?) ?? 0)
          .compareTo((b['sort_order'] as num?) ?? 0);
    });
  Navigator.of(context).push(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) =>
        _MediaViewer(assets: ordered, start: 0, brandColor: brandColor),
  ));
}

class _PortfolioViewScreenState extends State<PortfolioViewScreen> {
  late final List<String> _types; // present types, in canonical order
  // The WHOLE playlist in canonical type order — the viewer's ‹ Prev / Next ›
  // walks this across types (DDPI #14), not just the tapped tab.
  late final List<Map<String, dynamic>> _ordered;

  @override
  void initState() {
    super.initState();
    final present = widget.assets.map((a) => a['type'] as String? ?? '').toSet();
    _types = _order.where(present.contains).toList();
    _ordered = [...widget.assets]..sort((a, b) {
        final ta = _order.indexOf(a['type'] as String? ?? '');
        final tb = _order.indexOf(b['type'] as String? ?? '');
        if (ta != tb) return ta.compareTo(tb);
        return ((a['sort_order'] as num?) ?? 0)
            .compareTo((b['sort_order'] as num?) ?? 0);
      });
  }

  List<Map<String, dynamic>> _of(String type) =>
      widget.assets.where((a) => a['type'] == type).toList();

  // Representative design name + how many designs this asset rides ("+N variants").
  static ({String name, int count}) _rep(Map<String, dynamic> a) {
    final arts = (a['artworks'] as List?) ?? const [];
    final designs = (a['designs'] as List?) ?? const [];
    final list = arts.isNotEmpty ? arts : designs;
    final name =
        list.isNotEmpty ? (list.first as Map)['name']?.toString() ?? '' : '';
    // Close-look has no artwork tag → count its distinct designs instead.
    final count = arts.isNotEmpty ? arts.length : designs.length;
    return (name: name, count: count);
  }

  @override
  Widget build(BuildContext context) {
    if (_types.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Portfolio')),
        body: const Center(child: Text('No media yet.')),
      );
    }
    return DefaultTabController(
      length: _types.length,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: widget.brandColor,
          foregroundColor: Colors.white,
          title: Text(widget.title.isEmpty ? 'Portfolio' : widget.title),
          bottom: TabBar(
            isScrollable: true,
            indicatorColor: Colors.white,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            tabs: [
              for (final t in _types)
                Tab(text: '${_typeLabel[t] ?? t} (${_of(t).length})'),
            ],
          ),
        ),
        body: TabBarView(
          children: [for (final t in _types) _grid(_of(t))],
        ),
      ),
    );
  }

  Widget _grid(List<Map<String, dynamic>> assets) {
    return LayoutBuilder(builder: (context, c) {
      final cols = (c.maxWidth / 240).floor().clamp(2, 6);
      return GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          childAspectRatio: 0.82,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: assets.length,
        itemBuilder: (_, i) => _tile(assets, i),
      );
    });
  }

  Widget _tile(List<Map<String, dynamic>> assets, int i) {
    final a = assets[i];
    final type = a['type'] as String? ?? '';
    final isImage = _isImageType(type);
    final url = a['url'] as String? ?? '';
    final rep = _rep(a);
    final space = a['space_label'] as String?;

    return InkWell(
      // Open the viewer on the WHOLE playlist, positioned at this asset, so
      // Prev/Next walks every type in order.
      onTap: () {
        final gi = _ordered.indexWhere((x) => x['id'] == a['id']);
        _openViewer(_ordered, gi < 0 ? 0 : gi);
      },
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.grey.shade200),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SizedBox(
                width: double.infinity,
                child: isImage && url.isNotEmpty
                    ? Image.network(CloudinaryService.thumbUrl(url, width: 400),
                        fit: BoxFit.cover)
                    : Container(
                        color: widget.brandColor.withValues(alpha: 0.08),
                        child: Icon(
                            type == 'video'
                                ? Icons.play_circle_outline
                                : Icons.threesixty,
                            size: 44,
                            color: widget.brandColor),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(rep.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13)),
                  const SizedBox(height: 1),
                  Text(
                    [
                      if (rep.count > 1) '+${rep.count - 1} variants',
                      if (space != null && space.isNotEmpty) space,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openViewer(List<Map<String, dynamic>> assets, int start) {
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _MediaViewer(
          assets: assets, start: start, brandColor: widget.brandColor),
    ));
  }
}

/// Full-screen viewer over one type's assets, ‹ Prev / Next ›.
class _MediaViewer extends StatefulWidget {
  final List<Map<String, dynamic>> assets;
  final int start;
  final Color brandColor;

  const _MediaViewer(
      {required this.assets, required this.start, required this.brandColor});

  @override
  State<_MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<_MediaViewer> {
  late final PageController _pc = PageController(initialPage: widget.start);
  late int _i = widget.start;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  Future<void> _open(String url) async {
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
            PageView.builder(
              controller: _pc,
              onPageChanged: (v) => setState(() => _i = v),
              itemCount: widget.assets.length,
              itemBuilder: (_, i) => _page(widget.assets[i]),
            ),
            // close
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            // prev / next
            if (_i > 0)
              _navArrow(Alignment.centerLeft, Icons.chevron_left,
                  () => _pc.previousPage(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut)),
            if (_i < widget.assets.length - 1)
              _navArrow(Alignment.centerRight, Icons.chevron_right,
                  () => _pc.nextPage(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut)),
            // caption
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _caption(widget.assets[_i]),
            ),
          ],
        ),
      ),
    );
  }

  // All faces side by side for comparison. Leaves room at the bottom for the
  // caption; tap a face to zoom it to full/original resolution.
  Widget _facesGrid(List<String> urls) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 96),
      child: GridView.builder(
        physics: const BouncingScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 320,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          // Portrait-leaning cells; BoxFit.contain shows the WHOLE tile (no
          // crop), so any shape fits inside its cell.
          childAspectRatio: 0.62,
        ),
        itemCount: urls.length,
        itemBuilder: (_, i) => GestureDetector(
          onTap: () => _zoom(urls[i]),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.network(CloudinaryService.thumbUrl(urls[i], width: 700),
                fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }

  // Full/original-resolution zoom of one face (pinch/scroll). Original is the
  // stored Cloudinary upload — untouched, reused later for auto room-mockups.
  void _zoom(String url) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      builder: (ctx) => GestureDetector(
        onTap: () => Navigator.pop(ctx),
        child: Stack(
          children: [
            InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              child: Center(child: Image.network(url, fit: BoxFit.contain)),
            ),
            Positioned(
              top: 24,
              right: 16,
              child: Icon(Icons.close, color: Colors.white.withValues(alpha: 0.85)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _navArrow(Alignment a, IconData icon, VoidCallback onTap) => Align(
        alignment: a,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: CircleAvatar(
            backgroundColor: Colors.black45,
            child: IconButton(
              icon: Icon(icon, color: Colors.white),
              onPressed: onTap,
            ),
          ),
        ),
      );

  Widget _page(Map<String, dynamic> a) {
    final type = a['type'] as String? ?? '';
    final url = a['url'] as String? ?? '';
    // Faces are a COMPARISON GRID — the main design + extras, all together, no
    // carousel. Tap any face to zoom it full / original. (media portfolio #14)
    if (type == 'faces') {
      final urls = ((a['face_urls'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList();
      return _facesGrid(urls);
    }
    final isImage = _isImageType(type);
    if (isImage && url.isNotEmpty) {
      return InteractiveViewer(
        minScale: 1,
        maxScale: 4,
        child: Center(
          child: Image.network(CloudinaryService.thumbUrl(url, width: 1400),
              fit: BoxFit.contain),
        ),
      );
    }
    // 360 embeds INLINE on the web (iframe srcdoc); video and the app link out.
    if (type == '360' && kIsWeb && url.isNotEmpty) {
      return panoEmbed(url);
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(type == 'video' ? Icons.play_circle_outline : Icons.threesixty,
              size: 72, color: Colors.white70),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () => _open(url),
            style: ElevatedButton.styleFrom(
                backgroundColor: widget.brandColor,
                foregroundColor: Colors.white),
            icon: const Icon(Icons.open_in_new),
            label: Text(type == 'video' ? 'Play video' : 'Open 360 view'),
          ),
        ],
      ),
    );
  }

  Widget _caption(Map<String, dynamic> a) {
    final designs = (a['artworks'] as List?)?.isNotEmpty == true
        ? (a['artworks'] as List)
        : (a['designs'] as List? ?? const []);
    final names = <String>[
      for (final d in designs) (d as Map)['name']?.toString() ?? '',
    ].where((s) => s.isNotEmpty).toSet().toList();
    final space = a['space_label'] as String?;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withValues(alpha: 0.8), Colors.transparent],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('${_typeLabel[a['type']] ?? a['type']}',
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
              if (space != null && space.isNotEmpty) ...[
                const Text('  ·  ', style: TextStyle(color: Colors.white38)),
                Text(space,
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
              const Spacer(),
              Text('${_i + 1} / ${widget.assets.length}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            names.isEmpty
                ? 'Design'
                : names.length == 1
                    ? names.first
                    : '${names.first}  +${names.length - 1} variants',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700),
          ),
          if (names.length > 1) ...[
            const SizedBox(height: 2),
            Text(names.join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ],
      ),
    );
  }
}
