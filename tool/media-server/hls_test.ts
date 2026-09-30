import { assertEquals } from "jsr:@std/assert@1";
import { hlsArgs, rungsFor } from "./hls.ts";

Deno.test("never upscales, always has at least one rung", () => {
  assertEquals(rungsFor(1080).map((r) => r.height), [360, 720, 1080]);
  assertEquals(rungsFor(2160).map((r) => r.height), [360, 720, 1080]);
  assertEquals(rungsFor(720).map((r) => r.height), [360, 720]);
  assertEquals(rungsFor(240).map((r) => r.height), [360]);
  assertEquals(rungsFor(null).map((r) => r.height), [360, 720, 1080]);
});

Deno.test("stream map matches audio presence", () => {
  const withA = hlsArgs("in.mp4", "out", 720, true);
  assertEquals(withA[withA.indexOf("-var_stream_map") + 1], "v:0,a:0 v:1,a:1");
  const noA = hlsArgs("in.mp4", "out", 720, false);
  assertEquals(noA[noA.indexOf("-var_stream_map") + 1], "v:0 v:1");
  assertEquals(noA.includes("0:a:0"), false);
});
