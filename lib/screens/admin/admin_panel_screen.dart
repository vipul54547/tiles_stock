import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../services/supabase_auth_service.dart';



class AdminPanelScreen extends StatelessWidget {

  const AdminPanelScreen({super.key});



  @override

  Widget build(BuildContext context) {

    return Scaffold(

      appBar: AppBar(

        title: const Text('Admin Panel'),

        actions: [

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
          _adminCard(Icons.storefront_outlined, 'Manage Stockists',
              'Create, view & assign sequential IDs', Colors.blue,
              onTap: () => context.push('/admin/stockists')),
          _adminCard(Icons.grid_view_rounded, 'Tile Master Data',
              'Sync designs from TilesFinders.com', Colors.green),
          _adminCard(Icons.people_outline, 'End Users',
              'Create, view & manage companies', Colors.orange,
              onTap: () => context.push('/admin/end-users')),
          _adminCard(Icons.how_to_reg_outlined, 'Registration Requests',
              'Approve or reject new company signups', const Color(0xFF00838F),
              onTap: () => context.push('/admin/registration-requests')),
          // Only the super admin can create / manage sub-admins.
          if (isSuperAdmin)
            _adminCard(Icons.admin_panel_settings_outlined, 'Manage Admins',
                'Create sub-admins & set access', const Color(0xFF6A1B9A),
                onTap: () => context.push('/admin/admins')),
          _adminCard(Icons.bar_chart_outlined, 'Inquiry Reports',
              'All inquiries across stockists', Colors.purple),
          _adminCard(Icons.sort_outlined, 'Listing Order',
              'Reorder stockists by sequence', Colors.red),

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