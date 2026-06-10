import 'package:flutter/material.dart';

/// Standard "unsaved changes" confirmation used as a back/exit guard on forms.
/// Returns true if the user chose to discard and leave, false to stay.
Future<bool> confirmDiscardChanges(BuildContext context) async {
  final discard = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Discard changes?'),
      content: const Text(
          'You have unsaved changes. If you leave now they will be lost.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep editing')),
        TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard', style: TextStyle(color: Colors.red))),
      ],
    ),
  );
  return discard ?? false;
}

/// Wraps [child] in a [PopScope] that blocks back-navigation while [isDirty]
/// is true, showing [confirmDiscardChanges] first. Drop this around a form body.
class UnsavedChangesGuard extends StatelessWidget {
  final bool isDirty;
  final Widget child;
  const UnsavedChangesGuard(
      {super.key, required this.isDirty, required this.child});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !isDirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await confirmDiscardChanges(context)) {
          if (context.mounted) Navigator.of(context).pop();
        }
      },
      child: child,
    );
  }
}
