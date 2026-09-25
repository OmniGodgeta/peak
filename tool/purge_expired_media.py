#!/usr/bin/env python3
"""Hard-delete posts past the 30-day window, then remove their Storage objects.

Soft-deleted posts are left alone. Reads the local service role from
`supabase status` and does not print it.
"""
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def status_env():
    out = subprocess.check_output(
        ["supabase", "status", "-o", "env"], cwd=ROOT, text=True
    )
    env = {}
    for line in out.splitlines():
        if "=" not in line or line.startswith("Stopped"):
            continue
        key, value = line.split("=", 1)
        env[key] = value.strip().strip('"')
    return env


def psql(sql):
    subprocess.run(
        [
            "docker",
            "exec",
            "-i",
            "supabase_db_peak",
            "psql",
            "-U",
            "postgres",
            "-d",
            "postgres",
            "-v",
            "ON_ERROR_STOP=1",
            "-q",
        ],
        input=sql,
        text=True,
        check=True,
    )


def main():
    env = status_env()
    api = env["API_URL"].rstrip("/")
    key = env["SERVICE_ROLE_KEY"]
    psql("select purge_expired_deletions();")
    rows = subprocess.check_output(
        [
            "docker",
            "exec",
            "supabase_db_peak",
            "psql",
            "-U",
            "postgres",
            "-d",
            "postgres",
            "-tA",
            "-c",
            "select bucket_id || '	' || object_name from media_pending_delete order by queued_at;",
        ],
        text=True,
    )
    removed = 0
    for line in rows.splitlines():
        if not line.strip():
            continue
        bucket, name = line.split("\t", 1)
        body = json.dumps({"prefixes": [name]}).encode()
        req = urllib.request.Request(
            f"{api}/storage/v1/object/{bucket}",
            data=body,
            method="DELETE",
            headers={
                "Authorization": f"Bearer {key}",
                "apikey": key,
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req) as res:
                res.read()
        except urllib.error.HTTPError as exc:
            if exc.code != 404:
                print(f"storage delete failed for {bucket}/{name}: {exc.code}", file=sys.stderr)
                return 1
        safe = name.replace("'", "''")
        psql(
            "delete from media_pending_delete "
            f"where bucket_id = '{bucket}' and object_name = '{safe}';"
        )
        removed += 1
    print(f"removed {removed} stored object(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
