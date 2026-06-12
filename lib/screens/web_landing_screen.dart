import 'package:flutter/material.dart';

/// Shown on the WEB build for any route that isn't a public share link. The web
/// build is published only to serve `/s/<token>` catalog pages — login, admin and
/// the buyer/stockist app live in the mobile app, never on the public domain.
class WebLandingScreen extends StatelessWidget {
  const WebLandingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    const brand = Color(0xFF1B4F72);
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.grid_view_rounded, size: 56, color: brand),
              const SizedBox(height: 16),
              const Text('Tiles Stock',
                  style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: brand)),
              const SizedBox(height: 10),
              Text(
                'This page opens a tile catalog shared with you by your supplier.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 6),
              Text(
                'Please open the catalog link your supplier sent you.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
