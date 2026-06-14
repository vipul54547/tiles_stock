import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/supabase_auth_service.dart';

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
