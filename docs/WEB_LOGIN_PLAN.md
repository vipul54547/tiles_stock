# Login on the web

Status: ⛔ **PARKED by the user, 2026-07-11. DO NOT BUILD.**

> "let first app development first till that time no need, we will deploy only stock_list links,
> so do not allow login from web"

The lockdown in `lib/app.dart` **stays**: the web build serves `/s/` catalogue links (and `/d/`
receipts) and nothing else. Finish the app first.

Kept because the investigation found things that are true whether or not this ever ships — §3
(the device cap would lock out 12 of 15 users **today**) and §9 (hiding routes on the web is
cosmetic; the API is already fully exposed). Read those before reviving this.

Decisions in §2 were taken with the user and hold if the work is revived.

---

## 1. What is true today

The web build is deliberately crippled. `lib/app.dart:95` redirects **every** route except
`/s/:token`, `/reset-password` and `/web` to a landing page that says "open the link your
supplier sent you". The comment is explicit: *"login, admin and the buyer/stockist app live in
the mobile app, never on the public domain."*

So tilesdesign.in is not the app. It renders one supplier's shared catalogue and nothing else.

That decision is now reversed: **stockists and buyers log in on the web.**

## 2. Decisions (locked with the user, 2026-07-11)

1. **A browser is not a device.** `register_device` skips the cap when the label is `'Web'`.
2. **Stockist + buyer go live on web. Admin does NOT.** The 15 `/admin/*` routes keep redirecting.
3. **A signed-in buyer claims a `/s/` link on web. An anonymous visitor does not get a silent
   guest account.**

## 3. 🔴 The blocker, and why decision 1 exists

`device_limit` in the live DB **right now**:

| Who | limit | rows |
|---|---|---|
| stockists | 1 | 7 |
| stockists | 2 | 3 |
| end_users | 1 | 5 |

`register_device` counts a new device against that cap and returns `'blocked'`, which signs the
user back out with "This login is already active on the maximum number of devices allowed."

**Twelve of fifteen users are on a limit of 1.** Open web login with the cap as it stands and a
stockist who is signed in on their phone simply cannot get into the browser.

And on web the device id lives in `localStorage` (`DeviceId` → SharedPreferences). Clearing
browser data, switching Chrome→Edge, or opening incognito each mint a **new** device id that
permanently eats a slot — nothing ever prunes `user_devices`.

A browser is not a device. The cap exists to stop one login being shared across many phones; it
should keep doing exactly that, and stop pretending a browser tab is a phone.

## 4. Design

### A. Migration — `register_device` ignores the web

```sql
-- inside register_device, before the cap is enforced:
if p_label = 'Web' then
  -- A browser is not a device. Its id lives in localStorage, so clearing site
  -- data or opening another browser mints a new one — capping that locks people
  -- out of their own account for no security gain. The cap's real job is to stop
  -- one login being shared across phones; that is untouched.
  return 'ok';
end if;
```

No `user_devices` row is written for a browser, so nothing to prune later.
Everything else in the function is unchanged: a known device refreshes, a new phone/desktop is
still capped, admins are still unlimited.

⚠️ Read the current definition from the live schema before writing the migration — do not
reconstruct it from this document. (CLAUDE.md)

### B. The gate — `lib/app.dart`

The allow-list inverts into a **deny-list of one thing**:

```dart
if (!kIsWeb || kWebFullApp) return null;
// Admin never appears on the public domain. RLS is the real gate, but the panel
// should not be discoverable from the open internet.
return loc.startsWith('/admin') ? '/web' : null;
```

`/web` (`WebLandingScreen`) stays, as the destination for a blocked admin route. Its copy needs
rewording — it currently says "this page opens a stock catalogue shared with you", which will be
wrong once the site is also a login.

### C. The login page is phone-shaped

`login_screen.dart` is a `SingleChildScrollView` with **no max width**, so on a 1920px monitor
the email and password fields stretch edge to edge. Same story in `register_screen.dart` and
`create_login_screen.dart`.

