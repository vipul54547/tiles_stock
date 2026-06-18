import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../services/supabase_auth_service.dart';
import '../../widgets/notification_bell.dart';



class AdminPanelScreen extends StatelessWidget {

  const AdminPanelScreen({super.key});



  @override

  Widget build(BuildContext context) {

    return Scaffold(

      appBar: AppBar(

        title: const Text('Admin Panel'),

        actions: [

          const NotificationBell(),

          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await SupabaseAuthService().logout();
              if (context.mounted) context.go('/login');
            },
          ),

        ],

      ),

      body: ListView(

        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.viewPaddingOf(context).bottom),

        children: [

          _adminCard(
            Icons.bar_chart_rounded,
            'Stockists Stock Overview',
            'Live stock summary across all stockists',
            const Color(0xFF1B4F72),
            onTap: () => context.push('/home'),
          ),
          // Finishes + Sizes now live inside the Design DNA screen (top row) —
          // all the searchable master data in one place.
          _adminCard(
            Icons.science_outlined,
            'Manage Design DNA',
            'Searchable attributes (Punch, Glaze, Colour…) + Finishes & Sizes',
            const Color(0xFFB9770E),
            onTap: () => context.push('/admin/design-dna'),
          ),
          _adminCard(Icons.storefront_outlined, 'Manage Stockists',
              'Create, view & assign sequential IDs', Colors.blue,
              onTap: () => context.push('/admin/stockists')),
          _adminCard(Icons.wallpaper_rounded, 'Catalog Banners',
              'Default / anonymous banner pool (shown on share pages)',
              const Color(0xFF673AB7),
              onTap: () => context.push('/admin/banners')),
          _adminCard(Icons.people_outline, 'End Users',
              'Create, view & manage companies', Colors.orange,
              onTap: () => context.push('/admin/end-users')),
          _adminCard(Icons.how_to_reg_outlined, 'Registration Requests',
              'Approve or reject new company signups', const Color(0xFF00838F),
              onTap: () => context.push('/admin/registration-requests')),
          _adminCard(Icons.campaign_outlined, 'Send Notification',
              'Notify selected stockists or end users', const Color(0xFFEF6C00),
              onTap: () => context.push('/admin/send-notification')),
          _adminCard(Icons.fact_check_outlined, 'Pending Stock Approvals',
              'Review large stock additions (10,000+ boxes/day)',
              const Color(0xFFD84315),
              onTap: () => context.push('/admin/pending-stock')),
          // Super-admin-only: sub-admins + the app-wide public-market launch switch.
          if (isSuperAdmin)
            _adminCard(Icons.admin_panel_settings_outlined, 'Super Admin',
                'Sub-admins & launch settings', const Color(0xFF6A1B9A),
                onTap: () => context.push('/admin/admins')),
          _adminCard(Icons.bar_chart_outlined, 'Inquiry Reports',
              'All inquiries across stockists', Colors.purple,
              onTap: () => context.push('/admin/inquiry-report')),

        ],

      ),

    );

  }



  Widget _adminCard(IconData icon, String title, String subtitle, Color color,
      {VoidCallback? onTap}) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          child: Icon(icon, color: color),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap ?? () {},
      ),
    );
  }

}