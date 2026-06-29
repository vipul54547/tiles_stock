-- Stock list limit is now stockist-wide (across all brands), not per-brand.
-- Drops the per-brand limit RPC and auto-seeding of lists on brand creation.

-- 1. create_stock_list: count stockist-wide, not per-brand
CREATE OR REPLACE FUNCTION public.create_stock_list(p_brand_id uuid, p_name text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_stk uuid; v_limit int; v_count int; v_order int; v_id uuid;
        v_anon boolean;
        v_name text := trim(coalesce(p_name,''));
begin
  select id, coalesce(stock_list_limit,3), coalesce(is_anonymous,false)
    into v_stk, v_limit, v_anon from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can create stock lists'; end if;
  if v_name = '' then raise exception 'Stock list name cannot be empty'; end if;
  if not exists (select 1 from brands where id = p_brand_id and stockist_id = v_stk) then
    raise exception 'Brand not found';
  end if;
  select count(*) into v_count from stock_catalogs where stockist_id = v_stk and is_active;
  if v_count >= v_limit then
    raise exception 'Stock list limit reached (%). Ask the admin to allow more.', v_limit;
  end if;
  if exists (select 1 from stock_catalogs where brand_id = p_brand_id and lower(name) = lower(v_name)) then
    raise exception 'You already have a stock list with that name';
  end if;
  select coalesce(max(sort_order),0)+10 into v_order from stock_catalogs where brand_id = p_brand_id;
  insert into stock_catalogs (stockist_id, brand_id, name, visibility, show_in_marketplace, sort_order, is_anonymous)
    values (v_stk, p_brand_id, v_name, 'private', false, v_order, v_anon)
    returning id into v_id;
  return v_id;
end; $function$;

-- 2. create_brand: no auto-seeded lists
CREATE OR REPLACE FUNCTION public.create_brand(p_name text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_stk uuid; v_limit int; v_count int; v_brand uuid;
        v_name text := trim(coalesce(p_name,''));
begin
  select id, coalesce(brand_limit,1)
    into v_stk, v_limit from stockists where user_id = auth.uid();
  if v_stk is null then raise exception 'Only stockists can create brands'; end if;
  if v_name = '' then raise exception 'Brand name cannot be empty'; end if;
  select count(*) into v_count from brands where stockist_id = v_stk;
  if v_count >= v_limit then
    raise exception 'Brand limit reached (%). Ask the admin to allow more.', v_limit;
  end if;
  if exists (select 1 from brands where stockist_id = v_stk and lower(name) = lower(v_name)) then
    raise exception 'You already have a brand with that name';
  end if;
  insert into brands (stockist_id, name, sort_order)
    values (v_stk, v_name, v_count) returning id into v_brand;
  return v_brand;
end; $function$;

-- 3. admin_add_brand: no auto-seeded lists
CREATE OR REPLACE FUNCTION public.admin_add_brand(p_seq text, p_name text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_stk uuid; v_count int; v_brand uuid;
        v_name text := btrim(coalesce(p_name,''));
begin
  if current_user_role() <> 'admin' then raise exception 'Only admins can add brands'; end if;
  select id into v_stk from stockists where sequential_id = p_seq;
  if v_stk is null then raise exception 'Stockist not found'; end if;
  select count(*) into v_count from brands where stockist_id = v_stk;
  if v_name = '' then v_name := 'Brand ' || (v_count + 1); end if;
  if exists (select 1 from brands where stockist_id = v_stk and lower(name) = lower(v_name)) then
    raise exception 'A brand with that name already exists';
  end if;
  insert into brands (stockist_id, name, sort_order)
    values (v_stk, v_name, v_count) returning id into v_brand;
  update stockists set brand_limit = greatest(coalesce(brand_limit,1), v_count + 1) where id = v_stk;
  return v_brand;
end; $function$;

-- 4. _ensure_stockist_capacity: fill brands only, no list seeding
CREATE OR REPLACE FUNCTION public._ensure_stockist_capacity(p_stk uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_bl int; v_count int; v_n int; v_name text;
begin
  select greatest(coalesce(brand_limit,1),1)
    into v_bl from stockists where id = p_stk;
  if v_bl is null then return; end if;
  select count(*) into v_count from brands where stockist_id = p_stk;
  v_n := v_count;
  while v_count < v_bl loop
    v_n := v_n + 1;
    v_name := 'Brand ' || v_n;
    if exists (select 1 from brands where stockist_id = p_stk and lower(name) = lower(v_name)) then
      continue;
    end if;
    insert into brands (stockist_id, name, sort_order, status, is_active)
      values (p_stk, v_name, v_count, 'live', true);
    v_count := v_count + 1;
  end loop;
end; $function$;

-- 5. purge_scheduled_brand_deletes: replacement brand only, no lists
CREATE OR REPLACE FUNCTION public.purge_scheduled_brand_deletes()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare r record; n int := 0; v_count int; v_name text;
begin
  for r in select id, stockist_id from brands
           where delete_scheduled_at is not null
             and delete_scheduled_at < now() - interval '24 hours'
             and is_default = false loop
    delete from stock_catalogs where brand_id = r.id;
    delete from brands where id = r.id;
    select count(*) into v_count from brands where stockist_id = r.stockist_id;
    v_name := 'Brand ' || (v_count + 1);
    while exists (select 1 from brands where stockist_id = r.stockist_id
                  and lower(name) = lower(v_name)) loop
      v_count := v_count + 1;
      v_name := 'Brand ' || (v_count + 1);
    end loop;
    insert into brands (stockist_id, name, sort_order)
      values (r.stockist_id, v_name,
              (select count(*) from brands where stockist_id = r.stockist_id));
    n := n + 1;
  end loop;
  return n;
end; $function$;

-- 6. Drop dead RPCs
DROP FUNCTION IF EXISTS public.admin_set_brand_stock_list_limit(uuid, integer);
DROP FUNCTION IF EXISTS public._seed_brand_lists(uuid, uuid, integer);
