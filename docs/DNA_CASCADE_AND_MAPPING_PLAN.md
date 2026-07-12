# DNA: per-attribute mapping switch + generic parent→child (cascading) values

Status: **PLANNED, not built.** Written 2026-07-12 (DDPI — decisions locked with the user).

Two independent features on the Design-DNA engine:
- **A. Mapping on/off per attribute** — admin decides whether a stockist may attach their own
  word, or must pick the admin's canonical value.
- **B. Generic parent→child values** — an attribute can *depend on* another; its values are
  scoped to a parent value, so the stockist's second selector shows only the children of what
  they picked (Look Type → Natural Name, Punch → Punch Look).

---

## 1. Decisions (locked with the user, 2026-07-12)

1. **Generic**, not hard-wired: admin can point *any* attribute at a parent attribute.
2. **Map off ⇒ admin words only.** When mapping is off for an attribute, the stockist can only
   select the admin canonical values — no own word, no alias. (Map on = today's behaviour.)
3. **Child needs its parent.** A child value is selectable only after its parent value is chosen;
   nothing else changes until then.
4. **None** stays the default option at every level.
5. **Buyer filters stay FLAT** — no cascade for buyers. Buyer *display* is unchanged; the buyer
   filter panel keeps showing each attribute as its own facet (Look Type and Natural Name side by
   side), exactly as today.
6. **Natural Name and Punch Look are rebuilt from scratch** — old values + their design tags are
   cleared when they become dependent.

---

## 2. Current model (verified against the live DB, 2026-07-12)

- **dna_attributes** `(id, name, sort_order, is_multi, is_free_text, is_active, show_in_facets)`
  — e.g. Look Type, Punch, Natural Name, Punch Look, Colour…
- **dna_values** `(id, attribute_id, name, sort_order, is_active, stockist_id)` — `stockist_id null`
  = admin canonical; non-null = a stockist's own value. A leading **None** value per attribute.
- **dna_aliases** `(stockist_id, attribute_id, raw_text, value_id)` — a stockist's word mapped to a
  canonical value. **This is "mapping."**
- **library_dna** `(library_id, value_id)` — the actual design tags.
- Today **Natural Name** is a *flat, independent* attribute (None, Satuario, Traventino, Onexy) and
  **Punch Look** is a *free-text* attribute — neither knows a parent. That is exactly what B changes.

Key RPCs: `dna_catalog` (attributes+values for tagging), `dna_set_design(library, attribute,
value_ids[])` (replace one attribute's tags on a design), the alias set `dna_learn_alias` /
`dna_resolve` / `dna_set_value_words` / `dna_rename_my_value` / `dna_delete_my_value`, the admin set
`admin_dna_add_attribute` / `admin_dna_update_attribute` / `admin_dna_add_value` /
`admin_dna_update_value` / `admin_dna_delete_value`, and buyer `public_dna_catalog` /
`public_dna_facets`.

---

## 3. Data-model changes (3 columns — nothing dropped)

```sql
alter table dna_attributes
  add column allow_mapping boolean not null default true,          -- Feature A
  add column parent_attribute_id uuid references dna_attributes(id); -- Feature B

alter table dna_values
  add column parent_value_id uuid references dna_values(id);        -- Feature B
```

- **allow_mapping** — false ⇒ stockist picks admin values only.
- **parent_attribute_id** — set on the *child* attribute (e.g. Natural Name → Look Type). Null =
  independent, like every attribute today.
- **parent_value_id** — set on each *child value* (e.g. "Carara".parent_value_id = "Marble".id).
  Null on values of a non-dependent attribute.

Invariant: a value's `parent_value_id`, when set, points at a value whose `attribute_id` =
this value's attribute's `parent_attribute_id`. Enforced in the admin RPC, not by a DB constraint
(cross-row check).

---

## 4. Admin — `manage_design_dna_screen.dart` + `admin_dna_*` RPCs

Per attribute, add two controls:
- **Mapping** toggle → `allow_mapping`.
- **Depends on** → a parent-attribute picker → `parent_attribute_id` (choices = other active,
  non-dependent attributes; guard against cycles / self).

When an attribute *is* dependent, the **Add value** form gains a required **Parent value** picker
(the parent attribute's values). So the admin builds, e.g. under Look Type = Stone: "kota stone,
black granite, slate, sand stone"; under Marble: "Carara, Satuario, Onyx, Piatra, Botochino, Armani".

RPC changes:
- `admin_dna_update_attribute` → add `p_allow_mapping`, `p_parent_attribute_id` (validate no cycle;
  changing/clearing a parent must clear stale `parent_value_id`s + orphaned tags — see §7).
- `admin_dna_add_value` / `admin_dna_update_value` → add `p_parent_value_id` (required when the
  attribute is dependent; must belong to the parent attribute).
- `dna_catalog` **and** `public_dna_catalog` → return `allow_mapping`, `parent_attribute_id` per
  attribute and `parent_value_id` per value.

---

## 5. Stockist — cascading tag UI + map-off enforcement

Tagging entry points: `dna_editor_sheet.dart`, `manage_my_dna_values_screen.dart`,
`my_dna_words_screen.dart` (all read `dna_catalog`).

**Cascade (B):** render dependent attributes *after* their parent. The child selector is **disabled
until the parent value is chosen**, then shows only values whose `parent_value_id` = the chosen
parent value's id (plus None). Change the parent ⇒ clear the child selection.

**Map-off (A):** when `allow_mapping = false`, hide the "add your own word / new value" affordance —
the stockist picks from admin values only. The alias/own-value RPCs must **refuse** for that
attribute server-side (belt-and-braces): `dna_learn_alias`, `dna_set_value_words`,
`dna_rename_my_value`, and any own-value insert check `allow_mapping` and raise if off.

**Integrity in `dna_set_design`:**
- If the attribute is dependent, reject a `value_id` whose `parent_value_id` is **not** currently in
  `library_dna` for this library (parent must be set first).
- When setting a **parent** attribute, delete any now-orphaned child tags on this library (child
  whose `parent_value_id` is no longer among the library's tags for the parent attribute).

---

## 6. Buyer — no change (decision 5)

`public_dna_facets` / buyer filter panel keep every attribute flat. Design detail already renders
whatever tags the stockist applied. The extra columns are ignored on the buyer side; we do **not**
cascade buyer facets. (If ever wanted, it's a later, separate change.)

---

## 7. One-time data rebuild (decision 6)

Natural Name and Punch Look become dependent, rebuilt from scratch:
1. `parent_attribute_id`: Natural Name → **Look Type**; Punch Look → **Punch**. (Punch Look also
   flips from free-text to a value-list attribute.)
2. Delete their existing `dna_values` (Satuario, Traventino, Onexy, …) **and** the `library_dna`
   rows referencing them (orphaned tags). Keep each attribute's **None**.
3. The admin then creates the child values under each parent value via the new UI (§4).

A migration does step 1–2; step 3 is manual admin work once Phase 1 ships.

---

## 8. Phases

- **Phase 1 — schema + admin.** The 3 columns; `admin_dna_*` + `dna_catalog`/`public_dna_catalog`
  updated; admin UI (Mapping toggle, Depends-on, Parent-value on Add value). Ship first so the admin
  can build the child lists. Independent attributes behave exactly as today.
- **Phase 2 — stockist cascade + map-off.** The dependent second selector, map-off hiding, and the
  `dna_set_design` integrity + alias-refusal rules.
- **Phase 3 — data rebuild.** Migration for §7 step 1–2; then admin builds the lists.

Phase 1 is safe to ship alone (defaults: `allow_mapping=true`, no parents → today's behaviour).

---

## 9. Must not break

- **Every existing attribute stays independent** until an admin sets a parent — defaults preserve
  today's behaviour exactly.
- **The deactivated "Surface" `dna_attribute` stays untouched** (`is_active=false`) — do NOT
  reactivate it (superseded; see memory). This work is unrelated to surface.
- **Buyer facets + design display** — unchanged (decision 5).
- **Map-on attributes** — aliasing keeps working as now.
- **`None`** stays selectable/default at every level.

---

## 10. Test checklist

Admin:
- [ ] Toggle Mapping off on an attribute → stockist no longer sees "add own word" for it.
- [ ] Set Natural Name "Depends on" = Look Type → Add value now requires a parent value.
- [ ] Cycle guard: cannot set A→B and B→A; cannot self-parent.

Stockist tagging:
- [ ] Pick Look Type = Marble → Natural Name activates, shows only Marble's children + None.
- [ ] Pick Look Type = Stone → Natural Name shows Stone's children (not Marble's).
- [ ] Change Look Type after choosing a Natural Name → the Natural Name clears.
- [ ] Punch = Groove → Punch Look shows Groove's children; Punch = Texture → Texture's.
- [ ] Map-off attribute → only admin values selectable; server refuses an alias write.
- [ ] `dna_set_design` rejects a child value whose parent isn't set on the design.

Data:
- [ ] Old Natural Name values + their design tags are gone; None remains.
- [ ] Buyer filters still show Look Type and Natural Name as separate flat facets.
