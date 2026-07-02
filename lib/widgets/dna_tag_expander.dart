import 'package:flutter/material.dart';

const _kNavy = Color(0xFF1B4F72);

/// A small ▾ arrow (bottom-left of a design card) that expands the card
/// inline to reveal that design's DNA tags, grouped by attribute. Renders
/// nothing when the design has no tags. Only one card is ever expanded at a
/// time and any tap outside collapses it — both driven by the PARENT screen's
/// single `expandedId` state (see stockist_dashboard_screen.dart /
/// stockists_overview_screen.dart / public_catalog_screen.dart), not held
/// here, so sibling cards can react to each other without a shared ancestor
/// widget beyond the screen itself.
class DnaTagExpander extends StatelessWidget {
  final Map<String, List<String>> tagsByAttribute;
  final bool isExpanded;
  final VoidCallback onToggleExpand;
  final VoidCallback onCollapseIfExpanded;

  const DnaTagExpander({
    super.key,
    required this.tagsByAttribute,
    required this.isExpanded,
    required this.onToggleExpand,
    required this.onCollapseIfExpanded,
  });

  @override
  Widget build(BuildContext context) {
    if (tagsByAttribute.isEmpty) return const SizedBox.shrink();
    return TapRegion(
      onTapOutside: (_) => onCollapseIfExpanded(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggleExpand,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
              child: AnimatedRotation(
                turns: isExpanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 150),
                child: Icon(Icons.expand_more_rounded,
                    size: 16, color: Colors.grey.shade600),
              ),
            ),
          ),
          if (isExpanded)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: tagsByAttribute.entries
                    .map((e) => Padding(
                          padding: const EdgeInsets.only(bottom: 5),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(e.key.toUpperCase(),
                                  style: TextStyle(
                                      fontSize: 8.5,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.grey.shade500)),
                              const SizedBox(height: 2),
                              Wrap(
                                spacing: 4,
                                runSpacing: 3,
                                children: e.value
                                    .map((label) => Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: _kNavy.withValues(alpha: 0.08),
                                            borderRadius:
                                                BorderRadius.circular(4),
                                            border: Border.all(
                                                color: _kNavy
                                                    .withValues(alpha: 0.2)),
                                          ),
                                          child: Text(label,
                                              style: const TextStyle(
                                                  fontSize: 9.5,
                                                  color: _kNavy,
                                                  fontWeight: FontWeight.w600)),
                                        ))
                                    .toList(),
                              ),
                            ],
                          ),
                        ))
                    .toList(),
              ),
            ),
        ],
      ),
    );
  }
}
