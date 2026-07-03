import 'package:flutter/material.dart';

const _kNavy = Color(0xFF1B4F72);

/// A small "DNA ▾" chip (bottom-left of a design card) that opens a POPUP with
/// the design's DNA tags, grouped by attribute. Renders nothing when the design
/// has no tags.
///
/// It used to expand the card inline, but a growing card wrecked the masonry
/// grid's scroll extent (endless scroll) and made cards huge — so the tags now
/// live in a bottom-sheet popup. The `isExpanded`/`onToggleExpand`/
/// `onCollapseIfExpanded` params are kept (optional, ignored) only so existing
/// call sites keep compiling; they no longer drive any inline state.
class DnaTagExpander extends StatelessWidget {
  final Map<String, List<String>> tagsByAttribute;
  final bool isExpanded; // deprecated: no longer used (popup, not inline)
  final VoidCallback? onToggleExpand; // deprecated
  final VoidCallback? onCollapseIfExpanded; // deprecated

  const DnaTagExpander({
    super.key,
    required this.tagsByAttribute,
    this.isExpanded = false,
    this.onToggleExpand,
    this.onCollapseIfExpanded,
  });

  void _showPopup(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.local_offer_outlined, size: 18, color: _kNavy),
                    SizedBox(width: 8),
                    Text('Design DNA',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: _kNavy)),
                  ],
                ),
                const SizedBox(height: 14),
                ...tagsByAttribute.entries.map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.key.toUpperCase(),
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.grey.shade500)),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: e.value
                                .map((label) => Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 5),
                                      decoration: BoxDecoration(
                                        color: _kNavy.withValues(alpha: 0.08),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                            color:
                                                _kNavy.withValues(alpha: 0.2)),
                                      ),
                                      child: Text(label,
                                          style: const TextStyle(
                                              fontSize: 12.5,
                                              color: _kNavy,
                                              fontWeight: FontWeight.w600)),
                                    ))
                                .toList(),
                          ),
                        ],
                      ),
                    )),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (tagsByAttribute.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        onTap: () => _showPopup(context),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          margin: const EdgeInsets.only(top: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: _kNavy.withValues(alpha: 0.25)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.local_offer_outlined,
                  size: 12, color: Colors.grey.shade600),
              const SizedBox(width: 3),
              Text('DNA',
                  style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade600)),
              Icon(Icons.expand_more_rounded,
                  size: 14, color: Colors.grey.shade600),
            ],
          ),
        ),
      ),
    );
  }
}
