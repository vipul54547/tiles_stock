# App Store Submission — Answer Sheet (Tiles Stock)

Everything you need to fill in **App Store Connect** for the Tiles Stock iOS app,
written so you can copy-paste. Drafted 2026-06-15.

- **App name:** Tiles Stock
- **Bundle ID:** `in.tilesdesign.stock`
- **Apple Team:** 269Z898HHC (Alpesh Moradiya)
- **Privacy Policy URL:** `https://tilesdesign.in/privacy.html` *(deploy `web/privacy.html` — see end)*
- **Support URL:** `https://tilesdesign.in`
- **Category:** Business (secondary: optional — Shopping)

> ⚠️ **You must confirm these 3 before submitting** (placeholders used in the drafts):
> 1. **Legal/seller name** shown on the store (currently "TilesDesign").
> 2. **Support email** — privacy page uses `support@tilesdesign.in`; make sure that
>    inbox exists, or change it (a Gmail is fine for a small business).
> 3. **Screenshots** — must be captured from a real build (TestFlight/Codemagic). See Phase 4/5.

---

## 1. App Privacy questionnaire (App Store Connect → App Privacy)

Answer **"Yes, we collect data from this app."** Then declare the data types below.
For **every** type: **Linked to the user? Yes.** **Used for tracking? NO** (we do not track
across other companies' apps/sites, no ads, no data brokers). Purpose = **App Functionality**
(and Account Management) only.

| Data type (Apple's list) | Collected? | Linked to user | Tracking | Purpose |
|---|---|---|---|---|
| Phone Number | Yes | Yes | No | App Functionality, Account |
| Name | Yes | Yes | No | App Functionality |
| Coarse/city location *(typed city, not GPS)* — declare under **"Other User Content"**, not Location | — | — | — | — |
| Other Contact Info (none beyond phone) | No | — | — | — |
| Photos or Videos *(stockists upload tile photos)* | Yes | Yes | No | App Functionality |
| User Content — other *(catalogues, enquiries, GST, city, company)* | Yes | Yes | No | App Functionality |
| Device ID | Yes | Yes | No | App Functionality (device-limit/session security) |
| Purchases | No | — | — | — |
| Location (precise/coarse GPS) | No | — | — | — |
| Contacts | No | — | — | — |
| Browsing/Search History | No | — | — | — |
| Identifiers — User ID | Yes | Yes | No | App Functionality, Account |
| Usage Data / Analytics | No | — | — | — |
| Diagnostics / Crash data | No | — | — | — |
| Financial Info / Payment | No | — | — | — |

**Key answers:**
- **Do you use data for tracking?** → **No.**
- **Third-party advertising?** → **No.**
- We do not show ads and do not use an analytics SDK.

> Note: We do **not** collect GPS location. The app only stores a **city the user types in**;
> declare that as User Content, not as "Location," to avoid implying GPS access.

---

## 2. Age Rating
- Answer **None** to all content categories (no violence, gambling, mature content, etc.).
- Result: **4+**.
- Unrestricted Web Access: the app does not embed an open web browser → **No**.

## 3. Export Compliance
- "Does your app use encryption?" → **Yes** (standard HTTPS/TLS only).
- "Does it qualify for the exemptions?" → **Yes** — uses only standard encryption (HTTPS)
  and no proprietary/non-standard cryptography. **Exempt.**
- You can set `ITSAppUsesNonExemptEncryption = NO` in Info.plist to skip this question each
  build *(optional — tell me to add it)*.

---

## 4. Listing text (copy-paste)

**Subtitle (max 30 chars):**
> Tile stock & catalogues

**Promotional text (max 170 chars):**
> Share your tile stock catalogues, browse what your suppliers have in stock, and send
> enquiries on WhatsApp — all in one place.

**Keywords (max 100 chars, comma-separated, no spaces):**
> tiles,tile,stock,catalogue,ceramic,vitrified,stockist,supplier,inventory,dealer,marble,godown

**Description:**
```
Tiles Stock connects tile stockists and buyers.

FOR STOCKISTS
• Publish your tile stock catalogues — organise designs into your own stock lists.
• Upload tile photos from your camera or gallery, or import from a catalogue PDF / Excel.
• Track box quantities, sizes, finishes and tile types.
• Share a private link with each customer — the link always works, and opens straight in the app.
• Receive enquiries and confirm orders, then send a dispatch report on WhatsApp.

FOR BUYERS
• Browse the live stock catalogues your suppliers share with you.
• Search by size, finish, colour and tile type with smart search.
• Save designs to "My Choice" and send an enquiry to your supplier on WhatsApp.
• Keep all your suppliers in one place.

• Browse as a guest — no sign-up needed to look around.
• Sign in securely with your phone number.
• Delete your account and data any time from inside the app.

Tiles Stock is the mobile app of TilesDesign (tilesdesign.in).
```

**Support URL:** `https://tilesdesign.in`
**Marketing URL (optional):** `https://tilesdesign.in`
**Privacy Policy URL:** `https://tilesdesign.in/privacy.html`
**Copyright:** `2026 TilesDesign`
**Primary language:** English (India)

---

## 5. App Review notes (paste into "Notes" / "App Review Information")

```
HOW TO TEST WITHOUT LOGGING IN:
The app supports full Guest browsing — on the first screen, continue as a guest to
browse and use the app without an account. No login is required to review the app.

SIGN-IN (optional):
Sign-in uses a phone number + one-time SMS code. The SMS provider may not deliver
codes to non-Indian numbers during review, so please use GUEST MODE to evaluate the
app. (We do not use Google/Facebook social login, so Sign in with Apple does not apply.)

ACCOUNT DELETION (Guideline 5.1.1(v)):
Account creation supports in-app deletion. To find it: open the app, tap the menu
(three dots, "Account") in the top-right of the home screen next to the logout icon,
choose "Delete account", and confirm twice. This permanently deletes the account and
its data.

CAMERA / PHOTOS:
Camera and Photo Library are used only when a stockist uploads tile photos. Reason
strings are provided in Info.plist.
```

**Demo account fields:** leave blank, and tick that a demo isn't needed (Guest mode covers it).
If the reviewer insists on a login, we can provision a test phone via the SMS provider once it's live.

**Contact (App Review Information):** your name, phone (+91 97269 66906), email.

---

## 6. Screenshots (required — capture later)
Needed sizes (use a TestFlight build on a borrowed iPhone, or the simulator on the
Codemagic build):
- **6.7"** iPhone (e.g. 15 Pro Max) — 1290 × 2796 — **required**.
- **6.5"** iPhone — 1242 × 2688 — recommended.
- iPad only if you ship an iPad build (the app is iPhone-first; you can mark iPhone-only).

Suggested 4–6 shots: guest browse grid, a stockist's stock catalogue, design detail/My
Choice, the share-link / stock-list screen, enquiry on WhatsApp.

---

## 7. Deploy the privacy policy (do this before submitting)
The policy page lives at `web/privacy.html`. It is copied to `build/web/privacy.html`
on `flutter build web` and served directly by Netlify (no SPA redirect swallows it):

```
flutter build web --release
netlify deploy --prod          # site curious-druid-1cbbfb → tilesdesign.in
```
Then verify `https://tilesdesign.in/privacy.html` loads (HTTP 200) before pasting the
URL into App Store Connect.

---

## Status checklist
- [x] In-app account deletion built (Delete Account) — Guideline 5.1.1(v).
- [x] Privacy Policy drafted (`web/privacy.html`).
- [x] App Privacy questionnaire answers drafted (Section 1).
- [x] Age rating / export compliance / listing text / review notes drafted.
- [ ] Confirm legal name + support email + that the policy is deployed live.
- [ ] Device-verify Delete Account on a THROWAWAY account.
- [ ] SMS/OTP provider (your gate) — needed for full login during review.
- [ ] Screenshots from a real build.
- [ ] Phases 1–5 of `IOS_RELEASE_PLAN.md` (App Store Connect record → Codemagic → TestFlight → submit).
