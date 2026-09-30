// HLS ladder for one uploaded MP4: <dir>/<id>/master.m3u8 plus v0/, v1/, …
// renditions of 4-second MPEG-TS segments. Built into <id>.hls-tmp and
// renamed into place only when complete, so a half-built ladder is never
// served — players fall back to the MP4 until master.m3u8 exists.

import { join } from "jsr:@std/path@1";

const RUNGS = [
  { height: 360, v: "800k", max: "856k", buf: "1200k" },
  { height: 720, v: "2800k", max: "2996k", buf: "4200k" },
  { height: 1080, v: "5000k", max: "5350k", buf: "7500k" },
];

/** The renditions worth making for a source this tall (never upscale). */
export function rungsFor(sourceHeight: number | null) {
  const h = sourceHeight ?? 1080;
  const fit = RUNGS.filter((r) => r.height <= h);
  return fit.length > 0 ? fit : [RUNGS[0]];
}

/** ffmpeg arguments for the ladder (pure, so it's unit-tested). */
export function hlsArgs(
  src: string,
  outDir: string,
  sourceHeight: number | null,
  hasAudio: boolean,
): string[] {
  const rungs = rungsFor(sourceHeight);
  const n = rungs.length;
  const split = `[0:v]split=${n}${rungs.map((_, i) => `[s${i}]`).join("")}`;
  const scales = rungs.map((r, i) => `[s${i}]scale=-2:${r.height}[o${i}]`);
  const args = [
    "-y",
    "-i",
    src,
    "-filter_complex",
    [split, ...scales].join(";"),
  ];
  rungs.forEach((r, i) => {
    args.push(
      "-map",
      `[o${i}]`,
      `-c:v:${i}`,
      "libx264",
      `-b:v:${i}`,
      r.v,
      `-maxrate:v:${i}`,
      r.max,
      `-bufsize:v:${i}`,
      r.buf,
    );
  });
  if (hasAudio) {
    for (let i = 0; i < n; i++) args.push("-map", "0:a:0");
    args.push("-c:a", "aac", "-b:a", "128k", "-ac", "2");
  }
  args.push(
    "-preset",
    "veryfast",
    "-pix_fmt",
    "yuv420p",
    "-g",
    "48",
    "-keyint_min",
    "48",
    "-sc_threshold",
    "0",
    "-f",
    "hls",
    "-hls_time",
    "4",
    "-hls_playlist_type",
    "vod",
    "-hls_segment_type",
    "mpegts",
    "-hls_segment_filename",
    join(outDir, "v%v", "seg%03d.ts"),
    "-master_pl_name",
    "master.m3u8",
    "-var_stream_map",
    rungs.map((_, i) => (hasAudio ? `v:${i},a:${i}` : `v:${i}`)).join(" "),
    join(outDir, "v%v", "index.m3u8"),
  );
  return args;
}

async function hasAudioStream(src: string): Promise<boolean> {
  const { stdout } = await new Deno.Command("ffprobe", {
    args: [
      "-v",
      "error",
      "-select_streams",
      "a",
      "-show_entries",
      "stream=index",
      "-of",
      "csv=p=0",
      src,
    ],
    stdout: "piped",
    stderr: "null",
  }).output();
  return new TextDecoder().decode(stdout).trim().length > 0;
}

/** Builds <dir>/<id>/ from <dir>/<id>.mp4. Throws on ffmpeg failure. */
export async function buildHls(
  dir: string,
  id: string,
  sourceHeight: number | null,
): Promise<void> {
  const src = join(dir, `${id}.mp4`);
  const tmp = join(dir, `${id}.hls-tmp`);
  const final = join(dir, id);
  await Deno.remove(tmp, { recursive: true }).catch(() => {});
  const { code, stderr } = await new Deno.Command("ffmpeg", {
    args: hlsArgs(src, tmp, sourceHeight, await hasAudioStream(src)),
    stdout: "null",
    stderr: "piped",
  }).output();
  if (code !== 0) {
    await Deno.remove(tmp, { recursive: true }).catch(() => {});
    const msg = new TextDecoder().decode(stderr).split("\n").slice(-4).join(
      " ",
    );
    throw new Error(`ffmpeg hls exited ${code}: ${msg}`);
  }
  await Deno.remove(final, { recursive: true }).catch(() => {});
  await Deno.rename(tmp, final);
}

// One ladder at a time: transcoding three renditions is CPU-heavy, and
// uploads shouldn't wait on each other.
let chain: Promise<void> = Promise.resolve();

export function queueHls(dir: string, id: string, sourceHeight: number | null) {
  chain = chain
    .then(() => buildHls(dir, id, sourceHeight))
    .then(() => console.log(`hls ready: ${id}`))
    .catch((e) =>
      console.error(
        `hls failed for ${id}: ${e instanceof Error ? e.message : e}`,
      )
    );
}
