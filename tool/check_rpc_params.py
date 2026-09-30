#!/usr/bin/env python3
"""Checks every `.rpc('name', params: {...})` call in app/lib against the
function signatures in the local database (supabase_db_peak container).

PostgREST matches functions by *parameter names*: renaming a parameter in a
migration, or sending one the function doesn't take, makes the call fail at
runtime with PGRST202 — nothing at compile time or in CI notices. On
2026-09-30 this found two live breakages (posts_by, suggested_communities).

Run after `supabase migration up`. Exit 1 on a mismatch. Calls whose params
are built in a variable are listed as unchecked, not failed.
"""
import glob
import re
import subprocess
import sys

ROOT = __file__.rsplit("/tool/", 1)[0]
src = "\n".join(open(f).read() for f in glob.glob(f"{ROOT}/app/lib/**/*.dart", recursive=True))

def top_level_keys(block):
    """Keys of the outermost map literal only (nested maps are values)."""
    keys, depth, i = set(), 0, 0
    while i < len(block):
        c = block[i]
        if c in "{[(":
            depth += 1
        elif c in "}])":
            depth -= 1
        elif c == "'" and depth == 1:
            m = re.match(r"'([a-z_][a-z_0-9]*)'\s*:", block[i:])
            if m:
                keys.add(m.group(1))
            j = block.index("'", i + 1)
            i = j
        i += 1
    return keys


calls = {}
unchecked = set()
for m in re.finditer(r"\.rpc\(\s*'([a-z_0-9]+)'\s*(?:,\s*params:\s*(\{.*?\}|[A-Za-z_]\w*))?", src, re.S):
    name, params = m.group(1), m.group(2)
    if params and not params.startswith("{"):
        unchecked.add(name)
        continue
    keys = top_level_keys(params or "")
    calls.setdefault(name, []).append(keys)

out = subprocess.check_output(
    ["docker", "exec", "-i", "supabase_db_peak", "psql", "-U", "postgres", "-tA", "-F", "|", "-c",
     "select proname, coalesce(array_to_string(proargnames[1:pronargs], ','), ''), pronargs, pronargdefaults "
     "from pg_proc p join pg_namespace n on n.oid = p.pronamespace where nspname = 'public'"],
    text=True,
)
db = {}
for line in out.strip().splitlines():
    name, args, nargs, ndef = line.split("|")
    allargs = [a for a in args.split(",") if a]
    required = set(allargs[: int(nargs) - int(ndef)])
    db.setdefault(name, []).append((set(allargs), required))

bad = 0
for name, uses in sorted(calls.items()):
    if name not in db:
        print(f"MISSING FUNCTION  {name}")
        bad += 1
        continue
    for keys in uses:
        if not any(keys <= a and r <= keys for a, r in db[name]):
            sigs = ", ".join(f"({', '.join(sorted(a))})" for a, _ in db[name])
            print(f"MISMATCH  {name}: app sends {sorted(keys)}; database has {sigs}")
            bad += 1
print(f"checked {len(calls)} RPCs; {bad} problem(s); unchecked (dynamic params): {', '.join(sorted(unchecked)) or 'none'}")
sys.exit(1 if bad else 0)
