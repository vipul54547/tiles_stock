import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/supabase_auth_service.dart';

/// Guest gating for member-only actions (inquiry, stockist contact, groups,
/// placing orders). If the current session is an anonymous guest, shows a
/// "register to unlock" prompt and returns true (caller should stop). Returns
/// false for real members (caller proceeds).
bool blockIfGuest(BuildContext context, {String feature = 'This feature'}) {
  if (!isGuest) return false;
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Members only'),
      content: Text(
          '$feature is available once you register and an admin approves your '
          'account.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK')),
        FilledButton(
          onPressed: () {
            Navigator.pop(ctx);
            context.push('/register');
          },
          child: const Text('Register'),
        ),
      ],
    ),
  );
  return true;
}
