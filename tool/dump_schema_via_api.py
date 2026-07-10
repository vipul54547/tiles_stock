"""Reconstruct the full public schema from the live catalog, via the Supabase
Management API. No Docker, no database password — uses the personal access
token the MCP server already relies on (~/.claude.json or $SUPABASE_ACCESS_TOKEN).

The Supabase CLI's `db dump` needs Docker (it runs pg_dump in a container), which
isn't installed here. This reproduces the important part — the schema — by asking
Postgres for each object's definition (pg_get_constraintdef / _indexdef /
pg_get_expr, and assembled CREATE TABLEs) and writing them in dependency order.

Output: supabase/snapshots/full_schema.sql — extensions, sequences, tables,
constraints, indexes, RLS + policies, functions, views, triggers, table grants.

Best-effort runnable (it's ordered sensibly), but its real job is disaster
recovery: unlike supabase/migrations/ (only 3 of 37 tables have a CREATE TABLE),
this captures the whole structure so the database can be rebuilt or diffed.
"""

import datetime
import json
import os
import sys
import urllib.error
import urllib.request

REF = "buxjebeeiwyrsakeucyk"
API = f"https://api.supabase.com/v1/projects/{REF}/database/query"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0 Safari/537.36")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "supabase", "snapshots", "full_schema.sql")


def token():
    t = os.environ.get("SUPABASE_ACCESS_TOKEN")
    if t:
        return t
    cfg = os.path.expanduser("~/.claude.json")
    args = json.load(open(cfg, encoding="utf-8"))["mcpServers"]["supabase"]["args"]
    return args[args.index("--access-token") + 1]


def q(tok, sql):
    req = urllib.request.Request(
        API, data=json.dumps({"query": sql}).encode(), method="POST",
        headers={"Authorization": f"Bearer {tok}",
                 "Content-Type": "application/json", "User-Agent": UA})
    try:
        return json.load(urllib.request.urlopen(req))
    except urllib.error.HTTPError as e:
        raise SystemExit(f"query failed: HTTP {e.code} {e.read()[:300]!r}")


# ── catalog queries ───────────────────────────────────────────────────────────

Q_EXT = """select 'CREATE EXTENSION IF NOT EXISTS "'||extname||'";' as s
from pg_extension e join pg_namespace n on n.oid=e.extnamespace
where extname not in ('plpgsql') order by extname"""

Q_SEQ = """select 'CREATE SEQUENCE IF NOT EXISTS public.'||c.relname||';' as s
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind='S' order by c.relname"""

Q_TBL = """select c.relname as tbl,
  'CREATE TABLE IF NOT EXISTS public.'||c.relname||E' (\n'||
  string_agg('    '||a.attname||' '||format_type(a.atttypid,a.atttypmod)
    ||case when a.attidentity in ('a','d') then ' GENERATED '||
        case a.attidentity when 'a' then 'ALWAYS' else 'BY DEFAULT' end||' AS IDENTITY' else '' end
    ||case when a.attnotnull then ' NOT NULL' else '' end
    ||case when ad.adbin is not null and a.attidentity not in ('a','d')
        then ' DEFAULT '||pg_get_expr(ad.adbin,ad.adrelid) else '' end,
    E',\n' order by a.attnum)||E'\n);' as ddl
from pg_class c join pg_namespace n on n.oid=c.relnamespace
join pg_attribute a on a.attrelid=c.oid and a.attnum>0 and not a.attisdropped
left join pg_attrdef ad on ad.adrelid=c.oid and ad.adnum=a.attnum
where n.nspname='public' and c.relkind='r'
group by c.relname order by c.relname"""

# non-FK constraints first (PK/UNIQUE/CHECK), then FKs after all tables exist
Q_CON = """select c.contype, rel.relname as tbl,
  'ALTER TABLE public.'||rel.relname||' ADD CONSTRAINT '||c.conname||' '||
  pg_get_constraintdef(c.oid)||';' as s
from pg_constraint c join pg_class rel on rel.oid=c.conrelid
join pg_namespace n on n.oid=rel.relnamespace
where n.nspname='public' order by (c.contype='f'), rel.relname, c.conname"""

Q_IDX = """select indexdef||';' as s
from pg_indexes where schemaname='public'
  and indexname not in (
    select conname from pg_constraint c join pg_class r on r.oid=c.conrelid
    join pg_namespace n on n.oid=r.relnamespace where n.nspname='public')
order by tablename, indexname"""

