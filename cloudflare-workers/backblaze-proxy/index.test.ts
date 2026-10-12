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

describe("backblaze-proxy health", () => {
  async function health(body: string, overrides: Partial<typeof env> = {}) {
    upstream = mock.fn(async () => new Response(body, { status: 403 }));
    globalThis.fetch = upstream as unknown as typeof fetch;
    const ctx = { waitUntil: () => {}, passThroughOnException: () => {} };
    const response = await worker.fetch(
      new Request("https://cf.5stack.gg/demo/_health"),
      { ...env, ...overrides },
      ctx as any,
    );
    return { response, json: await response.json() };
  }

  it("reports the bucket as reachable when Backblaze accepts the keys", async () => {
    const { response, json } = await health(
      "<Error><Code>AccessDenied</Code></Error>",
    );

    assert.equal(response.headers.get("Access-Control-Allow-Origin"), "*");
    assert.equal(response.headers.get("Cache-Control"), "no-store");
    assert.deepEqual(json, {
      ok: true,
      worker: "5stack-backblaze-proxy",
      version: "1",
      bucket: "ok",
      code: "AccessDenied",
    });
    assert.match(
      String(upstream.mock.calls[0].arguments[0]),
      /^https:\/\/5stack\.s3\.example\.test\/\.5stack-health$/,
    );
  });

  it("reports keys Backblaze rejects", async () => {
    const { json } = await health(
      "<Error><Code>InvalidAccessKeyId</Code></Error>",
    );

    assert.equal(json.ok, false);
    assert.equal(json.bucket, "rejected");
    assert.equal(json.code, "InvalidAccessKeyId");
  });

  it("reports a worker deployed without its bucket keys", async () => {
    const { json } = await health("", { S3_SECRET: "" });

    assert.equal(json.bucket, "misconfigured");
    assert.equal(upstream.mock.callCount(), 0);
  });
});


describe("backblaze-proxy clip views", () => {
  const API_URL = "https://api.5stack.gg";
  const CLIP = "clips/76561198000000001/0b7c.mp4";
  const UA = "Mozilla/5.0 (Macintosh) Chrome/141";

  let waited: Promise<unknown>[];
  let cacheKeys: string[];

  function ctx() {
    return {
      waitUntil: (promise: Promise<unknown>) => waited.push(promise),
      passThroughOnException: () => {},
    } as any;
  }

  function viewCalls() {
    return upstream.mock.calls.filter((call) =>
      String(call.arguments[0]).startsWith(`${API_URL}/clip-views/play`),
    );
  }

  async function send(
    method: string,
    path: string,
    headers: Record<string, string> = {},
  ) {
    const response = await worker.fetch(
      new Request(`https://cf.5stack.gg/${path}`, {
        method,
        headers: { "user-agent": UA, "cf-connecting-ip": "203.0.113.9", ...headers },
      }),
      { ...env, API_URL },
      ctx(),
    );
    await Promise.all(waited);
    return response;
  }

  beforeEach(() => {
    waited = [];
    cacheKeys = [];
    (globalThis as any).caches = {
      default: {
        match: async (request: Request) => {
          cacheKeys.push(request.url);
          return undefined;
        },
        put: async (request: Request) => {
          cacheKeys.push(request.url);
        },
      },
    };
  });

  it("counts a played clip", async () => {
    await send("GET", `${CLIP}?name=ace.mp4&v=1`);

    assert.equal(viewCalls().length, 1);
  });

  it("does not count a request marked noview", async () => {
    await send("GET", `${CLIP}?name=ace.mp4&v=1&noview=1`);

    assert.equal(viewCalls().length, 0);
  });

  it("keeps one edge copy of a clip whether or not the request is marked noview", async () => {
    await send("GET", `${CLIP}?name=ace.mp4&v=1&noview=1`);
    const marked = [...cacheKeys];
    cacheKeys = [];
    await send("GET", `${CLIP}?name=ace.mp4&v=1`);

    assert.deepEqual(marked, cacheKeys);
    assert.ok(cacheKeys.every((key) => !key.includes("noview")));
  });

  it("drops noview from the cache key without re-encoding the rest", async () => {
    await send("GET", `${CLIP}?name=ace%20on%20B.mp4&noview=1&v=1`);

    assert.ok(
      cacheKeys.every(
        (key) =>
          key ===
          `https://cf.5stack.gg/${CLIP}?name=ace%20on%20B.mp4&v=1#origin=`,
      ),
    );
  });

  it("still keeps a named download apart from the inline copy", async () => {
    await send("GET", `${CLIP}?name=ace.mp4&v=1&dl=1`);
    const download = [...cacheKeys];
    cacheKeys = [];
    await send("GET", `${CLIP}?name=ace.mp4&v=1`);

    assert.notDeepEqual(download, cacheKeys);
  });

  it("counts a POST to a clip as the player saying it was watched", async () => {
    const response = await send("POST", `${CLIP}?name=ace.mp4&v=1`, {
      Origin: ORIGIN,
    });

    assert.equal(response.status, 204);
    assert.equal(response.headers.get("Access-Control-Allow-Origin"), ORIGIN);
    const [call] = viewCalls();
    assert.ok(call);
    const init = call.arguments[1] as RequestInit;
    assert.equal(
      (init.headers as Record<string, string>).authorization,
      "Bearer secret",
    );
    const body = JSON.parse(String(init.body));
    assert.equal(body.file, CLIP);
    assert.match(body.clientKey, /^[a-f0-9]{32}$/);
  });

  it("gives a POST and a GET from the same viewer one dedupe key", async () => {
    await send("POST", CLIP);
    await send("GET", CLIP);

    const keys = viewCalls().map(
      (call) => JSON.parse(String((call.arguments[1] as RequestInit).body)).clientKey,
    );
    assert.equal(keys.length, 2);
    assert.equal(keys[0], keys[1]);
  });

  it("never fetches the clip itself for a POST", async () => {
    await send("POST", CLIP);

    assert.equal(upstream.mock.callCount(), viewCalls().length);
    assert.deepEqual(cacheKeys, []);
  });

  it("does not count a POST from a bot", async () => {
    const response = await send("POST", CLIP, { "user-agent": "Discordbot/2.0" });

    assert.equal(response.status, 204);
    assert.equal(viewCalls().length, 0);
  });

  it("refuses a POST to anything that isn't a clip", async () => {
    const response = await send("POST", "maps/latest.json");

    assert.equal(response.status, 405);
    assert.equal(viewCalls().length, 0);
  });
});
