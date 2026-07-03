import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/library_entry.dart';
import '../services/supabase_data_service.dart';
import '../services/cloudinary_service.dart';

const _navy = Color(0xFF1B4F72);

/// Family (concept) correction sheet — shared by the Library and the dashboard so
/// both edit families the same way. Lists the auto-grouped variants of [keep]
/// (same size + family key), lets the stockist remove a wrong member (→ it stands
/// alone) or add a same-size sibling. [allEntries] is the stockist's whole library
/// (the "add" picker's candidates). Returns after the sheet closes. (design_family)
Future<void> showFamilyCorrectionSheet(
  BuildContext context, {
  required SupabaseDataService data,
  required LibraryEntry keep,
  required List<LibraryEntry> allEntries,
}) async {
  Future<Map<String, dynamic>> load() => data.myFamilyFor(keep.id);
  var famData = await load();
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    constraints:
        BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        final key = (famData['family_key'] ?? '').toString();
        final members = ((famData['members'] as List?) ?? const [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        final memberIds = members.map((m) => '${m['library_id']}').toSet();

        Future<void> refresh() async {
          final d = await load();
          if (ctx.mounted) setSheet(() => famData = d);
        }

        Future<void> removeMember(String libId) async {
          // Stand-alone = point it at its own id (a unique key).
          await data.familySetOverride(libId, libId);
          await refresh();
        }

        Future<void> addMember() async {
          final picked =
              await _pickFamilyAddition(ctx, keep, allEntries, memberIds);
          if (picked == null || key.isEmpty) return;
          await data.familySetOverride(picked.id, key);
          await refresh();
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _grip(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Design family',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(
                        'Variants sold as a set. Auto-grouped by name — remove a '
                        'wrong one or add a missing one. Buyers see the whole '
                        'family on the tile page.',
                        style:
                            TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  ],
                ),
              ),
              const Divider(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  children: [
                    if (members.length < 2)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                            'No family yet — this design stands alone. Add a '
                            'same-size variant to start a family.',
                            style: TextStyle(color: Colors.grey.shade600)),
                      ),
                    for (final m in members)
                      _familyMemberRow(m,
                          onRemove: () => removeMember('${m['library_id']}')),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: addMember,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add a design to this family'),
                      style: OutlinedButton.styleFrom(foregroundColor: _navy),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

Widget _grip() => Container(
      width: 40,
      height: 4,
      margin: const EdgeInsets.only(top: 8, bottom: 2),
      decoration: BoxDecoration(
          color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
    );

Widget _familyMemberRow(Map<String, dynamic> m,
    {required VoidCallback onRemove}) {
  final name = (m['name'] ?? '').toString();
  final img = (m['image_url'] ?? '').toString();
  final fStock = (m['f_stock'] as num?)?.toInt() ?? 0;
  final inStock = fStock > 0;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
    child: Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: 44,
            height: 44,
            child: img.isEmpty
                ? Container(
                    color: Colors.grey.shade100,
                    child: Icon(Icons.image_outlined,
                        size: 20, color: Colors.grey.shade400))
                : CachedNetworkImage(
                    imageUrl: CloudinaryService.thumbUrl(img, width: 120),
                    fit: BoxFit.cover,
                    placeholder: (_, __) =>
                        Container(color: Colors.grey.shade200),
                    errorWidget: (_, __, ___) =>
                        Container(color: Colors.grey.shade200)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(inStock ? '$fStock boxes' : 'Out of stock',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: inStock
                          ? const Color(0xFF2E7D32)
                          : const Color(0xFFC62828))),
            ],
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.close, size: 18, color: Colors.red.shade400),
          tooltip: 'Remove from family',
          onPressed: onRemove,
        ),
      ],
    ),
  );
}

// Same-size sibling picker for "add to family" — candidates = other masters of
// the same size not already in the family.
Future<LibraryEntry?> _pickFamilyAddition(BuildContext context,
    LibraryEntry keep, List<LibraryEntry> allEntries, Set<String> excludeIds) {
  final candidates = allEntries
      .where((o) =>
          o.id != keep.id && o.size == keep.size && !excludeIds.contains(o.id))
      .toList();
  if (candidates.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'No other ${keep.size.replaceAll(' mm', '')} designs to add.')));
    return Future.value(null);
  }
  var query = '';
  return showModalBottomSheet<LibraryEntry>(
    context: context,
    isScrollControlled: true,
    constraints:
        BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        final q = query.trim().toLowerCase();
        final list = q.isEmpty
            ? candidates
            : candidates
                .where((c) => c.masterName.toLowerCase().contains(q))
                .toList();
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _grip(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  onChanged: (v) => setSheet(() => query = v),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    hintText: 'Search a design to add',
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const Divider(height: 12),
              Flexible(
                child: list.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text('No match for "$query".',
                            style: TextStyle(color: Colors.grey.shade600)))
                    : ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                        itemCount: list.length,
                        itemBuilder: (_, i) {
                          final c = list[i];
                          return InkWell(
                            onTap: () => Navigator.pop(ctx, c),
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 7),
                              child: Row(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: SizedBox(
                                      width: 44,
                                      height: 44,
                                      child: c.imageUrl.isEmpty
                                          ? Container(
                                              color: Colors.grey.shade100,
                                              child: Icon(Icons.image_outlined,
                                                  size: 20,
                                                  color: Colors.grey.shade400))
                                          : CachedNetworkImage(
                                              imageUrl:
                                                  CloudinaryService.thumbUrl(
                                                      c.imageUrl,
                                                      width: 120),
                                              fit: BoxFit.cover,
                                              placeholder: (_, __) => Container(
                                                  color: Colors.grey.shade200),
                                              errorWidget: (_, __, ___) =>
                                                  Container(
                                                      color:
                                                          Colors.grey.shade200)),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                      child: Text(c.masterName,
                                          style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600))),
                                  const SizedBox(width: 8),
                                  const Icon(Icons.add_circle_outline,
                                      color: _navy),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
