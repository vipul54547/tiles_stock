# iOS Release Plan — Tiles Stock

A step-by-step plan to get the app onto the **Apple App Store**, written for a
Windows user with **no Mac**, who already has a **paid Apple Developer account**
(Team ID `269Z898HHC`).

The build is done on a **cloud Mac (Codemagic)** — you never need to own a Mac.
Testing is done on a **dealer's iPhone via TestFlight** — you never need to own an
iPhone.

Legend: 🤖 = Claude does it (code) · 👤 = you do it (browser/Apple) · 🤝 = together

---

## Key facts (so there are no surprises)

- **Cost:** ₹0 extra. Apple charges **$99/year per ACCOUNT, not per app** — already paid.
  Unlimited apps under your one account.
- **Bundle id (final):** `in.tilesdesign.stock` (same as Android plan, matches the
  website AASA file already live).
- ⚠️ **Current mismatch to fix first:** the iOS project still says
  `com.example.tilesStock`. The website expects `in.tilesdesign.stock`. Until these
  match, iOS "open link in app" (Universal Links) won't verify. Fixed in Phase 0.
- **Login & App Review:** the app uses **phone + OTP** and a **guest trial** (browse
  without login). That's good — Apple reviewers can use **Guest mode** to test, so we
  likely don't need to hand them a demo account. (We are NOT using Google/Facebook
  social login, so Apple's "Sign in with Apple" requirement does **not** apply.)

---

## Phase 0 — Code prep (🤖 Claude, on Windows)

No Mac needed for these. I do them in the repo and push.

- [ ] Change iOS bundle id `com.example.tilesStock` → `in.tilesdesign.stock`
      (in `ios/Runner.xcodeproj/project.pbxproj`).
- [ ] Confirm display name stays **"Tiles Stock"** (already set).
- [ ] Add the **Associated Domains** entitlement for Universal Links
      (`applinks:tilesdesign.in`) so tapping a `/s/...` link opens the app.
- [ ] Make sure required usage descriptions are in `Info.plist`
      (Camera + Photo Library — the app uses both for uploads). Apple **rejects**
      apps that access these without a reason string.
- [ ] App icon present for iOS (reuse the existing logo).

**You don't do anything in Phase 0** — just approve when I say it's ready to push.

---

## Phase 1 — Create the app record in App Store Connect (👤 you, ~15 min)

This reserves your app's page on the store. Browser only — no Mac.

1. Go to **https://appstoreconnect.apple.com** → sign in.
2. **My Apps → "+" → New App.**
3. Fill in:
   - Platform: **iOS**
   - Name: **Tiles Stock** (must be unique on the App Store; if taken, we pick a variant)
   - Primary language: **English (India)**
   - Bundle ID: select **`in.tilesdesign.stock`**
     - If it's not in the list: **Certificates, IDs & Profiles → Identifiers → "+"**
       → App IDs → App → enter `in.tilesdesign.stock`, enable **Associated Domains**.
   - SKU: any text, e.g. `tilesstock001`
4. Click **Create**. Done — the empty app page now exists.

---

## Phase 2 — Give Codemagic permission to build & upload (👤 you, ~15 min)

Codemagic is the cloud Mac. It needs a key to talk to your Apple account.

1. In **App Store Connect → Users and Access → Integrations → App Store Connect API**
   → generate an **API Key** with **App Manager** role.
2. Download the **.p8 key file** and note the **Key ID** and **Issuer ID**
   (Apple shows the .p8 only once — save it safely).
3. 🤝 Send me the **Key ID + Issuer ID** (NOT the secret file contents) so I can
   pre-fill the Codemagic config. You upload the .p8 file itself into Codemagic
   directly (it's a secret — I never see it).

---

## Phase 3 — Set up Codemagic (🤝 together, ~30 min)

1. 👤 Go to **https://codemagic.io** → sign up with your **GitHub** account.
2. 👤 Authorize it to see the **`vipul54547/tiles_stock`** repo → add the app.
3. 👤 In Codemagic → Team settings → **Apple Developer Portal / App Store Connect**
   → add the API key (.p8 + Key ID + Issuer ID from Phase 2).
4. 🤖 I add a **`codemagic.yaml`** file to the repo that:
   - builds the Flutter iOS app,
   - signs it automatically using your Apple key,
   - uploads it to **TestFlight**.
5. 🤝 First build run — we fix any signing hiccups together (normal on first try).

---

## Phase 4 — Test on real iPhones via TestFlight (🤝)

No Mac, no owning an iPhone needed — your dealers test it.

1. After the build lands in **TestFlight** (App Store Connect → TestFlight tab):
2. 👤 Add testers by email (yourself + a few trusted dealers/stockists on iPhone),
   or create a **public TestFlight link** to share on WhatsApp.
3. 👤 Testers install the free **TestFlight** app from the App Store, tap your link,
   install Tiles Stock.
4. 🤝 Test checklist on iPhone:
   - [ ] App opens, guest browsing works
   - [ ] Phone + OTP login works *(needs the SMS provider — see note below)*
   - [ ] Save a supplier, send a WhatsApp enquiry
   - [ ] Tapping a `tilesdesign.in/s/...` link opens the app (Universal Link)
   - [ ] Camera + photo upload work

> ⚠️ **OTP dependency:** real OTP texts still need the **SMS provider setup** (your
> separate pending task). Until then, login OTP won't send on iOS *or* Android. Guest
> mode + browsing can be tested without it.

---

## Phase 5 — Submit to the App Store (👤 you, with my help on text)

1. In App Store Connect, fill the listing (🤖 I'll draft all the text for you):
   - Description, keywords, support URL (`tilesdesign.in`), privacy policy URL
   - **Screenshots** — required (I'll tell you exact sizes; we can capture from a
     TestFlight iPhone or the Codemagic build).
   - **App Privacy** questionnaire (what data you collect: phone number, etc.)
2. Select the TestFlight build → **Submit for Review**.
3. Apple reviews in ~1–3 days. If they reject, they say why → 🤝 we fix and resubmit
   (very common on first submit, not a problem).
4. Approved → choose **release** → live on the App Store. 🎉

---

## What I (Claude) need from you to start

- ✅ **Phase 0:** nothing — just say "do Phase 0" and I prepare + push the code.
- For Phase 1–2: you do them in the browser; send me **Key ID + Issuer ID** (not the
  secret file).
- I never need your Apple password or the .p8 secret — those stay with you.

## Order I recommend

**Phase 0 now** (code is ready and matches the website) → then you do **Phase 1**
whenever you have 15 minutes → then we do Codemagic together. Android can keep moving
in parallel.

---

## Honest watch-outs

- **First Codemagic build often fails on signing** — normal, we iterate. Budget an
  hour for the first green build.
- **App Review can reject** for: missing privacy policy, camera/photo reason strings,
  or reviewer can't log in. We've pre-handled these (guest mode + reason strings).
- **SMS/OTP** must be live for the full login experience to pass review cleanly — line
  this up with the same provider task that blocks Android.
- Keep the **.p8 key safe** — Apple shows it only once.
