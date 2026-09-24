#!/usr/bin/env python3
"""Download a few public-domain NASA clips into local Storage and post them.

Idempotent: a post is skipped when one with the same title already exists.
Not a migration — the bytes are not in git. Run against the local database:

    python3 tool/seed_videos.py
"""

import json
import os
import subprocess
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLIPS = [
    {
        "author": "webb",
        "title": "29 days on the edge",
        "body": "A public-domain look at the James Webb Space Telescope's deployment. NASA / ESA.",
        "mp4": "http://images-assets.nasa.gov/video/29_DAYS_ON_THE_EDGE-VOTY_Entry-h264/29_DAYS_ON_THE_EDGE-VOTY_Entry-h264~mobile.mp4",
        "poster": "http://images-assets.nasa.gov/video/29_DAYS_ON_THE_EDGE-VOTY_Entry-h264/29_DAYS_ON_THE_EDGE-VOTY_Entry-h264~thumb.jpg",
        "slug": "jwst-29-days",
    },
    {
        "author": "hubble",
        "title": "Hubble's 29th anniversary",
        "body": "Hubble's 29th anniversary film. Public domain, NASA / ESA.",
        "mp4": "http://images-assets.nasa.gov/video/GSFC_20190424_HST_m13189_Hubble29/GSFC_20190424_HST_m13189_Hubble29~mobile.mp4",
        "poster": "http://images-assets.nasa.gov/video/GSFC_20190424_HST_m13189_Hubble29/GSFC_20190424_HST_m13189_Hubble29~medium.jpg",
        "slug": "hubble-29",
    },
    {
        "author": "launches",
        "title": "Artemis I launch",
        "body": "Artemis I leaving the pad. Public domain, NASA.",
        "mp4": "http://images-assets.nasa.gov/video/A1Launch/A1Launch~mobile.mp4",
        "poster": "http://images-assets.nasa.gov/video/A1Launch/A1Launch~thumb.jpg",
        "slug": "artemis-i",
    },
    {
        "author": "launches",
        "title": "Apollo 11 moonwalk",
        "body": "Apollo 11 on the lunar surface. Public domain, NASA.",
        "mp4": "http://images-assets.nasa.gov/video/Apollo_11_moonwalk_montage_720p/Apollo_11_moonwalk_montage_720p~mobile.mp4",
        "poster": "http://images-assets.nasa.gov/video/Apollo_11_moonwalk_montage_720p/Apollo_11_moonwalk_montage_720p~thumb.jpg",
        "slug": "apollo-11-moonwalk",
    },
]


def service_role() -> str:
    env = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if env:
        return env
    out = subprocess.check_output(
        ["supabase", "status", "-o", "env"],
        cwd=ROOT / "supabase",
        text=True,
    )
    for line in out.splitlines():
        if line.startswith("SERVICE_ROLE_KEY="):
            return line.split("=", 1)[1].strip().strip('"')
    raise SystemExit("no service role key")


def download(url: str, dest: Path) -> None:
    if dest.exists() and dest.stat().st_size > 0:
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    urllib.request.urlretrieve(url, dest)


def upload(key: str, path: Path, content_type: str, object_path: str) -> None:
    req = urllib.request.Request(
        f"http://127.0.0.1:54321/storage/v1/object/post-media/{object_path}",
        data=path.read_bytes(),
        method="POST",
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": content_type,
            "x-upsert": "true",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as res:
            res.read()
    except urllib.error.HTTPError as e:
        body = e.read().decode()[:300]
        if e.code == 409 or "already exists" in body.lower():
            return
        raise SystemExit(f"upload {object_path} failed {e.code}: {body}") from e


def main() -> None:
    import urllib.error

    key = service_role()
    cache = Path("/tmp/peak-seed-videos")
    sql = ["begin;"]
    for i, clip in enumerate(CLIPS):
        mp4 = cache / f"{clip['slug']}.mp4"
        poster = cache / f"{clip['slug']}.jpg"
        print(f"fetch {clip['slug']}")
        download(clip["mp4"], mp4)
        download(clip["poster"], poster)
        print(f"upload {clip['slug']} ({mp4.stat().st_size / 1e6:.1f} MB)")
        upload(key, mp4, "video/mp4", f"seed/{clip['slug']}.mp4")
        upload(key, poster, "image/jpeg", f"seed/{clip['slug']}.jpg")
        title = clip["title"].replace("'", "''")
        body = clip["body"].replace("'", "''")
        author = clip["author"]
        slug = clip["slug"]
        minutes = i + 1
        sql.append(
            f"""
insert into post (author_id, persona_id, body, title, visibility, created_at)
select u.id, pe.id, '{body}', '{title}', 'public', now() - interval '{minutes} minutes'
from auth.users u
join persona pe on pe.account_id = u.id and pe.is_default
where u.email = '{author}@peak.social'
  and not exists (select 1 from post p where p.title = '{title}');
insert into post_media (post_id, kind, storage_path, poster_path, alt_text, width, height, sort_order)
select p.id, 'video', 'seed/{slug}.mp4', 'seed/{slug}.jpg', '{title}', 1280, 720, 0
from post p
where p.title = '{title}'
  and not exists (select 1 from post_media m where m.post_id = p.id);
"""
        )
    sql.append("commit;")
    sql_path = cache / "insert.sql"
    sql_path.write_text("\n".join(sql))
    subprocess.check_call(
        [
            "psql",
            "postgresql://postgres:postgres@127.0.0.1:54322/postgres",
            "-v",
            "ON_ERROR_STOP=1",
            "-f",
            str(sql_path),
        ]
    )
    print(json.dumps({"clips": len(CLIPS)}))


if __name__ == "__main__":
    main()
