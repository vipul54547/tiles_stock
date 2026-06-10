import 'dart:async';

import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'main.dart';

import 'screens/splash_screen.dart';

import 'screens/login_screen.dart';

import 'screens/notifications_screen.dart';
import 'screens/public_catalog_screen.dart';

import 'screens/reset_password_screen.dart';

import 'screens/register_screen.dart';

import 'screens/end_user/home_screen.dart';


import 'screens/end_user/design_detail_screen.dart';

import 'screens/end_user/stockist_portfolio_screen.dart';

import 'screens/end_user/inquiry_screen.dart';

import 'screens/stockist/stockist_dashboard_screen.dart';

import 'screens/stockist/add_edit_stock_screen.dart';

import 'screens/stockist/received_inquiries_screen.dart';

import 'screens/admin/admin_panel_screen.dart';
import 'screens/admin/manage_surfaces_screen.dart';
import 'screens/admin/manage_sizes_screen.dart';
import 'screens/admin/manage_stockists_screen.dart';
import 'screens/admin/manage_end_users_screen.dart';
import 'screens/admin/manage_admins_screen.dart';
import 'screens/admin/manage_registration_requests_screen.dart';
import 'screens/admin/send_notification_screen.dart';
import 'screens/admin/pending_stock_screen.dart';
import 'screens/admin/inquiry_report_screen.dart';
import 'screens/stockists_overview_screen.dart';
import 'screens/end_user/stockist_group_screen.dart';
import 'screens/end_user/my_choice_screen.dart';
import 'screens/stockist/upload_stock_screen.dart';
import 'screens/stockist/import_excel_stock_screen.dart';
import 'screens/stockist/add_dispatch_screen.dart';
import 'screens/stockist/all_dispatches_screen.dart';
import 'screens/stockist/stock_history_screen.dart';



final GoRouter _router = GoRouter(

  initialLocation: '/splash',

  routes: [

    GoRoute(path: '/splash', builder: (_, __) => const SplashScreen()),

    GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),

    GoRoute(path: '/reset-password', builder: (_, __) => const ResetPasswordScreen()),

    GoRoute(path: '/notifications', builder: (_, __) => const NotificationsScreen()),

    // Public, login-free stockist catalog (share link → Flutter web build).
    GoRoute(
      path: '/s/:token',
      builder: (_, state) =>
          PublicCatalogScreen(token: state.pathParameters['token']!),
    ),

    GoRoute(path: '/register', builder: (_, __) => const RegisterScreen()),

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

    GoRoute(

        path: '/stockist/dashboard',

        builder: (_, __) => const StockistDashboardScreen()),

    GoRoute(

        path: '/stockist/stock/add',

        builder: (_, __) => const AddEditStockScreen()),

    GoRoute(

      path: '/stockist/stock/edit/:id',

      builder: (_, state) =>

          AddEditStockScreen(designId: state.pathParameters['id']),

    ),

    GoRoute(

        path: '/stockist/inquiries',

        builder: (_, __) => const ReceivedInquiriesScreen()),

    GoRoute(path: '/admin', builder: (_, __) => const AdminPanelScreen()),
    GoRoute(path: '/admin/surfaces', builder: (_, __) => const ManageSurfacesScreen()),
    GoRoute(path: '/admin/sizes', builder: (_, __) => const ManageSizesScreen()),
    GoRoute(path: '/admin/stockists', builder: (_, __) => const ManageStockistsScreen()),
    GoRoute(path: '/admin/end-users', builder: (_, __) => const ManageEndUsersScreen()),
    GoRoute(path: '/admin/registration-requests', builder: (_, __) => const ManageRegistrationRequestsScreen()),
    GoRoute(path: '/admin/send-notification', builder: (_, __) => const SendNotificationScreen()),
    GoRoute(path: '/admin/pending-stock', builder: (_, __) => const PendingStockScreen()),
    GoRoute(path: '/admin/inquiry-report', builder: (_, __) => const InquiryReportScreen()),
    GoRoute(path: '/admin/admins', builder: (_, __) => const ManageAdminsScreen()),
    GoRoute(path: '/stockists-overview', builder: (_, __) => const StockistsOverviewScreen()), // legacy alias
    GoRoute(path: '/stockist-groups', builder: (_, __) => const StockistGroupScreen()),
    GoRoute(path: '/my-choices', builder: (_, __) => const MyChoiceScreen()),

    GoRoute(
      path: '/stockist/stock/upload',
      builder: (_, __) => const UploadStockScreen(),
    ),
    GoRoute(
      path: '/stockist/stock/import-excel',
      builder: (_, __) => const ImportExcelStockScreen(),
    ),
    GoRoute(
      path: '/stockist/stock/dispatch',
      builder: (_, state) =>
          AddDispatchScreen(initialDesignId: state.extra as String?),
    ),
    GoRoute(
      path: '/stockist/dispatches',
      builder: (_, __) => const AllDispatchesScreen(),
    ),
    GoRoute(
      path: '/stockist/stock/history/:designId/:designName',
      builder: (_, state) => StockHistoryScreen(
        designId:   state.pathParameters['designId']!,
        designName: state.pathParameters['designName']!,
      ),
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

    );

  }

} 