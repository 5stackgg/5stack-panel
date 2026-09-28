import { afterEach, beforeEach, describe, it, mock } from "node:test";
import assert from "node:assert/strict";
import worker from "./index.ts";

const env = {
  S3_ACCESS_KEY: "key",
  S3_SECRET: "secret",
  BUCKET_NAME: "5stack",
  S3_ENDPOINT: "s3.example.test",
};
const ORIGIN = "https://5stack.gg";

const realFetch = globalThis.fetch;
let upstream: ReturnType<typeof mock.fn>;

beforeEach(() => {
  upstream = mock.fn(
    async () =>
      new Response("{}", {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
  );
  globalThis.fetch = upstream as unknown as typeof fetch;
  (globalThis as any).caches = {
    default: { match: async () => undefined, put: async () => {} },
  };
});

afterEach(() => {
  globalThis.fetch = realFetch;
  delete (globalThis as any).caches;
});

async function get(path: string) {
  const ctx = { waitUntil: () => {}, passThroughOnException: () => {} };
  const response = await worker.fetch(
    new Request(`https://demo-dl.5stack.gg/${path}`, {
      headers: { Origin: ORIGIN },
    }),
    env,
    ctx as any,
  );
  const init = upstream.mock.calls[0].arguments[1] as {
    cf: { cacheTtlByStatus: Record<string, number> };
  };
  return { response, edgeTtl: init.cf.cacheTtlByStatus["200-299"] };
}

describe("backblaze-proxy map assets", () => {
  it("lets latest.json go stale within a minute, at the edge and in the browser", async () => {
    const { response, edgeTtl } = await get("maps/latest.json");

    assert.equal(response.status, 200);
    assert.equal(response.headers.get("Cache-Control"), "public, max-age=60");
    assert.equal(edgeTtl, 60);
    assert.match(
      String(upstream.mock.calls[0].arguments[0]),
      /\/maps\/latest\.json$/,
    );
  });

  for (const path of [
    "maps/25537370/manifest.json",
    "maps/25537370/de_mirage.view.bin.gz",
  ]) {
    it(`keeps ${path} immutable`, async () => {
      const { response, edgeTtl } = await get(path);

      assert.equal(
        response.headers.get("Cache-Control"),
        "public, max-age=2592000, immutable",
      );
      assert.equal(edgeTtl, 2592000);
    });
  }

  for (const path of [
    "maps/latest.json",
    "maps/25537370/manifest.json",
    "maps/25537370/de_mirage.tri.gz",
  ]) {
    it(`answers ${path} with the same CORS headers`, async () => {
      const { response } = await get(path);

      assert.equal(response.headers.get("Access-Control-Allow-Origin"), ORIGIN);
      assert.equal(
        response.headers.get("Access-Control-Allow-Credentials"),
        "true",
      );
      assert.match(
        response.headers.get("Access-Control-Expose-Headers") ?? "",
        /Content-Length/,
      );
      assert.equal(response.headers.get("Vary"), "Origin");
    });
  }
});

describe("backblaze-proxy upstream failures", () => {
  it("answers with B2's 403 once every retry is spent", async () => {
    upstream = mock.fn(
      async () =>
        new Response("<Error><Code>AccessDenied</Code></Error>", {
          status: 403,
        }),
    );
    globalThis.fetch = upstream as unknown as typeof fetch;

    const { response } = await get("clips/missing.mp4");

    assert.equal(upstream.mock.callCount(), 3);
    assert.equal(response.status, 403);
    assert.match(await response.text(), /AccessDenied/);
  });
});
