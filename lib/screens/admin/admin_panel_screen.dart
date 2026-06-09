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

        padding: const EdgeInsets.all(16),

        children: [

          _adminCard(
            Icons.bar_chart_rounded,
            'Stockists Stock Overview',
            'Live stock summary across all stockists',
            const Color(0xFF1B4F72),
            onTap: () => context.push('/home'),
          ),
          _adminCard(
            Icons.texture_rounded,
            'Manage Finishes',
            'Master list of tile surfaces stockists align to',
            const Color(0xFF00897B),
            onTap: () => context.push('/admin/surfaces'),
          ),
          _adminCard(
            Icons.straighten_rounded,
            'Manage Sizes',
            'Master list of tile sizes (add / reorder / hide)',
            const Color(0xFF5E35B1),
            onTap: () => context.push('/admin/sizes'),
          ),
          _adminCard(Icons.storefront_outlined, 'Manage Stockists',
              'Create, view & assign sequential IDs', Colors.blue,
              onTap: () => context.push('/admin/stockists')),
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
          // Only the super admin can create / manage sub-admins.
          if (isSuperAdmin)
            _adminCard(Icons.admin_panel_settings_outlined, 'Manage Admins',
                'Create sub-admins & set access', const Color(0xFF6A1B9A),
                onTap: () => context.push('/admin/admins')),
          _adminCard(Icons.bar_chart_outlined, 'Inquiry Reports',
              'All inquiries across stockists', Colors.purple,
              onTap: () => context.push('/admin/inquiry-report')),
          _adminCard(Icons.sort_outlined, 'Listing Order',
              'Set stockist tier & priority (controls buyer order)', Colors.red,
              onTap: () => context.push('/admin/listing-order')),

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