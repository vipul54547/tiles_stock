import 'package:flutter/material.dart';

const _kNavy = Color(0xFF1B4F72);

/// Header summary for a multi-select facet on a collapsed accordion row.
String filterSummary(Set<String> selected) =>
    selected.isEmpty ? 'Any' : '${selected.length} chosen';

/// A collapsible filter facet: a tappable header (title + current-selection
/// summary + chevron) that reveals its chips below when expanded. Manages its
/// own open/closed state; the parent owns the selection state and passes a
/// freshly-computed [summary] on every rebuild.
class FilterSection extends StatefulWidget {
  final String title;
  final String summary;
  final Widget child;
  final bool initiallyExpanded;

  const FilterSection({
    super.key,
    required this.title,
    required this.summary,
    required this.child,
    this.initiallyExpanded = false,
  });

  @override
  State<FilterSection> createState() => _FilterSectionState();
}

class _FilterSectionState extends State<FilterSection> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final active = widget.summary != 'Any';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () {
            FocusManager.instance.primaryFocus?.unfocus();
            setState(() => _expanded = !_expanded);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 13),
            child: Row(
              children: [
                Text(widget.title,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13)),
                const Spacer(),
                Text(widget.summary,
                    style: TextStyle(
                        fontSize: 12,
                        color: active ? _kNavy : Colors.grey.shade500,
                        fontWeight:
                            active ? FontWeight.w600 : FontWeight.normal)),
                const SizedBox(width: 6),
                AnimatedRotation(
                  turns: _expanded ? 0.25 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Icon(Icons.chevron_right,
                      size: 20, color: Colors.grey.shade500),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: widget.child,
          ),
        Divider(height: 1, color: Colors.grey.shade200),
      ],
    );
  }
}

/// The "More filters / Fewer filters" row that reveals the advanced (secondary)
/// facets below the essential ones. Looks like a FilterSection header so it feels
/// native. Shows "(N active)" while collapsed if any hidden facet is set, so a
/// hidden selection is never invisible.
class MoreFiltersToggle extends StatelessWidget {
  final bool expanded;
  final int activeHidden;
  final VoidCallback onToggle;

  const MoreFiltersToggle({
    super.key,
    required this.expanded,
    required this.activeHidden,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () {
            FocusManager.instance.primaryFocus?.unfocus();
            onToggle();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 13),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: expanded ? 0.25 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: const Icon(Icons.chevron_right, size: 20, color: _kNavy),
                ),
                const SizedBox(width: 4),
                Text(expanded ? 'Fewer filters' : 'More filters',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: _kNavy)),
                const Spacer(),
                if (!expanded && activeHidden > 0)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: _kNavy.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('$activeHidden active',
                        style: const TextStyle(
                            fontSize: 11,
                            color: _kNavy,
                            fontWeight: FontWeight.w600)),
                  ),
              ],
            ),
          ),
        ),
        Divider(height: 1, color: Colors.grey.shade200),
      ],
    );
  }
}

/// One removable chip in the active-filter bar.
class ActiveFilter {
  final String label;
  final VoidCallback onRemove;
  const ActiveFilter(this.label, this.onRemove);
}

/// Horizontal strip of the currently-applied filters, each removable with a tap,
/// shown above a results grid so buyers can see/clear filters without reopening
/// the sheet. Renders nothing when no filters are active.
class ActiveFilterBar extends StatelessWidget {
  final List<ActiveFilter> filters;
  final VoidCallback? onClearAll;

  const ActiveFilterBar({super.key, required this.filters, this.onClearAll});

  @override
  Widget build(BuildContext context) {
    if (filters.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          for (final f in filters)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InkWell(
                onTap: f.onRemove,
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: _kNavy.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _kNavy.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(f.label,
                          style: const TextStyle(
                              fontSize: 12,
                              color: _kNavy,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(width: 4),
                      const Icon(Icons.close, size: 13, color: _kNavy),
                    ],
                  ),
                ),
              ),
            ),
          if (onClearAll != null)
            Center(
              child: TextButton(
                onPressed: onClearAll,
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 0),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                child: const Text('Clear all',
                    style: TextStyle(fontSize: 12, color: Colors.red)),
              ),
            ),
        ],
      ),
    );
  }
}
