// The part of purge-media that does the work, split out so it can be tested
// with a fake client.

export interface QueueRow {
  bucket_id: string;
  object_name: string;
}

export interface DrainDeps {
  /** Up to `limit` queued rows, oldest first. */
  claim(limit: number): Promise<QueueRow[]>;
  /** Remove objects from a bucket. Throws on failure. */
  remove(bucket: string, names: string[]): Promise<void>;
  /** Drop rows from the queue once their objects are gone. */
  forget(bucket: string, names: string[]): Promise<void>;
}

export interface DrainResult {
  removed: number;
  failed: number;
}

/**
 * Removes queued objects bucket by bucket, in batches. A batch that fails
 * stays queued for the next run; a missing object counts as removed
 * (Storage's remove() doesn't error on names that aren't there).
 */
export async function drain(
  deps: DrainDeps,
  { batch = 100, maxBatches = 20 } = {},
): Promise<DrainResult> {
  let removed = 0;
  let failed = 0;
  const failedKeys = new Set<string>();
  for (let i = 0; i < maxBatches; i++) {
    const rows = (await deps.claim(batch + failedKeys.size)).filter(
      (r) => !failedKeys.has(`${r.bucket_id}/${r.object_name}`),
    ).slice(0, batch);
    if (rows.length === 0) break;
    const byBucket = new Map<string, string[]>();
    for (const r of rows) {
      byBucket.set(r.bucket_id, [
        ...(byBucket.get(r.bucket_id) ?? []),
        r.object_name,
      ]);
    }
    for (const [bucket, names] of byBucket) {
      try {
        await deps.remove(bucket, names);
        await deps.forget(bucket, names);
        removed += names.length;
      } catch {
        failed += names.length;
        for (const n of names) failedKeys.add(`${bucket}/${n}`);
      }
    }
    if (rows.length < batch) break;
  }
  return { removed, failed };
}
