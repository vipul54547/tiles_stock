import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'main.dart';

import 'screens/splash_screen.dart';

import 'screens/login_screen.dart';

import 'screens/notifications_screen.dart';
import 'screens/share_link_handler_screen.dart';
import 'screens/dispatch_link_screen.dart';
import 'screens/web_landing_screen.dart';

import 'screens/reset_password_screen.dart';

import 'screens/register_screen.dart';
import 'screens/create_login_screen.dart';

import 'screens/end_user/home_screen.dart';


import 'screens/end_user/design_detail_screen.dart';

import 'screens/end_user/stockist_portfolio_screen.dart';

import 'screens/end_user/inquiry_screen.dart';

import 'screens/stockist/stockist_dashboard_screen.dart';
import 'screens/stockist/inquiries_screen.dart';

import 'screens/stockist/add_edit_stock_screen.dart';
import 'screens/stockist/add_stock_batch_screen.dart';


import 'screens/admin/admin_panel_screen.dart';
import 'screens/admin/manage_surfaces_screen.dart';
import 'screens/admin/manage_design_dna_screen.dart';
import 'screens/stockist/my_dna_words_screen.dart';
import 'screens/admin/manage_sizes_screen.dart';
import 'screens/admin/manage_banners_screen.dart';
import 'screens/admin/manage_banner_videos_screen.dart';
import 'screens/admin/manage_stockists_screen.dart';
import 'screens/admin/manage_end_users_screen.dart';
import 'screens/admin/manage_admins_screen.dart';
import 'screens/admin/manage_registration_requests_screen.dart';
import 'screens/admin/send_notification_screen.dart';
import 'screens/admin/pending_stock_screen.dart';
import 'screens/admin/inquiry_report_screen.dart';
import 'screens/admin/admin_bulk_image_import_screen.dart';
import 'screens/stockists_overview_screen.dart';
import 'screens/end_user/stockist_group_screen.dart';
import 'screens/end_user/my_choice_screen.dart';
import 'screens/end_user/my_stock_lists_screen.dart';
import 'screens/end_user/my_orders_screen.dart';
import 'screens/end_user/my_dispatch_screen.dart';
import 'screens/end_user/my_profile_screen.dart';
import 'screens/end_user/dispatch_history_screen.dart';
import 'screens/stockist/import_supplier_pdf_screen.dart';
import 'screens/stockist/my_design_library_screen.dart';
import 'screens/stockist/import_mapping_excel_screen.dart';
import 'screens/stockist/import_excel_stock_screen.dart';
import 'screens/stockist/manual_dispatch_screen.dart';
import 'screens/stockist/all_dispatches_screen.dart';
import 'screens/stockist/stock_lists_screen.dart';
import 'screens/stockist/stockist_profile_screen.dart';
import 'screens/stockist/stockist_my_videos_screen.dart';
import 'widgets/stockist_shell.dart';
import 'services/supabase_auth_service.dart';
import 'screens/stockist/stock_history_screen.dart';



// TEST ONLY: build with `--dart-define=WEB_FULL_APP=true` to run the WHOLE app
// (login/buyer/stockist/admin) in a browser — handy for testing several users at
// once across Chrome profiles / incognito windows. NEVER deploy a build with this
// flag to the public domain; production web must stay locked to /s/ only.
const bool kWebFullApp = bool.fromEnvironment('WEB_FULL_APP');

