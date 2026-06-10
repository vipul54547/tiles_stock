import 'package:flutter/material.dart';
import '../../models/stockist.dart';
import '../../services/supabase_data_service.dart';
import '../../utils/guest_gate.dart';

// ── Shared state — persists across navigation within a session ────────────────

class StockistGroup {
  String? id; // DB row id; null until persisted
  String name;
  final Set<String> stockistIds;
  StockistGroup(this.name, {this.id}) : stockistIds = {};
}

// Loaded per end user from the database (empty until loaded / for guests).
final List<StockistGroup> stockistGroups = [];

/// Loads the signed-in end user's saved groups into [stockistGroups]. Call from
/// any buyer screen before using the group filter. No-op for guests.
Future<void> loadStockistGroupsFromDb() async {
  final rows = await SupabaseDataService().getMyGroups();
  stockistGroups
    ..clear()
    ..addAll(rows.map((r) {
      final g = StockistGroup(r['name'] as String? ?? 'Group',
          id: r['id'] as String?);
      g.stockistIds.addAll(List<String>.from(r['stockist_ids'] ?? const []));
      return g;
    }));
}

// ── Screen ────────────────────────────────────────────────────────────────────

class StockistGroupScreen extends StatefulWidget {
  const StockistGroupScreen({super.key});
  @override
  State<StockistGroupScreen> createState() => _State();
}

const _groupColors = [Color(0xFF1B4F72), Color(0xFF2E7D32), Color(0xFF6A1B9A)];

