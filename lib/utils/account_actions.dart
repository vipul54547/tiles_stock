import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/supabase_auth_service.dart';

/// Self-service account deletion — App Store Review Guideline 5.1.1(v): any app
/// that lets users create an account must let them delete it from inside the app.
///
/// Shows a clear double-confirm (deletion is permanent and irreversible), then
/// calls [SupabaseAuthService.deleteAccount] and returns the user to /login.
/// Used by buyers (incl. guests) and stockists; admin accounts are blocked
/// server-side.
Future<void> confirmDeleteAccount(BuildContext context) async {
  final first = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.warning_amber_rounded, color: Colors.red),
      title: const Text('Delete account'),
      content: const Text(
        'This permanently deletes your account and all your data — your '
        'profile, saved suppliers, groups and inquiries.\n\n'
        'This cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Delete account'),
        ),
      ],
    ),
  );
  if (first != true || !context.mounted) return;

  final second = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Are you absolutely sure?'),
      content: const Text(
        'Your account and data will be erased immediately and cannot be '
        'recovered.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Keep my account'),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Delete permanently'),
        ),
      ],
    ),
  );
  if (second != true || !context.mounted) return;

  // Block the UI with a spinner while the deletion runs.
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );

  try {
    await SupabaseAuthService().deleteAccount();
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // dismiss spinner
    context.go('/login');
  } catch (e) {
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // dismiss spinner
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Could not delete account: $e'),
        backgroundColor: Colors.red,
      ),
    );
  }
}
