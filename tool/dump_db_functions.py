"""Snapshot every Postgres function, view and trigger in the `public` schema.

The database renders each definition itself (pg_get_functiondef / _viewdef /
_triggerdef), and this script writes those bytes straight to a file. Nothing is
retyped or reformatted on the way, so the snapshot is exactly what Postgres
would print.

Read-only: it issues SELECTs and nothing else.

WHY THIS EXISTS
    supabase/migrations/ is a pile of incremental patches, not a rebuild path.
    Most tables, and 115 of the 217 functions, were created by hand in the SQL
    editor and never committed. The business logic — how a dispatch reduces
    stock, how an order tracks its remaining, how a buyer's catalogue is built —
    lived in exactly one place: the live Supabase project, on a free plan with no
    automatic backups. This puts it in git.

    It is a REFERENCE snapshot, not a runnable migration: the functions read
    tables, so they cannot be created before the tables exist. Capturing the
    tables too needs a real pg_dump.

AUTH
    Uses the Supabase personal access token that the MCP server already relies
    on (~/.claude.json), or $SUPABASE_ACCESS_TOKEN if set. No database password
    is needed, and nothing is created on the server.

USAGE
    python tool/dump_db_functions.py
"""

import datetime
import json
import os
import sys
import urllib.error
import urllib.request

PROJECT_REF = "buxjebeeiwyrsakeucyk"
API = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/database/query"

# api.supabase.com sits behind Cloudflare, which rejects urllib's default
# user-agent with "error code: 1010".
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0 Safari/537.36")

OUT = os.path.join("supabase", "snapshots",
                   f"{datetime.date.today():%Y%m%d}_functions_snapshot.sql")

FUNCS = """
select p.oid::regprocedure::text as sig, pg_get_functiondef(p.oid) as def
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.prokind = 'f'
order by p.proname, p.oid
"""

GRANTS = """
select p.oid::regprocedure::text as sig,
       coalesce(nullif(a.grantee::regrole::text, '-'), 'public') as grantee
from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
where n.nspname = 'public' and p.prokind = 'f' and a.privilege_type = 'EXECUTE'
order by 1, 2
"""

VIEWS = """
select c.relname as name, pg_get_viewdef(c.oid, true) as def
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind in ('v', 'm')
order by c.relname
"""

TRIGGERS = """
select t.tgname as name, pg_get_triggerdef(t.oid, true) as def
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and not t.tgisinternal
order by t.tgname
"""


def token():
    tok = os.environ.get("SUPABASE_ACCESS_TOKEN")
    if tok:
        return tok
    cfg = os.path.expanduser("~/.claude.json")
    try:
        args = json.load(open(cfg, encoding="utf-8"))["mcpServers"]["supabase"]["args"]
        return args[args.index("--access-token") + 1]
    except Exception as e:  # noqa: BLE001
        raise SystemExit(
            f"no token: set $SUPABASE_ACCESS_TOKEN, or configure the supabase "
            f"MCP server in {cfg} ({e})")


def query(tok, sql):
    req = urllib.request.Request(
        API, data=json.dumps({"query": sql}).encode(), method="POST",
        headers={"Authorization": f"Bearer {tok}",
                 "Content-Type": "application/json", "User-Agent": UA})
    try:
        return json.load(urllib.request.urlopen(req))
    except urllib.error.HTTPError as e:
        raise SystemExit(f"query failed: HTTP {e.code} {e.read()[:200]!r}")


def main():
    tok = token()
    print("fetching definitions ...", file=sys.stderr)
    funcs = query(tok, FUNCS)
    grants = query(tok, GRANTS)
    views = query(tok, VIEWS)
    triggers = query(tok, TRIGGERS)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(f"""-- Tiles Stock — snapshot of every public function, view and trigger.
-- Generated {datetime.datetime.now():%Y-%m-%d %H:%M} from project {PROJECT_REF}
-- by tool/dump_db_functions.py. Postgres rendered every definition below.
--
-- REFERENCE ONLY, not a runnable migration: these functions read tables, so
-- they cannot be created before the tables exist. Its purpose is that the
-- business logic lives in git — reviewable, diffable, recoverable.
--
--   functions: {len(funcs)}
--   views:     {len(views)}
--   triggers:  {len(triggers)}
--   grants:    {len(grants)}

""")
        f.write("-- " + "=" * 70 + "\n-- FUNCTIONS\n-- " + "=" * 70 + "\n\n")
        for r in funcs:
            f.write(f"-- {r['sig']}\n{r['def']};\n\n")

        f.write("-- " + "=" * 70 + "\n-- EXECUTE GRANTS\n-- " + "=" * 70 + "\n\n")
        for r in grants:
            f.write(f"grant execute on function {r['sig']} to {r['grantee']};\n")
        f.write("\n")

        if views:
            f.write("-- " + "=" * 70 + "\n-- VIEWS\n-- " + "=" * 70 + "\n\n")
            for r in views:
                f.write(f"create or replace view public.{r['name']} as\n{r['def']}\n\n")

        if triggers:
            f.write("-- " + "=" * 70 + "\n-- TRIGGERS\n-- " + "=" * 70 + "\n\n")
            for r in triggers:
                f.write(f"{r['def']};\n")

    print(f"wrote {OUT}")
    print(f"  {len(funcs)} functions, {len(views)} views, {len(triggers)} "
          f"triggers, {len(grants)} grants  ({os.path.getsize(OUT):,} bytes)")


if __name__ == "__main__":
    main()
