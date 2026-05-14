import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';



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

            onPressed: () => context.go('/login'),

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

          _adminCard(Icons.storefront_outlined, 'Manage Stockists',

              'Create, view & assign sequential IDs', Colors.blue),

          _adminCard(Icons.grid_view_rounded, 'Tile Master Data',

              'Sync designs from TilesFinders.com', Colors.green),

          _adminCard(Icons.people_outline, 'End Users',

              'View registered companies', Colors.orange),

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