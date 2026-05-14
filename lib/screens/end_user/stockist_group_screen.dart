import 'package:flutter/material.dart';
import '../../models/stockist.dart';
import '../../services/data_service.dart';

// ── Shared state — persists across navigation within a session ────────────────

class StockistGroup {
  String name;
  final Set<String> stockistIds;
  StockistGroup(this.name) : stockistIds = {};
}

final List<StockistGroup> stockistGroups = [
  StockistGroup('Group 1'),
  StockistGroup('Group 2'),
  StockistGroup('Group 3'),
];

// ── Screen ────────────────────────────────────────────────────────────────────

class StockistGroupScreen extends StatefulWidget {
  const StockistGroupScreen({super.key});
  @override
  State<StockistGroupScreen> createState() => _State();
}

const _groupColors = [Color(0xFF1B4F72), Color(0xFF2E7D32), Color(0xFF6A1B9A)];

class _State extends State<StockistGroupScreen> {
  final DataService _service = MockDataService();
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
    if (!mounted) return;
    setState(() {
      _stockists = stockists;
      _loading = false;
    });
  }

  void _renameGroup(int index) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => _RenameGroupDialog(initialName: stockistGroups[index].name),
    );
    if (!mounted) return;
    if (newName != null && newName.isNotEmpty) {
      setState(() => stockistGroups[index].name = newName);
    }
  }

  void _toggleStockist(int groupIndex, String stockistId) {
    setState(() {
      final ids = stockistGroups[groupIndex].stockistIds;
      if (ids.contains(stockistId)) {
        ids.remove(stockistId);
      } else {
        ids.add(stockistId);
      }
    });
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
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
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
                          'Organise stockists into up to 3 groups. '
                          'Use these groups to quickly filter across all screens.',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF1B4F72)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                for (int i = 0; i < 3; i++) _buildGroupCard(i),
              ],
            ),
    );
  }

  Widget _buildGroupCard(int index) {
    final group = stockistGroups[index];
    final isExpanded = _expanded == index;
    final count = group.stockistIds.length;
    final color = _groupColors[index];

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
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    onPressed: () => _renameGroup(index),
                    color: color,
                    tooltip: 'Rename group',
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
                    onPressed: () =>
                        setState(() => group.stockistIds.clear()),
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
  const _RenameGroupDialog({required this.initialName});

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
      title: const Text('Rename Group'),
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
