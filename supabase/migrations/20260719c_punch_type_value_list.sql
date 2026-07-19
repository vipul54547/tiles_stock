-- ═══ PUNCH TYPE is an ADMIN VALUE-LIST, not a stockist free-text field ════════════════════════
--
-- Punch ▸ Punch Type ▸ (free text). The admin owns the Punch and Punch Type lists; the stockist
-- SELECTS a Punch, then a Punch Type (Box/Wave under Emboss, Slat Punch/Sandstone under Texture),
-- and only at the LEAF gives a free-text word. That is the value-list + free_text_detail shape the
-- DNA editor already renders (parent dropdown → scoped child dropdown → detail word).
--
-- Punch Type was mis-created as `is_free_text = true`, which:
--   • let the STOCKIST invent Punch Types (admin does not allow that), and
--   • HID its 5 values and the "Free-text detail" toggle in the admin screen
--     (manage_design_dna_screen shows both only for `!is_free_text`).
-- The admin "edit attribute" RPC cannot flip is_free_text (it is set only at create), so fix it here.
-- The 5 values already exist (scoped under their Punch) — nothing is lost; they simply reappear.

update dna_attributes
   set is_free_text     = false,   -- it is an admin list, not stockist free text
       free_text_detail = true,    -- the stockist's own word lives at the LEAF, per Punch Type value
       allow_mapping    = false    -- admin words only (free_text_detail forces this anyway)
 where name = 'Punch Type';

-- self-check (raise only on FAILURE)
do $$
declare v_ff boolean; v_ftd boolean; v_vals int;
begin
  select is_free_text, free_text_detail into v_ff, v_ftd
    from dna_attributes where name = 'Punch Type';
  select count(*) into v_vals
    from dna_values v join dna_attributes a on a.id = v.attribute_id
   where a.name = 'Punch Type' and v.is_active and v.stockist_id is null and lower(v.name) <> 'none';
  if v_ff is not false or v_ftd is not true then
    raise exception 'FAILED: Punch Type is_free_text=% free_text_detail=%', v_ff, v_ftd;
  end if;
  raise notice 'OK: Punch Type is now a value-list + free-text detail, % admin values visible', v_vals;
end $$;