class _State extends State<StockistGroupScreen> {
  final SupabaseDataService _service = SupabaseDataService();
  List<Stockist> _stockists = [];
  bool _loading = true;
  int _expanded = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final stockists = await _service.getAllStockists();
    await loadStockistGroupsFromDb();
    if (!mounted) return;
    setState(() {
      _stockists = stockists;
      _loading = false;
    });
  }

  Color _colorFor(int i) => _groupColors[i % _groupColors.length];

  // Persist a group's members to the DB (after any add/remove/clear/toggle).
  void _persistMembers(StockistGroup g) {
    if (g.id != null) _service.setGroupMembers(g.id!, g.stockistIds.toList());
  }

  Future<void> _createGroup() async {
    if (blockIfGuest(context, feature: 'Groups')) return;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) =>
          const _RenameGroupDialog(initialName: '', title: 'New Group'),
    );
    if (!mounted || name == null || name.trim().isEmpty) return;
    final id = await _service.createGroup(name.trim());
    if (!mounted) return;
    setState(() {
      stockistGroups.add(StockistGroup(name.trim(), id: id));
      _expanded = stockistGroups.length - 1;
    });
  }

  Future<void> _deleteGroup(int index) async {
    final g = stockistGroups[index];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete group?'),
        content: Text('Delete "${g.name}"? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (g.id != null) await _service.deleteGroup(g.id!);
    if (!mounted) return;
    setState(() {
      stockistGroups.removeAt(index);
      if (_expanded >= stockistGroups.length) _expanded = -1;
    });
  }

  void _renameGroup(int index) async {
    if (blockIfGuest(context, feature: 'Groups')) return;
    final g = stockistGroups[index];
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => _RenameGroupDialog(initialName: g.name),
    );
    if (!mounted) return;
    if (newName != null && newName.isNotEmpty) {
      setState(() => g.name = newName);
      if (g.id != null) _service.renameGroup(g.id!, newName);
    }
  }

  void _toggleStockist(int groupIndex, String stockistId) {
    final g = stockistGroups[groupIndex];
    setState(() {
      if (g.stockistIds.contains(stockistId)) {
        g.stockistIds.remove(stockistId);
      } else {
        g.stockistIds.add(stockistId);
      }
    });
    _persistMembers(g);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Prevent keyboard-triggered MediaQuery resize from causing a rebuild
      // cascade while the rename dialog's TextField is focused.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Stockist Groups'),
      ),
      body: SafeArea(
        child: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              // Bottom padding clears the system navigation bar so the
              // "Create group" button is never hidden under it.
              padding: const EdgeInsets.all(16),
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1B4F72).withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: const Color(0xFF1B4F72).withValues(alpha: 0.15)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.info_outline_rounded,
                          size: 16, color: Color(0xFF1B4F72)),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Create your own groups of stockists and use them to '
                          'quickly filter designs across screens. Your groups are '
                          'saved to your account.',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF1B4F72)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (stockistGroups.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text('No groups yet. Tap "Create group" to start.',
                          style: TextStyle(color: Colors.grey.shade500)),
                    ),
                  ),
                for (int i = 0; i < stockistGroups.length; i++)
                  _buildGroupCard(i),
                const SizedBox(height: 4),
                OutlinedButton.icon(
                  onPressed: _createGroup,
                  icon: const Icon(Icons.add),
                  label: const Text('Create group'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF1B4F72),
                    side: const BorderSide(color: Color(0xFF1B4F72)),
                    minimumSize: const Size.fromHeight(46),
                  ),
                ),
              ],
            ),
      ),
    );
  }

  void _showViewSheet(int groupIndex) {
    final group = stockistGroups[groupIndex];
    final color = _colorFor(groupIndex);
    final sheetHeight = MediaQuery.sizeOf(context).height * 0.65;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) {
        String query = '';
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final members = _stockists
                .where((s) => group.stockistIds.contains(s.id))
                .where((s) =>
                    query.isEmpty ||
                    s.name.toLowerCase().contains(query.toLowerCase()))
                .toList();

            return SizedBox(
              height: sheetHeight,
              child: Column(
                children: [
                  Center(
                    child: Container(
                      width: 40, height: 4,
                      margin: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(
                      children: [
                        Icon(Icons.visibility_outlined, color: color, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${group.name} Members',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '${group.stockistIds.length} selected',
                            style: TextStyle(
                                color: color,
                                fontWeight: FontWeight.bold,
                                fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: TextField(
                      onChanged: (v) => setSheet(() => query = v),
                      decoration: InputDecoration(
                        hintText: 'Search members...',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        isDense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 10),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  Divider(height: 1, color: Colors.grey.shade200),
                  Expanded(
                    child: members.isEmpty
                        ? Center(
                            child: Text(
                              group.stockistIds.isEmpty
                                  ? 'No members in this group'
                                  : 'No results for "$query"',
                              style: const TextStyle(color: Colors.grey),
                            ),
                          )
                        : ListView.builder(
                            itemCount: members.length,
                            itemBuilder: (_, i) {
                              final s = members[i];
                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor:
                                      color.withValues(alpha: 0.12),
                                  child: Text(
                                    s.name[0].toUpperCase(),
                                    style: TextStyle(
                                        color: color,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                                title: Text(s.name,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13)),
                                subtitle: Text(
                                    'ID: ${s.id}  ·  ${s.city}, ${s.state}',
                                    style: const TextStyle(
                                        fontSize: 11, color: Colors.grey)),
                                trailing: IconButton(
                                  icon: Icon(Icons.remove_circle_outline,
                                      color: Colors.red.shade400, size: 20),
                                  tooltip: 'Remove from group',
                                  onPressed: () {
                                    setState(() =>
                                        group.stockistIds.remove(s.id));
                                    _persistMembers(group);
                                    setSheet(() {});
                                  },
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showAddMemberSheet(int groupIndex) {
    if (blockIfGuest(context, feature: 'Groups')) return;
    final group = stockistGroups[groupIndex];
    final color = _colorFor(groupIndex);
    final sheetHeight = MediaQuery.sizeOf(context).height * 0.65;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) {
        String query = '';
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final available = _stockists
                .where((s) => !group.stockistIds.contains(s.id))
                .where((s) =>
                    query.isEmpty ||
                    s.name.toLowerCase().contains(query.toLowerCase()))
                .toList();

            return SizedBox(
              height: sheetHeight,
              child: Column(
                children: [
                  Center(
                    child: Container(
                      width: 40, height: 4,
                      margin: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(
                      children: [
                        Icon(Icons.person_add_outlined,
                            color: color, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Add to ${group.name}',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: TextField(
                      onChanged: (v) => setSheet(() => query = v),
                      decoration: InputDecoration(
                        hintText: 'Search stockist...',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        isDense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 10),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  Divider(height: 1, color: Colors.grey.shade200),
                  Expanded(
                    child: available.isEmpty
                        ? Center(
                            child: Text(
                              _stockists.every((s) =>
                                      group.stockistIds.contains(s.id))
                                  ? 'All stockists are already in this group'
                                  : 'No results for "$query"',
                              style: const TextStyle(color: Colors.grey),
                            ),
                          )
                        : ListView.builder(
                            itemCount: available.length,
                            itemBuilder: (_, i) {
                              final s = available[i];
                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: Colors.grey.shade100,
                                  child: Text(
                                    s.name[0].toUpperCase(),
                                    style: TextStyle(
                                        color: Colors.grey.shade600,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                                title: Text(s.name,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13)),
                                subtitle: Text(
                                    'ID: ${s.id}  ·  ${s.city}, ${s.state}',
                                    style: const TextStyle(
                                        fontSize: 11, color: Colors.grey)),
                                trailing: IconButton(
                                  icon: Icon(Icons.add_circle_outline,
                                      color: color, size: 22),
                                  tooltip: 'Add to group',
                                  onPressed: () {
                                    setState(() =>
                                        group.stockistIds.add(s.id));
                                    _persistMembers(group);
                                    setSheet(() {});
                                  },
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildGroupCard(int index) {
    final group = stockistGroups[index];
    final isExpanded = _expanded == index;
    final count = group.stockistIds.length;
    final color = _colorFor(index);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          // ── Header ────────────────────────────────────────────────────
          InkWell(
            borderRadius: BorderRadius.vertical(
              top: const Radius.circular(12),
              bottom: isExpanded ? Radius.zero : const Radius.circular(12),
            ),
            onTap: () =>
                setState(() => _expanded = isExpanded ? -1 : index),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: Text(
                        '${index + 1}',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.name,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                        Text(
                          count == 0
                              ? 'No stockists selected'
                              : '$count stockist${count == 1 ? '' : 's'} selected',
                          style: TextStyle(
                            fontSize: 12,
                            color: count == 0 ? Colors.grey : color,
                            fontWeight: count == 0
                                ? FontWeight.normal
                                : FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.visibility_outlined, size: 18),
                    onPressed: () => _showViewSheet(index),
                    color: color,
                    tooltip: 'View members',
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: const Icon(Icons.drive_file_rename_outline, size: 18),
                    onPressed: () => _renameGroup(index),
                    color: color,
                    tooltip: 'Rename group',
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: const Icon(Icons.person_add_outlined, size: 18),
                    onPressed: () => _showAddMemberSheet(index),
                    color: color,
                    tooltip: 'Add members',
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () => _deleteGroup(index),
                    color: Colors.red.shade400,
                    tooltip: 'Delete group',
                    visualDensity: VisualDensity.compact,
                  ),
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    color: Colors.grey.shade500,
                  ),
                ],
              ),
            ),
          ),

          // ── Stockist list ─────────────────────────────────────────────
          if (isExpanded) ...[
            Divider(height: 1, color: Colors.grey.shade200),
            if (_stockists.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No stockists available',
                    style: TextStyle(color: Colors.grey)),
              )
            else
              // Use Column instead of ListView.builder(shrinkWrap: true) to
              // avoid the _dependents.isEmpty assertion that fires when a
              // nested lazy list is rebuilt via setState inside another ListView.
              Column(
                children: _stockists.map((s) {
                  final selected = group.stockistIds.contains(s.id);
                  return InkWell(
                    onTap: () => _toggleStockist(index, s.id),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      child: Row(
                        children: [
                          Checkbox(
                            value: selected,
                            onChanged: (_) => _toggleStockist(index, s.id),
                            activeColor: color,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  s.name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13),
                                ),
                                Text(
                                  'ID: ${s.id}  ·  ${s.city}, ${s.state}',
                                  style: const TextStyle(
                                      color: Colors.grey, fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                          if (selected)
                            Icon(Icons.check_circle_rounded,
                                color: color, size: 18),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            // Clear button for this group
            if (group.stockistIds.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () {
                      setState(() => group.stockistIds.clear());
                      _persistMembers(group);
                    },
                    icon: const Icon(Icons.clear_all, size: 15),
                    label: const Text('Clear group',
                        style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                        foregroundColor: Colors.red.shade600),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _RenameGroupDialog extends StatefulWidget {
  final String initialName;
  final String title;
  const _RenameGroupDialog(
      {required this.initialName, this.title = 'Rename Group'});

  @override
  State<_RenameGroupDialog> createState() => _RenameGroupDialogState();
}

class _RenameGroupDialogState extends State<_RenameGroupDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          hintText: 'Enter group name',
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text.trim()),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1B4F72),
            foregroundColor: Colors.white,
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
