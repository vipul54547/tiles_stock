import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/choice_state.dart';
import '../services/supabase_auth_service.dart';
import '../services/supabase_data_service.dart';
import '../utils/claimed_link_store.dart';
import 'public_catalog_screen.dart';

/// Entry point for a supplier's `/s/<token>` link.
///
/// On the mobile app, when a BUYER opens such a link (via Android App Links),
/// the supplier is auto-added to My Suppliers and we drop them straight onto
/// that screen with a confirmation — the effortless onboarding from
/// project_buyer_onboarding_funnel Scenario 1. If they aren't signed in at all,
/// we silently create a guest-trial account first so the supplier still saves
/// (zero-friction guest entry). A logged-in stockist/admin, and web visitors,
/// just get the login-free public catalog to browse.
class ShareLinkHandlerScreen extends StatefulWidget {
  final String token;
  const ShareLinkHandlerScreen({super.key, required this.token});
  @override
  State<ShareLinkHandlerScreen> createState() => _State();
}

class _State extends State<ShareLinkHandlerScreen> {
  // Already an end user (buyer or existing guest) → add right away.
  bool get _isEndUser => !kIsWeb && currentEndUserId.isNotEmpty;
  // Nobody signed in at all → we can silently become a guest and add.
  bool get _canGuest =>
      !kIsWeb && currentEndUserId.isEmpty && Supabase.instance.client.auth.currentUser == null;
  // On the app, a buyer/guest path resolves into My Suppliers; everyone else
  // (logged-in stockist/admin, web) just browses the public catalog.
  bool get _autoAdd => _isEndUser || _canGuest;
  // Set when guest creation fails → drop back to the public catalog.
  bool _fellBack = false;

  @override
  void initState() {
    super.initState();
    if (_autoAdd) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _claimAndGo());
    }
  }

  Future<void> _claimAndGo() async {
    String? message;
    // Not signed in → spin up a silent guest-trial identity so claim can save.
    if (_canGuest) {
      try {
        await SupabaseAuthService().loginAsGuest();
      } catch (_) {
        // Couldn't become a guest → fall back to the public catalog.
        if (!mounted) return;
        setState(() => _fellBack = true);
        return;
      }
    }
    try {
      final res = await SupabaseDataService().claimCatalog(widget.token);
      final name = (res['catalog_name'] ?? 'Supplier').toString();
      message = name;
      // Remember this link so the clipboard nudge won't re-prompt for it.
      await ClaimedLinkStore.addClaimed(widget.token);
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
    if (_autoAdd && !_fellBack) {
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
