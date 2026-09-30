// Builds HLS ladders for media-server videos uploaded before adaptive
// streaming existed. Safe to re-run: skips any video that already has one.
//
//   MEDIA_ROOT=/path/to/peak-media deno task backfill-hls
//
// The app finds these by convention (<id>.mp4 -> <id>/master.m3u8), so no
// database change is needed.

import { join } from "jsr:@std/path@1";
import { buildHls } from "./hls.ts";

const root = Deno.env.get("MEDIA_ROOT");
if (!root) {
  console.error("set MEDIA_ROOT");
  Deno.exit(1);
}

async function height(src: string): Promise<number | null> {
  const { stdout } = await new Deno.Command("ffprobe", {
    args: [
      "-v",
      "error",
      "-select_streams",
      "v:0",
      "-show_entries",
      "stream=height",
      "-of",
      "csv=p=0",
      src,
    ],
    stdout: "piped",
    stderr: "null",
  }).output();
  const h = Number(new TextDecoder().decode(stdout).trim());
  return Number.isFinite(h) && h > 0 ? h : null;
}

let built = 0, skipped = 0, failed = 0;
for await (const user of Deno.readDir(root)) {
  if (!user.isDirectory) continue;
  const dir = join(root, user.name);
  for await (const f of Deno.readDir(dir)) {
    const m = f.name.match(/^([0-9a-f-]{36})\.mp4$/);
    if (!f.isFile || !m) continue;
    try {
      await Deno.stat(join(dir, m[1], "master.m3u8"));
      skipped++;
      continue;
    } catch { /* no ladder yet */ }
    try {
      await buildHls(dir, m[1], await height(join(dir, f.name)));
      built++;
      console.log(`built ${user.name}/${m[1]}`);
    } catch (e) {
      failed++;
      console.error(
        `failed ${user.name}/${m[1]}: ${e instanceof Error ? e.message : e}`,
      );
    }
  }
}
console.log(
  `done: ${built} built, ${skipped} already had one, ${failed} failed`,
);