Q_RLS = """select 'ALTER TABLE public.'||c.relname||' ENABLE ROW LEVEL SECURITY;' as s
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind='r' and c.relrowsecurity order by c.relname"""

Q_POL = """select 'CREATE POLICY '||quote_ident(pol.polname)||' ON public.'||c.relname||
  ' AS '||case pol.polpermissive when true then 'PERMISSIVE' else 'RESTRICTIVE' end||
  ' FOR '||case pol.polcmd when 'r' then 'SELECT' when 'a' then 'INSERT'
        when 'w' then 'UPDATE' when 'd' then 'DELETE' else 'ALL' end||
  ' TO '||coalesce((select string_agg(quote_ident(r.rolname),', ')
        from pg_roles r where r.oid=any(pol.polroles)),'public')||
  coalesce(' USING ('||pg_get_expr(pol.polqual,pol.polrelid)||')','')||
  coalesce(' WITH CHECK ('||pg_get_expr(pol.polwithcheck,pol.polrelid)||')','')||';' as s
from pg_policy pol join pg_class c on c.oid=pol.polrelid
join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' order by c.relname, pol.polname"""

Q_FUNC = """select pg_get_functiondef(p.oid)||';' as s
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.prokind='f' order by p.proname, p.oid"""

Q_VIEW = """select 'CREATE OR REPLACE VIEW public.'||c.relname||' AS '||
  pg_get_viewdef(c.oid,true) as s
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind in ('v','m') order by c.relname"""

Q_TRIG = """select pg_get_triggerdef(t.oid,true)||';' as s
from pg_trigger t join pg_class c on c.oid=t.tgrelid
join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and not t.tgisinternal order by t.tgname"""

Q_GRANT = """select 'GRANT '||privilege_type||' ON public.'||table_name||' TO '||grantee||';' as s
from information_schema.role_table_grants
where table_schema='public' and grantee in ('anon','authenticated','service_role')
order by table_name, grantee, privilege_type"""


def section(f, title, rows, key="s"):
    f.write(f"\n-- {'='*72}\n-- {title}\n-- {'='*72}\n\n")
    for r in rows:
        f.write(r[key] + "\n")
    return len(rows)


def main():
    tok = token()
    print("querying catalog ...", file=sys.stderr)
    ext = q(tok, Q_EXT); seq = q(tok, Q_SEQ); tbl = q(tok, Q_TBL)
    con = q(tok, Q_CON); idx = q(tok, Q_IDX); rls = q(tok, Q_RLS)
    pol = q(tok, Q_POL); fn = q(tok, Q_FUNC); vw = q(tok, Q_VIEW)
    trg = q(tok, Q_TRIG); grt = q(tok, Q_GRANT)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(f"""-- Tiles Stock — FULL SCHEMA, reconstructed from the live catalog.
-- Generated {datetime.datetime.now():%Y-%m-%d %H:%M} from project {REF}
-- by tool/dump_schema_via_api.py (Management API; no Docker, no DB password).
--
-- Disaster-recovery backup: extensions, sequences, tables, constraints,
-- indexes, RLS + policies, functions, views, triggers, and table grants for
-- the public schema. Ordered for rebuild (sequences before tables, non-FK
-- constraints before FKs). Auth/storage schemas and row DATA are NOT included.
--
-- Contains SECURITY DEFINER bodies — gitignored, do not publish.

SET search_path TO public, extensions;
""")
        n = {}
        n['extensions'] = section(f, "EXTENSIONS", ext)
        n['sequences'] = section(f, "SEQUENCES", seq)
        n['tables'] = section(f, "TABLES", tbl, key="ddl")
        n['constraints'] = section(f, "CONSTRAINTS (PK/UNIQUE/CHECK then FK)", con)
        n['indexes'] = section(f, "INDEXES", idx)
        n['rls'] = section(f, "ROW LEVEL SECURITY", rls)
        n['policies'] = section(f, "POLICIES", pol)
        n['functions'] = section(f, "FUNCTIONS", fn)
        n['views'] = section(f, "VIEWS", vw)
        n['triggers'] = section(f, "TRIGGERS", trg)
        n['grants'] = section(f, "TABLE GRANTS", grt)

    print(f"wrote {OUT}  ({os.path.getsize(OUT):,} bytes)")
    for k, v in n.items():
        print(f"  {k:12} {v}")


if __name__ == "__main__":
    main()
