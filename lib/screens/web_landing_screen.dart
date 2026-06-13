import 'package:flutter/material.dart';

/// Shown on the WEB build for any route that isn't a public share link. The web
/// build is published only to serve `/s/<token>` catalog pages — login, admin and
/// the buyer/stockist app live in the mobile app, never on the public domain.
class WebLandingScreen extends StatelessWidget {
  const WebLandingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // TilesDesign brand is cream-on-charcoal, so the landing uses a dark canvas.
    const bg = Color(0xFF222222);
    return Scaffold(
      backgroundColor: bg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Image.asset('assets/brand/tilesdesign_wide.png'),
              ),
              const SizedBox(height: 18),
              Text(
                'This page opens a tile catalog shared with you by your supplier.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey.shade300),
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
