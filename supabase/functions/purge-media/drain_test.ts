import { assertEquals } from "jsr:@std/assert@1";
import { drain, type QueueRow } from "./drain.ts";

function fakeQueue(rows: QueueRow[], failBucket?: string) {
  const queue = [...rows];
  const removed: string[] = [];
  return {
    removed,
    queue,
    deps: {
      claim: (limit: number) => Promise.resolve(queue.slice(0, limit)),
      remove(bucket: string, names: string[]) {
        if (bucket === failBucket) return Promise.reject(new Error("boom"));
        removed.push(...names.map((n) => `${bucket}/${n}`));
        return Promise.resolve();
      },
      forget(bucket: string, names: string[]) {
        for (let i = queue.length - 1; i >= 0; i--) {
          if (
            queue[i].bucket_id === bucket &&
            names.includes(queue[i].object_name)
          ) {
            queue.splice(i, 1);
          }
        }
        return Promise.resolve();
      },
    },
  };
}

Deno.test("drains every queued object across batches", async () => {
  const rows = Array.from({ length: 7 }, (_, i) => ({
    bucket_id: "post-media",
    object_name: `u/${i}.jpg`,
  }));
  const f = fakeQueue(rows);
  const res = await drain(f.deps, { batch: 3 });
  assertEquals(res, { removed: 7, failed: 0 });
  assertEquals(f.queue.length, 0);
});

Deno.test("a failing bucket stays queued and doesn't block the others", async () => {
  const f = fakeQueue([
    { bucket_id: "broken", object_name: "a" },
    { bucket_id: "post-media", object_name: "b" },
  ], "broken");
  const res = await drain(f.deps, { batch: 10 });
  assertEquals(res, { removed: 1, failed: 1 });
  assertEquals(f.queue, [{ bucket_id: "broken", object_name: "a" }]);
  assertEquals(f.removed, ["post-media/b"]);
});

Deno.test("empty queue is a no-op", async () => {
  const f = fakeQueue([]);
  assertEquals(await drain(f.deps), { removed: 0, failed: 0 });
});
