import 'package:flutter/material.dart';
import '../../services/supabase_data_service.dart';

/// Admin "Banner Video": manage the GLOBAL learning videos that ride the top
/// banner of stockists' /s/ pages, and set each stockist's 4-step display mode
/// (off | admin | mixed | stockist). Videos are YouTube-only; the server pulls
/// the video id from any link form and auto-derives the thumbnail.
/// (project_tutorial_videos_plan — Banner Video, step 2)
class ManageBannerVideosScreen extends StatelessWidget {
  const ManageBannerVideosScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: const Color(0xFFF5F5F5),
        appBar: AppBar(
          title: const Text('Banner Video'),
          bottom: const TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.white,
            indicatorWeight: 3,
            labelStyle: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            tabs: [
              Tab(text: 'Learning videos'),
              Tab(text: 'Stockist modes'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _VideosTab(),
            _ModesTab(),
          ],
        ),
      ),
    );
  }
}

/// Pull the 11-char YouTube id from any link form (mirrors SQL yt_video_id, for
/// the local thumbnail preview only — the server re-derives on save).
String? _ytId(String url) {
  final m = RegExp(r'(?:youtu\.be/|[?&]v=|/shorts/|/embed/|/live/)([A-Za-z0-9_-]{11})')
      .firstMatch(url);
  if (m != null) return m.group(1);
  if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(url.trim())) return url.trim();
  return null;
}

const _navy = Color(0xFF1B4F72);

// ─── Tab 1: global learning videos ─────────────────────────────────────────
class _VideosTab extends StatefulWidget {
  const _VideosTab();
  @override
  State<_VideosTab> createState() => _VideosTabState();
}

class _VideosTabState extends State<_VideosTab>
    with AutomaticKeepAliveClientMixin {
  final _data = SupabaseDataService();
  List<Map<String, dynamic>> _videos = [];
  bool _loading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = await _data.adminListVideos();
      if (!mounted) return;
      setState(() {
        _videos = v;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Could not load videos: $e', error: true);
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg), backgroundColor: error ? Colors.red : null));
  }

  Future<void> _toggle(Map<String, dynamic> v) async {
    final id = v['id'] as String;
    final next = !(v['is_active'] as bool? ?? true);
    setState(() => v['is_active'] = next);
    try {
      await _data.adminSetVideoActive(id, next);
    } catch (e) {
      setState(() => v['is_active'] = !next);
      _snack('Could not update: $e', error: true);
    }
  }

  Future<void> _delete(Map<String, dynamic> v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete video?'),
        content: const Text(
            'It stops showing right away. You have 24 hours to restore it '
            'before it is purged.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _data.adminDeleteVideo(v['id'] as String);
      await _load();
    } catch (e) {
      _snack('Could not delete: $e', error: true);
    }
  }

  Future<void> _edit([Map<String, dynamic>? existing]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => _VideoEditSheet(existing: existing),
    );
    if (saved == true) {
      await _load();
      _snack('Saved.');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final active = _videos.where((v) => v['is_active'] == true).length;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add video'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                    16, 16, 16, 90 + MediaQuery.viewPaddingOf(context).bottom),
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _navy.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.play_circle_outline, color: _navy),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                              'Global learning videos — $active showing. These play '
                              'in the top banner across every stockist whose mode is '
                              '“admin” or “mixed”. Paste an Unlisted (or Public) '
                              'YouTube link with embedding on; 9:16 vertical is best.',
                              style: const TextStyle(
                                  fontSize: 12.5, color: _navy)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (_videos.isEmpty)
                    _empty('No videos yet',
                        'Tap “Add video” to add the first learning video.')
                  else
                    ..._videos.map(_tile),
                ],
              ),
            ),
    );
  }

  Widget _empty(String title, String subtitle) => Padding(
        padding: const EdgeInsets.only(top: 60),
        child: Column(children: [
          Icon(Icons.video_library_outlined,
              size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 12),
          Text(title,
              style: TextStyle(
                  fontWeight: FontWeight.bold, color: Colors.grey.shade600)),
          const SizedBox(height: 4),
          Text(subtitle,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
        ]),
      );

  Widget _tile(Map<String, dynamic> v) {
    final act = v['is_active'] as bool? ?? true;
    final kind = (v['kind'] ?? 'tutorial').toString();
    final thumb = (v['thumbnail'] ?? '').toString();
    final title = (v['title'] ?? '').toString();
    final subtitle = (v['subtitle'] ?? '').toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      clipBehavior: Clip.antiAlias,
      child: Opacity(
        opacity: act ? 1 : 0.5,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => _edit(v),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 96,
                    height: 96,
                    child: thumb.isEmpty
                        ? Container(color: Colors.grey.shade200)
                        : Image.network(thumb,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                                color: Colors.grey.shade200,
                                child: const Icon(Icons.broken_image))),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _kindChip(kind),
                          const SizedBox(height: 6),
                          Text(title.isEmpty ? '(no title)' : title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 14)),
                          if (subtitle.isNotEmpty)
                            Text(subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12, color: Colors.grey.shade600)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Row(
              children: [
                const SizedBox(width: 8),
                Icon(act ? Icons.check_circle : Icons.visibility_off,
                    size: 16, color: act ? const Color(0xFF2E7D32) : Colors.grey),
                const SizedBox(width: 6),
                Text(act ? 'Showing' : 'Hidden',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: act ? const Color(0xFF2E7D32) : Colors.grey)),
                const Spacer(),
                Switch(
                  value: act,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (_) => _toggle(v),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, color: _navy),
                  onPressed: () => _edit(v),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  onPressed: () => _delete(v),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Widget _kindChip(String kind) {
  final tutorial = kind == 'tutorial';
  final c = tutorial ? _navy : const Color(0xFFB9770E);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: c.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(tutorial ? '▶ Tutorial' : '✦ Collection',
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c)),
  );
}

