"""Full schema backup of the Supabase project via the bundled Supabase CLI.

This is the REAL backup — canonical pg_dump output covering every table,
constraint, index, sequence, RLS policy, function, view and trigger. Unlike
tool/dump_db_functions.py (functions only, reference), this can rebuild the
database structure. It complements the migration history, which alone cannot
(only 3 of 37 tables have a CREATE TABLE anywhere in supabase/migrations/).

The database password is required and is read interactively, so it never lands
in a shell history or a chat log. Get it from the Supabase dashboard:
    supabase.com  ->  (sign in with the GitHub account that OWNS the project:
    vipulghodasara / vipul54547@gmail.com)  ->  project buxjebeeiwyrsakeucyk
    ->  Settings  ->  Database  ->  Database password  ->  Reset, then copy.

Resetting the password is safe: the app authenticates with the anon API key,
not this password, so nothing in production uses it.

Usage:
    python tool/dump_full_backup.py

Writes, under supabase/snapshots/:
    full_schema.sql   every schema object (the structural backup)
    roles.sql         cluster roles
"""

import getpass
import os
import subprocess
import sys
import urllib.parse

REF = "buxjebeeiwyrsakeucyk"
# Resolve paths from THIS file's location, not the current directory, so the
# script works whether it's launched from the project root or from tool\.
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(ROOT, "tool", "bin", "supabase.exe")
OUTDIR = os.path.join(ROOT, "supabase", "snapshots")

# The direct host db.<ref>.supabase.co is IPv6-only and unreachable on IPv4
# home networks, so go straight to the IPv4 session pooler (port 5432, user
# postgres.<ref>), which diagnostics showed is open.
def db_urls(pw):
    enc = urllib.parse.quote(pw, safe="")
    return [
        ("IPv4 pooler",
         f"postgresql://postgres.{REF}:{enc}@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres"),
    ]


def run_dump(db_url, extra, out_path):
    # --debug so pg_dump's real error reaches stderr instead of the CLI's
    # generic "rerun with --debug" line.
    cmd = [CLI, "db", "dump", "--db-url", db_url, "-f", out_path, "--debug"] + extra
    return subprocess.run(cmd, capture_output=True, text=True)


def dump(label, extra, filename, pw):
    out = os.path.join(OUTDIR, filename)
    for how, url in db_urls(pw):
        print(f"  {label}: connecting via {how} ...", file=sys.stderr)
        r = run_dump(url, extra, out)
        if r.returncode == 0 and os.path.exists(out) and os.path.getsize(out) > 0:
            print(f"  {label}: wrote {out}  ({os.path.getsize(out):,} bytes)")
            return True
        # surface the real reason: last ~15 non-empty stderr lines, with the
        # password scrubbed just in case the CLI echoes the URL.
        err = (r.stderr or r.stdout or "")
        err = err.replace(urllib.parse.quote(pw, safe=""), "***").replace(pw, "***")
        tail = [l for l in err.splitlines() if l.strip()][-15:]
        print(f"    {how} failed (exit {r.returncode}):", file=sys.stderr)
        for l in tail:
            print(f"      {l}", file=sys.stderr)
    return False


def read_password():
    """Password source, in order of convenience:
      1. $SUPABASE_DB_PASSWORD
      2. tool/db_password.txt  — paste it there, save; we read then DELETE it
      3. hidden terminal prompt (input is invisible; right-click pastes in cmd)
    """
    env = os.environ.get("SUPABASE_DB_PASSWORD")
    if env and env.strip():
        return env.strip()

    pwfile = os.path.join(ROOT, "tool", "db_password.txt")
    if os.path.exists(pwfile):
        with open(pwfile, encoding="utf-8") as f:
            pw = f.read().strip()
        os.remove(pwfile)  # don't leave the password on disk
        print("  read password from tool/db_password.txt (now deleted)",
              file=sys.stderr)
        return pw

    try:
        return getpass.getpass(
            "Supabase database password (typing is hidden — paste with "
            "right-click, then Enter): ").strip()
    except Exception:
        # some terminals can't do hidden input; fall back to visible
        return input("Supabase database password (visible): ").strip()


def main():
    if not os.path.exists(CLI):
        raise SystemExit(f"CLI not found at {CLI}")
    os.makedirs(OUTDIR, exist_ok=True)
    pw = read_password()
    if not pw:
        raise SystemExit("no password entered")

    ok_schema = dump("schema", [], "full_schema.sql", pw)
    ok_roles = dump("roles", ["--role-only"], "roles.sql", pw)

    print()
    if ok_schema:
        print("Backup complete. full_schema.sql is the structural backup.")
        if not ok_roles:
            print("(roles.sql failed, but the schema — the important part — is saved.)")
    else:
        print("Schema dump failed. If both hosts errored with authentication, the "
              "password is wrong — reset it in the dashboard and retry. If it timed "
              "out, your network may block the DB port; tell Claude and we'll adjust.")
        sys.exit(1)


if __name__ == "__main__":
    main()
