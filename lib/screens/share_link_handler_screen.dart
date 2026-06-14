import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../models/choice_state.dart';
import '../services/supabase_data_service.dart';
import 'public_catalog_screen.dart';

/// Entry point for a supplier's `/s/<token>` link.
///
/// On the mobile app, when a logged-in BUYER opens such a link (via Android App
/// Links), the supplier is auto-added to My Suppliers and we drop them straight
/// onto that screen with a confirmation — the effortless onboarding from
/// project_buyer_onboarding_funnel Scenario 1. Everyone else (web, guests,
/// stockists, admins) just gets the login-free public catalog to browse.
class ShareLinkHandlerScreen extends StatefulWidget {
  final String token;
  const ShareLinkHandlerScreen({super.key, required this.token});
  @override
  State<ShareLinkHandlerScreen> createState() => _State();
}

class _State extends State<ShareLinkHandlerScreen> {
  // A logged-in end user on the app → auto-add; otherwise just browse.
  bool get _autoAdd => !kIsWeb && currentEndUserId.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_autoAdd) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _claimAndGo());
    }
  }

  Future<void> _claimAndGo() async {
    String? message;
    try {
      final res = await SupabaseDataService().claimCatalog(widget.token);
      final name = (res['catalog_name'] ?? 'Supplier').toString();
      message = name;
    } catch (_) {
      // Already saved / invalid link — still drop them on My Suppliers quietly.
      message = null;
    }
    if (!mounted) return;
    // Hand the confirmation to the My Suppliers screen to show once.
    pendingSupplierAdded = message;
    context.go('/home');
  }

  @override
  Widget build(BuildContext context) {
    if (_autoAdd) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Adding supplier…'),
            ],
          ),
        ),
      );
    }
    return PublicCatalogScreen(token: widget.token);
  }
}
