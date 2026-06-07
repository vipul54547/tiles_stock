import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';

import 'screens/splash_screen.dart';

import 'screens/login_screen.dart';

import 'screens/register_screen.dart';

import 'screens/end_user/home_screen.dart';


import 'screens/end_user/design_detail_screen.dart';

import 'screens/end_user/stockist_portfolio_screen.dart';

import 'screens/end_user/inquiry_screen.dart';

import 'screens/stockist/stockist_dashboard_screen.dart';

import 'screens/stockist/add_edit_stock_screen.dart';

import 'screens/stockist/received_inquiries_screen.dart';

import 'screens/admin/admin_panel_screen.dart';
import 'screens/admin/import_users_screen.dart';
import 'screens/admin/manage_surfaces_screen.dart';
import 'screens/stockists_overview_screen.dart';
import 'screens/end_user/stockist_group_screen.dart';
import 'screens/end_user/my_choice_screen.dart';
import 'screens/stockist/upload_stock_screen.dart';
import 'screens/stockist/add_dispatch_screen.dart';
import 'screens/stockist/stock_history_screen.dart';



final GoRouter _router = GoRouter(

  initialLocation: '/splash',

  routes: [

    GoRoute(path: '/splash', builder: (_, __) => const SplashScreen()),

    GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),

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
    GoRoute(path: '/admin/import-users', builder: (_, __) => const ImportUsersScreen()),
    GoRoute(path: '/admin/surfaces', builder: (_, __) => const ManageSurfacesScreen()),
    GoRoute(path: '/stockists-overview', builder: (_, __) => const StockistsOverviewScreen()), // legacy alias
    GoRoute(path: '/stockist-groups', builder: (_, __) => const StockistGroupScreen()),
    GoRoute(path: '/my-choices', builder: (_, __) => const MyChoiceScreen()),

    GoRoute(
      path: '/stockist/stock/upload',
      builder: (_, __) => const UploadStockScreen(),
    ),
    GoRoute(
      path: '/stockist/stock/dispatch',
      builder: (_, __) => const AddDispatchScreen(),
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



class TilesStockApp extends StatelessWidget {

  const TilesStockApp({super.key});



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