Fix: centre the form in a `ConstrainedBox(maxWidth: 420)` on wide viewports. Phones are
unaffected (the constraint only bites above ~460px). This is a layout wrapper, not a rewrite —
the form, the guest button, "Forgot password?", Register and the support link all stay as they
are.

### D. Share links — `share_link_handler_screen.dart`

```dart
bool get _isEndUser => currentEndUserId.isNotEmpty;              // was !kIsWeb && …
bool get _canGuest  => !kIsWeb && currentEndUserId.isEmpty && …; // UNCHANGED — keep !kIsWeb
```

A signed-in buyer on the web now claims the supplier into My Suppliers, exactly as on the app.
An anonymous web visitor still just browses the public catalogue — **no silent guest account**,
because anonymous sign-ups from the open internet are a different thing entirely from a phone
app's onboarding funnel (and anon sign-ins are already an open item in
`project_supabase_security_advisor`).

### E. Session persistence

`supabase_flutter` persists the session to `localStorage` on web by default, so a refresh keeps
the user signed in. `SplashScreen` already routes by role off `checkExistingSession()`, and
`_deviceLabel()` already returns `'Web'` — web login was anticipated in the auth layer. Nothing
to build here; it needs **verifying**, not writing.

## 5. Routing — nothing to do

The site is **hash-routed**. `netlify.toml` runs a `catalog-preview` edge function on `/s/:token`
that serves OG tags to crawlers and redirects real browsers to `/#/s/<token>`. So `/#/login` and
every app route already resolve client-side with no server config, no SPA rewrite, and no
conflict with the edge function.

## 6. Phases

**Phase 1 — the cap.** Migration for `register_device`. Ship and verify on its own: an existing
phone login must keep working, and a second phone must still be blocked.

**Phase 2 — the gate + the landing copy.** Open the routes, keep `/admin` out, reword `/web`.

**Phase 3 — the login/register/create-login layout.** Centre the forms.

**Phase 4 — share links.** Drop `!kIsWeb` from `_isEndUser` only.

Phases 1 and 3 are independent. **Phase 1 must land before Phase 2** or the first stockist to try
the site gets locked out.

## 7. Must not break

- **The `/s/` public catalogue.** It is the only thing on the web today and it is in customers'
  hands. Anonymous, login-free, unchanged.
- **`/d/` dispatch receipts.** Same.
- **The crawler OG preview** on `/s/:token` — the edge function must keep working.
- **Existing phone/desktop logins.** The cap change must not let a second *phone* through.
- **Admin must not become reachable on the public domain.**

## 8. Not covered — verify before promising them on web

These have desktop/mobile branches and have **never been run in a browser**. None of them block
login; all of them are reachable from the stockist app once it is on the web, and any one could
be broken:

- Excel import / template download (`FilePicker.saveFile`, `File()` writes are guarded by
  `!kIsWeb` but the read path is untested).
- Supplier-PDF import.
- Cloudinary image upload (Add Design, banners).
- The admin bulk image importer — moot, admin is off the web.

Plan: ship login, then walk the stockist app in a browser and fix what falls over. Do not
advertise imports on web until they are actually exercised.

## 9. ⚠️ Security — true TODAY, with or without this plan

**The route redirect hides the UI, not the API.** The deployed web build already ships
`main.dart.js` containing the whole app: every one of the ~160 RPC names and the Supabase anon
key. Anyone can open devtools on tilesdesign.in right now and call `admin_*` directly.

So "admin is not on the web" is **defence in depth only**. The only thing that has ever stood
between the internet and the data is **RLS + the role checks inside the RPCs** — before this
plan, and after it.

Worth doing regardless of whether web login ever ships:

1. **Audit that every `admin_*` RPC checks the caller's role server-side.** Any that trusts the
   client is exploitable today.
2. **Anonymous sign-ups are enabled** (open item in `project_supabase_security_advisor`) — bots
   can mint accounts. This is why §4D keeps `_canGuest` off on web.
3. **Leaked-password protection is off** (HIBP, Pro-gated). A stockist reusing a breached
   password is the most likely way this actually gets breached.
4. Sessions live in `localStorage` → XSS steals a session. Low for Flutter web (canvas render,
   no `innerHTML`), not zero.
