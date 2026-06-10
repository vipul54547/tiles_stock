import 'package:flutter/material.dart';
import '../models/choice_state.dart';

/// Compact toggle shown in the buyer search bar to switch between:
///   SMART  — synonym / multi-language expansion (bianco = white, carrara…),
///   NORMAL — plain literal text match.
/// It flips the shared [smartSearch] flag (applies to every buyer screen for
/// the session) and calls [onChanged] so the host can re-run its filter.
class SmartSearchToggle extends StatelessWidget {
  final VoidCallback onChanged;
  const SmartSearchToggle({super.key, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final on = smartSearch;
    return Tooltip(
      message: on
          ? 'Smart search ON — finds synonyms (bianco = white, carrara…). Tap for exact match.'
          : 'Exact search — tap for smart (synonym) search.',
      child: GestureDetector(
        onTap: () {
          smartSearch = !smartSearch;
          onChanged();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: on ? const Color(0xFF1B4F72) : Colors.grey.shade200,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_awesome,
                  size: 16, color: on ? Colors.white : Colors.grey.shade600),
              const SizedBox(width: 4),
              Text('Smart',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: on ? Colors.white : Colors.grey.shade600)),
            ],
          ),
        ),
      ),
    );
  }
}
