import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';

import 'config/app_config.dart';
import 'app.dart';
import 'services/supabase_data_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url:     AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabaseAnonKey,
  );

  // Tile-type densities drive the DERIVED thickness (weight / (pieces × area × density)) and
  // the buyer's thickness-band filter, and `densityFor()` is called synchronously inside
  // build() — so the table is pulled into a cache once, here. It is anon-readable, so buyers
  // get it too. Best-effort: on failure the built-in kTileDensity fallback (the same numbers)
  // stands, and nothing breaks. (docs/BOX_AND_DERIVED_THICKNESS_PLAN.md)
  unawaited(SupabaseDataService().refreshTileTypes());
  // The NOMINAL thickness list is part of product identity (the Library editor declares it),
  // so the picker must offer the table's list, not a stale const.
  // (docs/THICKNESS_AND_BODY_IDENTITY_PLAN.md)
  unawaited(SupabaseDataService().refreshThicknessOptions());

  runApp(const TilesStockApp());
}

// Global Supabase client — imported by all services
final supabase = Supabase.instance.client;
