# Tiles Stock

A stock catalog for tile stockists. Stockists keep their inventory in the app; buyers browse it,
send inquiries, and receive dispatches. Runs on Android, iOS, web, and Windows from one Flutter
codebase, backed by Supabase.

The public web build is live at **[tilesdesign.in](https://tilesdesign.in)**.

## What it does

There are three kinds of user, and the app looks different for each:

- **Stockists** maintain a design library, record stock as it arrives, and dispatch it as it
  leaves. Stock can be entered by hand, batch-imported from an Excel sheet, or pulled out of a
  supplier's PDF catalog. Each stockist gets a shareable, login-free catalog link
  (`/s/<token>`) they can send to a buyer over WhatsApp.
- **Buyers** browse across stockists, filter by size, surface, colour and quality, and raise
  inquiries that become orders.
- **Admins** manage stockists, brands, and the shared design taxonomy.

## Running it

You'll need the Flutter SDK (Dart >= 3.0).

```bash
flutter pub get
flutter run
```

That's enough to run against the shared Supabase project — the client-side keys live in
`lib/config/app_config.dart`, so there's nothing to configure.

## Building

```bash
flutter build web               # deployed to Netlify
flutter build apk --release     # in.tilesdesign.stock
flutter build windows --release
flutter analyze                 # one known info-level warning
```

## Where things live

```
lib/
  app.dart              routes (go_router); /s/:token and /d/:token are public
  screens/              admin/, stockist/, end_user/ — one per role
  services/             data_service.dart is the interface, supabase_data_service.dart the impl
  models/ widgets/ utils/
supabase/migrations/    every schema change, timestamped
docs/                   plans and manual test checklists
```

The backend is reached entirely through Postgres functions rather than direct table queries.
`docs/PROJECT_VISION_AND_PLAN.md` explains the data model; `CLAUDE.md` is the short version,
including the naming rules the schema depends on.

## Status

Actively developed, deployed, and in real use. It is not a general-purpose product yet — some
behaviour is specific to how the current stockists work.
