import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/supabase_auth_service.dart';
import 'support.dart';

/// Guest-trial gate for actions that need a real account (inquiry, placing
/// orders). A guest can browse + save suppliers freely, but these actions prompt
/// them to create a free phone login first — their saved suppliers carry over.
/// Returns true for guests (caller should stop), false for real members.
bool blockIfGuest(BuildContext context, {String feature = 'This'}) {
  if (!isGuest) return false;
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Create your login'),
      content: Text(
          '$feature needs a quick login. Create one free with your mobile '
          'number — your saved suppliers stay with you.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Not now')),
        FilledButton(
          onPressed: () {
            Navigator.pop(ctx);
            context.push('/create-login');
          },
          child: const Text('Create login'),
        ),
      ],
    ),
  );
  return true;
}

/// Guest logout is PERMANENT (no login to return), so if a guest has saved
/// suppliers we double-confirm before they lose everything. Returns true when
/// logout should proceed, false to cancel. Non-guests — and guests with nothing
/// saved — proceed immediately. project_buyer_onboarding_funnel Increment 3.
Future<bool> confirmGuestLogout(BuildContext context,
    {required int supplierCount}) async {
  if (!isGuest || supplierCount <= 0) return true;
  final n = supplierCount;
  final s = n == 1 ? '' : 's';

  // Dialog 1 — gentle: Create login (default) / Skip / Log out anyway.
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text("Don't lose your suppliers"),
      content: Text("You're on a free guest account. Create a login to keep "
          'your $n supplier$s on any phone.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, 'logout'),
            child: const Text('Log out anyway')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, 'skip'),
            child: const Text('Skip')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, 'create'),
            child: const Text('Create login')),
      ],
    ),
  );
  if (choice == 'create') {
    if (context.mounted) context.push('/create-login');
    return false;
  }
  if (choice != 'logout') return false; // Skip / dismissed → stay

  // Dialog 2 — strong warning: Help (default) / I want to lose my connection.
  if (!context.mounted) return false;
  final confirm = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('⚠️ You will lose your suppliers'),
      content: Text('Logging out permanently removes your $n saved supplier$s. '
          "This can't be undone — you'd have to find each supplier's link again."),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, 'lose'),
            child: const Text('I want to lose my connection',
                style: TextStyle(color: Colors.red))),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, 'help'),
            child: const Text('Help')),
      ],
    ),
  );
  if (confirm == 'help') {
    await contactSupport(ref: 'guest-logout');
    return false; // reached out → stay
  }
  return confirm == 'lose'; // proceed only on explicit choice
}