final GoRouter _router = GoRouter(

  initialLocation: '/splash',

  // On the WEB build, only the public share-link catalog (and the password reset
  // that may arrive by email) are reachable — every other route is redirected to
  // a minimal landing so login / admin / the buyer+stockist app never appear on
  // the public domain. The mobile app is unaffected (kIsWeb is false there).
  redirect: (context, state) {
    // Drives the desktop sidebar shell. redirect runs DURING build, so writing
    // the notifier here synchronously would make the shell's
    // ValueListenableBuilder call setState mid-build (asserts in debug, and
    // rebuilt the shell out from under the router). Publish it after the frame.
    final loc = state.matchedLocation;
    if (gRouteLocation.value != loc) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => gRouteLocation.value = loc);
    }
    if (!kIsWeb || kWebFullApp) return null;
    final allowed = loc.startsWith('/s/') ||
        loc == '/reset-password' ||
        loc == '/web';
    return allowed ? null : '/web';
  },

  routes: [

    GoRoute(path: '/web', builder: (_, __) => const WebLandingScreen()),

    GoRoute(path: '/splash', builder: (_, __) => const SplashScreen()),

    GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),

    GoRoute(path: '/reset-password', builder: (_, __) => const ResetPasswordScreen()),

    GoRoute(path: '/notifications', builder: (_, __) => const NotificationsScreen()),

    // Supplier share link. On the app a logged-in buyer auto-adds the supplier
    // to My Suppliers; web/guests/stockists get the login-free public catalog.
    GoRoute(
      path: '/s/:token',
      builder: (_, state) =>
          ShareLinkHandlerScreen(token: state.pathParameters['token']!),
    ),

    // Dispatch link — buyer views a dispatch receipt (login-free, read-only).
    GoRoute(
      path: '/d/:token',
      builder: (_, state) =>
          DispatchLinkScreen(token: state.pathParameters['token']!),
    ),

    GoRoute(path: '/register', builder: (_, __) => const RegisterScreen()),

    GoRoute(path: '/create-login', builder: (_, __) => const CreateLoginScreen()),

    GoRoute(path: '/home', builder: (_, __) => const StockistsOverviewScreen()),
    GoRoute(path: '/all-designs', builder: (_, __) => const HomeScreen()),

    GoRoute(

      path: '/design/:id',

      builder: (_, state) => DesignDetailScreen(

          designId: state.pathParameters['id']!),

    ),

    GoRoute(

      path: '/stockist/:id/portfolio',

      builder: (_, state) => StockistPortfolioScreen(

          stockistId: state.pathParameters['id']!,

          initialDesignId: state.extra as String?),

    ),

    GoRoute(

      path: '/inquiry/:stockistId/:designId',

      builder: (_, state) => InquiryScreen(

        stockistId: state.pathParameters['stockistId']!,

        designId: state.pathParameters['designId']!,

        preFilledMessage: state.extra as String?,

      ),

    ),

    // Stockist section — plain top-level routes. The desktop/web sidebar is
    // provided app-wide by StockistShell (MaterialApp.router builder), beside the
    // single navigator so dialogs / pops never blank the page.
    GoRoute(
        path: '/stockist/dashboard',
        builder: (_, __) => const StockistDashboardScreen()),
        GoRoute(
            path: '/stockist/inquiries',
            builder: (_, __) => const InquiriesScreen()),
        // "+ Add → Stock" — batch manual stock entry (P_Stock only, no list).
        GoRoute(
            path: '/stockist/stock/add',
            builder: (_, state) {
              final e = state.extra;
              final brandId = e is Map ? e['brandId'] as String? : null;
              return AddStockBatchScreen(initialBrandId: brandId);
            }),
        GoRoute(
          path: '/stockist/stock/edit/:id',
          builder: (_, state) =>
              AddEditStockScreen(designId: state.pathParameters['id']),
        ),
        GoRoute(
          path: '/stockist/stock/import-supplier-pdf',
          builder: (_, state) =>
              ImportSupplierPdfScreen(initialBrandId: state.extra as String?),
        ),
        GoRoute(
          path: '/stockist/library',
          builder: (_, __) => const MyDesignLibraryScreen(),
        ),
        GoRoute(
          path: '/stockist/library/import-mapping',
          builder: (_, __) => const ImportMappingExcelScreen(),
        ),
        GoRoute(
          path: '/stockist/stock/import-excel',
          builder: (_, state) =>
              ImportExcelStockScreen(initialBrandId: state.extra as String?),
        ),
        // The ONE dispatch screen. Opened empty (walk-in) from the dashboard, or
        // with an order pre-attached from Inquiries → Dispatch.
        GoRoute(
          path: '/stockist/dispatch/manual',
          builder: (_, state) {
            final e = (state.extra as Map?) ?? const {};
            return ManualDispatchScreen(
              orderId: e['id']?.toString(),
              reduceStock: e['reduce_stock'] as bool?,
            );
          },
        ),
        GoRoute(
          path: '/stockist/dispatches',
          builder: (_, __) => const AllDispatchesScreen(),
        ),
        GoRoute(
          path: '/stockist/stock/history/:designId/:designName',
          builder: (_, state) => StockHistoryScreen(
            designId: state.pathParameters['designId']!,
            designName: state.pathParameters['designName']!,
          ),
        ),
        GoRoute(
            path: '/stockist/lists',
            builder: (_, __) => const StockListsScreen()),
        GoRoute(
            path: '/stockist/profile',
            builder: (_, __) => const StockistProfileScreen()),
        GoRoute(
            path: '/stockist/videos',
            builder: (_, __) => const StockistMyVideosScreen()),


    GoRoute(path: '/admin', builder: (_, __) => const AdminPanelScreen()),
    GoRoute(path: '/admin/surfaces', builder: (_, __) => const ManageSurfacesScreen()),
    GoRoute(path: '/admin/design-dna', builder: (_, __) => const ManageDesignDnaScreen()),
    GoRoute(path: '/stockist/dna-words', builder: (_, __) => const MyDnaWordsScreen()),
    GoRoute(path: '/admin/sizes', builder: (_, __) => const ManageSizesScreen()),
    GoRoute(path: '/admin/banners', builder: (_, __) => const ManageBannersScreen()),
    GoRoute(path: '/admin/banner-video', builder: (_, __) => const ManageBannerVideosScreen()),
    GoRoute(path: '/admin/stockists', builder: (_, __) => const ManageStockistsScreen()),
    GoRoute(path: '/admin/end-users', builder: (_, __) => const ManageEndUsersScreen()),
    GoRoute(path: '/admin/registration-requests', builder: (_, __) => const ManageRegistrationRequestsScreen()),
    GoRoute(path: '/admin/send-notification', builder: (_, __) => const SendNotificationScreen()),
    GoRoute(path: '/admin/pending-stock', builder: (_, __) => const PendingStockScreen()),
    GoRoute(path: '/admin/inquiry-report', builder: (_, __) => const InquiryReportScreen()),
    GoRoute(path: '/admin/bulk-image-import', builder: (_, __) => const AdminBulkImageImportScreen()),
    GoRoute(path: '/admin/admins', builder: (_, __) => const ManageAdminsScreen()),
    GoRoute(path: '/stockists-overview', builder: (_, __) => const StockistsOverviewScreen()), // legacy alias
    GoRoute(path: '/stockist-groups', builder: (_, __) => const StockistGroupScreen()),
    GoRoute(path: '/my-choices', builder: (_, __) => const MyChoiceScreen()),
    GoRoute(path: '/my-stock-lists', builder: (_, __) => const MyStockListsScreen()),
    GoRoute(path: '/my-orders', builder: (_, __) => const MyOrdersScreen()),
    GoRoute(path: '/my-dispatch', builder: (_, __) => const MyDispatchScreen()),
    GoRoute(path: '/my-profile', builder: (_, __) => const MyProfileScreen()),
    GoRoute(
      path: '/my-dispatches',
      builder: (_, state) =>
          DispatchHistoryScreen(filterToken: state.uri.queryParameters['token']),
    ),

  ],

);