// ─── Add / edit sheet ───────────────────────────────────────────────────────
class _VideoEditSheet extends StatefulWidget {
  const _VideoEditSheet({this.existing});
  final Map<String, dynamic>? existing;
  @override
  State<_VideoEditSheet> createState() => _VideoEditSheetState();
}

class _VideoEditSheetState extends State<_VideoEditSheet> {
  final _data = SupabaseDataService();
  late final TextEditingController _url;
  late final TextEditingController _title;
  late final TextEditingController _subtitle;
  late String _kind;
  late bool _active;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _url = TextEditingController(text: (e?['video_url'] ?? '').toString());
    _title = TextEditingController(text: (e?['title'] ?? '').toString());
    _subtitle = TextEditingController(text: (e?['subtitle'] ?? '').toString());
    _kind = (e?['kind'] ?? 'tutorial').toString();
    _active = e?['is_active'] as bool? ?? true;
    _url.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _url.dispose();
    _title.dispose();
    _subtitle.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final id = _ytId(_url.text);
    if (id == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('That doesn’t look like a YouTube link.'),
          backgroundColor: Colors.red));
      return;
    }
    setState(() => _saving = true);
    try {
      await _data.adminSaveVideo(
        id: widget.existing?['id'] as String?,
        kind: _kind,
        title: _title.text.trim(),
        subtitle: _subtitle.text.trim(),
        url: _url.text.trim(),
        isActive: _active,
        sortOrder: (widget.existing?['sort_order'] as int?) ?? 0,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not save: $e'),
            backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = _ytId(_url.text);
    final editing = widget.existing != null;
    return Padding(
      padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 18,
          bottom: 18 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Text(editing ? 'Edit video' : 'Add learning video',
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'tutorial', label: Text('Tutorial')),
                ButtonSegment(value: 'collection', label: Text('Collection')),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() => _kind = s.first),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: 'YouTube link',
                hintText: 'https://youtu.be/… or /shorts/…',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.link),
              ),
            ),
            if (_url.text.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              if (id != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Image.network(
                      'https://img.youtube.com/vi/$id/hqdefault.jpg',
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                          color: Colors.grey.shade200,
                          child: const Icon(Icons.broken_image)),
                    ),
                  ),
                )
              else
                Row(children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('Can’t read a video id from that link.',
                        style: TextStyle(
                            fontSize: 12.5, color: Colors.red.shade700)),
                  ),
                ]),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Title',
                hintText: 'How to use this catalogue',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _subtitle,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Subtitle (optional)',
                hintText: 'Quick 30-second walkthrough',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _active,
              activeThumbColor: _navy,
              title: const Text('Show now'),
              subtitle: Text(
                  _active
                      ? 'Plays in the banner on eligible stockists.'
                      : 'Kept in the library, not shown.',
                  style: const TextStyle(fontSize: 12)),
              onChanged: (v) => setState(() => _active = v),
            ),
            const SizedBox(height: 12),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: _navy,
                  minimumSize: const Size.fromHeight(48)),
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(editing ? 'Save changes' : 'Add video'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Tab 2: per-stockist mode ───────────────────────────────────────────────
class _ModesTab extends StatefulWidget {
  const _ModesTab();
  @override
  State<_ModesTab> createState() => _ModesTabState();
}

class _ModesTabState extends State<_ModesTab>
    with AutomaticKeepAliveClientMixin {
  final _data = SupabaseDataService();
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String _query = '';

  static const _modes = ['off', 'admin', 'mixed', 'stockist'];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _data.adminStockistVideoModes();
      if (!mounted) return;
      setState(() {
        _rows = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not load stockists: $e'),
          backgroundColor: Colors.red));
    }
  }

  Future<void> _setMode(Map<String, dynamic> row, String mode) async {
    final prev = (row['mode'] ?? 'mixed').toString();
    if (prev == mode) return;
    setState(() => row['mode'] = mode);
    try {
      await _data.adminSetStockistVideoMode(row['seq'].toString(), mode);
    } catch (e) {
      setState(() => row['mode'] = prev);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not set mode: $e'),
            backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final q = _query.trim().toLowerCase();
    final rows = q.isEmpty
        ? _rows
        : _rows.where((r) {
            final name = (r['name'] ?? '').toString().toLowerCase();
            final city = (r['city'] ?? '').toString().toLowerCase();
            final seq = (r['seq'] ?? '').toString().toLowerCase();
            return name.contains(q) || city.contains(q) || seq.contains(q);
          }).toList();
    return _loading
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: TextField(
                  decoration: InputDecoration(
                    hintText: 'Search stockist…',
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: Colors.grey.shade300)),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: EdgeInsets.fromLTRB(
                        16, 8, 16, 16 + MediaQuery.viewPaddingOf(context).bottom),
                    itemCount: rows.length,
                    itemBuilder: (_, i) => _modeCard(rows[i]),
                  ),
                ),
              ),
            ],
          );
  }

  Widget _modeCard(Map<String, dynamic> row) {
    final mode = (row['mode'] ?? 'mixed').toString();
    final name = (row['name'] ?? '').toString();
    final city = (row['city'] ?? '').toString();
    final active = (row['active_count'] as num?)?.toInt() ?? 0;
    final lib = (row['lib_count'] as num?)?.toInt() ?? 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                    Text(
                        [
                          if (city.isNotEmpty) city,
                          '$active shown · $lib in library'
                        ].join(' · '),
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade600)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              segments: const [
                ButtonSegment(value: 'off', label: Text('Off')),
                ButtonSegment(value: 'admin', label: Text('Admin')),
                ButtonSegment(value: 'mixed', label: Text('Mixed')),
                ButtonSegment(value: 'stockist', label: Text('Own')),
              ],
              selected: {_modes.contains(mode) ? mode : 'mixed'},
              onSelectionChanged: (s) => _setMode(row, s.first),
            ),
          ),
          const SizedBox(height: 6),
          Text(_modeHint(mode),
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
        ],
      ),
    );
  }

  String _modeHint(String mode) {
    switch (mode) {
      case 'off':
        return 'No video on this stockist’s banner.';
      case 'admin':
        return 'Only the global learning videos play here.';
      case 'stockist':
        return 'Only this stockist’s own videos play here.';
      case 'mixed':
      default:
        return 'Blend — 2 of the stockist’s own to every 1 admin video.';
    }
  }
}
