-- ═══ A free-text word REUSES the admin value, never mints a duplicate ═════════════════════════
--
-- Series has an admin seed "Regular". `dna_set_design_text` looked only for the STOCKIST'S OWN
-- value by name, so picking/typing "Regular" minted a SECOND, stockist-owned "Regular" beside the
-- admin one — two "Regular"s in the Series picker. Same trap for any free-text attribute with an
-- admin seed.
--
-- Fix: match an existing value by name (own OR admin), preferring the admin canonical, and only
-- mint a stockist value when the word is genuinely new. Then collapse the duplicates already made.

-- ── 1. the writer reuses an existing value ──────────────────────────────────────────────────
create or replace function public.dna_set_design_text(
  p_library_id uuid, p_attribute_id uuid, p_texts text[]
) returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_stk uuid; v_t text; v_name text; v_id uuid; v_ids uuid[] := array[]::uuid[];
begin
  select id into v_stk from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists'; end if;
  if not exists (select 1 from stockist_library where id = p_library_id and stockist_id = v_stk) then
    raise exception 'Not your design'; end if;
  if not exists (select 1 from dna_attributes where id = p_attribute_id and is_free_text) then
    raise exception 'Not a free-text attribute'; end if;

  foreach v_t in array coalesce(p_texts, array[]::text[]) loop
    v_name := btrim(v_t);
    if v_name = '' then continue; end if;
    -- Reuse an admin OR own value with this name; prefer the admin canonical so wording unifies.
    select id into v_id from dna_values
     where attribute_id = p_attribute_id
       and lower(name) = lower(v_name)
       and (stockist_id = v_stk or stockist_id is null)
     order by (stockist_id is null) desc
     limit 1;
    if v_id is null then
      insert into dna_values (attribute_id, name, stockist_id)
        values (p_attribute_id, v_name, v_stk)
        returning id into v_id;
    end if;
    if not (v_id = any(v_ids)) then v_ids := array_append(v_ids, v_id); end if;
  end loop;

  delete from library_dna ld using dna_values v
    where ld.value_id = v.id and ld.library_id = p_library_id
      and v.attribute_id = p_attribute_id;
  insert into library_dna (library_id, value_id)
    select p_library_id, x from unnest(v_ids) x;
end;
$function$;

-- ── 2. collapse the duplicates already minted (stockist value that twins an admin one) ──────
-- Match on attribute + name (+ same parent, if any). Repoint every design onto the admin value,
-- drop rows that would collide, then delete the stockist duplicate.
with dup as (
  select sv.id as sid, av.id as aid
    from dna_values sv
    join dna_attributes a on a.id = sv.attribute_id and a.is_free_text
    join dna_values av
      on av.attribute_id = sv.attribute_id
     and av.stockist_id is null
     and lower(av.name) = lower(sv.name)
     and av.parent_value_id is not distinct from sv.parent_value_id
   where sv.stockist_id is not null
)
update library_dna ld set value_id = d.aid
  from dup d
 where ld.value_id = d.sid
   and not exists (
     select 1 from library_dna l2 where l2.library_id = ld.library_id and l2.value_id = d.aid);

with dup as (
  select sv.id as sid
    from dna_values sv
    join dna_attributes a on a.id = sv.attribute_id and a.is_free_text
    join dna_values av
      on av.attribute_id = sv.attribute_id and av.stockist_id is null
     and lower(av.name) = lower(sv.name)
     and av.parent_value_id is not distinct from sv.parent_value_id
   where sv.stockist_id is not null
)
delete from library_dna ld using dup d where ld.value_id = d.sid;  -- any left were collisions

with dup as (
  select sv.id as sid
    from dna_values sv
    join dna_attributes a on a.id = sv.attribute_id and a.is_free_text
    join dna_values av
      on av.attribute_id = sv.attribute_id and av.stockist_id is null
     and lower(av.name) = lower(sv.name)
     and av.parent_value_id is not distinct from sv.parent_value_id
   where sv.stockist_id is not null
)
delete from dna_values sv using dup d where sv.id = d.sid;

-- ── 3. self-check (raise only on FAILURE) ───────────────────────────────────────────────────
do $$
declare v_dups int;
begin
  select count(*) into v_dups
    from dna_values sv
    join dna_attributes a on a.id = sv.attribute_id and a.is_free_text
    join dna_values av on av.attribute_id = sv.attribute_id and av.stockist_id is null
     and lower(av.name) = lower(sv.name)
     and av.parent_value_id is not distinct from sv.parent_value_id
   where sv.stockist_id is not null;
  if v_dups > 0 then raise exception 'FAILED: % free-text duplicates remain', v_dups; end if;
  raise notice 'OK: free-text values reuse the admin canonical; duplicates collapsed';
end $$;
