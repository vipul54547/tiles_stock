import 'dart:async';
import 'package:flutter/material.dart';

// The three stock-upload modes, shared by the PDF importer and the Excel importer.
// Scope of "unmatched" is ALWAYS the Brand + Stock list being uploaded into.
//  • add        — quantity += uploaded (top-up); unmatched kept.
//  • fullyNew   — quantity = uploaded; unmatched in THIS list zeroed (out-of-stock,
//                 never deleted — image + DNA stay in the Library).
//  • updateKeep — quantity = uploaded; unmatched kept.
enum UploadMode { add, fullyNew, updateKeep }

const _navy = Color(0xFF1B4F72);

extension UploadModeX on UploadMode {
  /// The value the atomic RPC expects (p_mode).
  String get api {
    switch (this) {
      case UploadMode.add:
        return 'add';
      case UploadMode.fullyNew:
        return 'replace_all';
      case UploadMode.updateKeep:
        return 'replace_keep';
    }
  }

  String get label {
    switch (this) {
      case UploadMode.add:
        return 'Add only';
      case UploadMode.fullyNew:
        return 'Fully new';
      case UploadMode.updateKeep:
        return 'Update & keep';
    }
  }

  String get short {
    switch (this) {
      case UploadMode.add:
        return 'Add these boxes on top of the current stock.';
      case UploadMode.fullyNew:
        return 'This file is my full current stock — set these and zero anything '
            'in this list not in the file.';
      case UploadMode.updateKeep:
        return "Set these designs to the file's numbers; leave my other designs "
            'alone.';
    }
  }

  IconData get icon {
    switch (this) {
      case UploadMode.add:
        return Icons.add_circle_outline;
      case UploadMode.fullyNew:
        return Icons.sync_alt;
      case UploadMode.updateKeep:
        return Icons.edit_note;
    }
  }

  bool get isDestructive => this == UploadMode.fullyNew;

  /// The consequence message for the guarded confirm — names the exact brand + list.
  String consequence(String brand, String list) {
    final dest = 'Brand:  $brand\nList:   $list';
    switch (this) {
      case UploadMode.add:
        return 'The boxes in this file will be ADDED on top of the current stock '
            'in:\n\n$dest';
      case UploadMode.fullyNew:
        return 'This REPLACES the stock in:\n\n$dest\n\nEvery design in this file '
            'is set to its number, and any design in this list that is NOT in the '
            'file is set to 0 boxes (out of stock). Designs, images and DNA stay '
            'in your Library.';
      case UploadMode.updateKeep:
        return 'This SETS the stock for the designs in this file, in:\n\n$dest\n\n'
            'Your other designs in this list are left unchanged.';
    }
  }
}

/// 5-second guarded confirm shown after a mode is picked. Returns true only if
/// the user confirms AFTER the countdown finishes. Names the exact brand + list
/// so a destructive "Fully new" can never be tapped through blindly.
Future<bool> showUploadModeConfirm(
    BuildContext context, UploadMode mode, String brand, String list) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ModeConfirmDialog(mode: mode, brand: brand, list: list),
  );
  return ok ?? false;
}

class _ModeConfirmDialog extends StatefulWidget {
  final UploadMode mode;
  final String brand;
  final String list;
  const _ModeConfirmDialog(
      {required this.mode, required this.brand, required this.list});
  @override
  State<_ModeConfirmDialog> createState() => _ModeConfirmDialogState();
}

class _ModeConfirmDialogState extends State<_ModeConfirmDialog> {
  static const _wait = 5;
  int _left = _wait;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _left = (_left - 1).clamp(0, _wait));
      if (_left == 0) t.cancel();
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _left == 0;
    final danger = widget.mode.isDestructive;
    final accent = danger ? Colors.red.shade700 : _navy;
    return AlertDialog(
      title: Row(
        children: [
          Icon(widget.mode.icon, color: accent),
          const SizedBox(width: 8),
          Expanded(child: Text(widget.mode.label)),
        ],
      ),
      content: Text(
        widget.mode.consequence(
            widget.brand.isEmpty ? '—' : widget.brand,
            widget.list.isEmpty ? '—' : widget.list),
        style: const TextStyle(fontSize: 13.5, height: 1.35),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: ready ? () => Navigator.pop(context, true) : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: Colors.white,
            disabledBackgroundColor: Colors.grey.shade300,
          ),
          child: Text(ready ? 'Yes, continue' : 'Yes ($_left)'),
        ),
      ],
    );
  }
}