class TilesStockApp extends StatefulWidget {

  const TilesStockApp({super.key});

  @override
  State<TilesStockApp> createState() => _TilesStockAppState();

}

class _TilesStockAppState extends State<TilesStockApp> {

  StreamSubscription<AuthState>? _authSub;

  @override
  void initState() {
    super.initState();
    // When the user opens the password-reset link from their email, Supabase
    // captures the deep link and emits a passwordRecovery event. Route them to
    // the "set new password" screen so they can finish the reset in-app.
    _authSub = supabase.auth.onAuthStateChange.listen((data) {
      if (data.event == AuthChangeEvent.passwordRecovery) {
        _router.go('/reset-password');
      }
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  @override

  Widget build(BuildContext context) {

    return MaterialApp.router(

      title: 'Tiles Stock',

      theme: ThemeData(

        colorScheme: ColorScheme.fromSeed(

          seedColor: const Color(0xFF1B4F72),

        ),

        useMaterial3: true,

        appBarTheme: const AppBarTheme(

          backgroundColor: Color(0xFF1B4F72),

          foregroundColor: Colors.white,

          elevation: 0,

        ),

      ),

      routerConfig: _router,

      // Desktop/web sidebar shell — sits BESIDE the single navigator (not a
      // nested ShellRoute), so dialogs/back/pops always target the one navigator
      // and never blank the page. No-op on phones / non-stockist routes.
      builder: (context, child) => StockistShell(
        onNavigate: (path) => _router.go(path),
        onLogout: () async {
          await SupabaseAuthService().logout();
          _router.go('/login');
        },
        child: child ?? const SizedBox.shrink(),
      ),

    );

  }

} 