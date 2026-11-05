import { afterEach, beforeEach, describe, it, mock } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import worker from "./index.ts";

const env = {
  S3_ACCESS_KEY: "key",
  S3_SECRET: "secret",
  BUCKET_NAME: "5stack",
  S3_ENDPOINT: "s3.example.test",
};
const ORIGIN = "https://5stack.gg";

// The query string the api's computed fields put on a clip link
// (file_url_signature.sql), worked out the way the api does it.
function signed(key: string, exp = Math.floor(Date.now() / 1000) + 21600) {
  const signingKey = createHmac("sha256", env.S3_SECRET)
    .update("5stack-file-url-v1")
    .digest();
  const sig = createHmac("sha256", signingKey)
    .update(`${key}\n${exp}`)
    .digest("base64url");
  return `exp=${exp}&sig=${sig}`;
}

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

    const { response } = await get(
      `clips/missing.mp4?${signed("clips/missing.mp4")}`,
    );

    assert.equal(upstream.mock.callCount(), 3);
    assert.equal(response.status, 403);
    assert.match(await response.text(), /AccessDenied/);
  });
});

describe("backblaze-proxy browser cache", () => {
  for (const [label, path, status, cacheControl] of [
    ["a landing video B2 has", "landing/intro.mp4", 200, "public, max-age=2592000, immutable"],
    ["the map pointer B2 has", "maps/latest.json", 200, "public, max-age=60"],
    ["a landing video B2 does not have yet", "landing/does-not-exist-123.mp4", 404, "no-store"],
    ["a map pointer B2 does not have", "maps/latest.json", 404, "no-store"],
    ["a demo B2 refuses on every retry", "demo/0b7c.dem", 403, "no-store"],
    ["a demo while B2 is down", "demo/0b7c.dem", 503, "no-store"],
  ] as const) {
    it(`answers ${label} with ${cacheControl}`, async () => {
      upstream = mock.fn(async () => new Response("body", { status }));
      globalThis.fetch = upstream as unknown as typeof fetch;

      const { response } = await get(path);

      assert.equal(response.status, status);
      assert.equal(response.headers.get("Cache-Control"), cacheControl);
      assert.equal(response.headers.get("Access-Control-Allow-Origin"), ORIGIN);
    });
  }

  it("keeps the immutable header on a range served from the edge copy", async () => {
    (globalThis as any).caches = {
      default: {
        match: async () =>
          new Response("ace", {
            status: 206,
            headers: {
              "Content-Range": "bytes 0-2/100",
              "Cache-Control": "public, max-age=2592000, immutable",
            },
          }),
        put: async () => {},
      },
    };
    const ctx = { waitUntil: () => {}, passThroughOnException: () => {} };

    const response = await worker.fetch(
      new Request("https://demo-dl.5stack.gg/landing/intro.mp4", {
        headers: { Origin: ORIGIN, Range: "bytes=0-2" },
      }),
      env,
      ctx as any,
    );

    assert.equal(response.status, 206);
    assert.equal(
      response.headers.get("Cache-Control"),
      "public, max-age=2592000, immutable",
    );
  });

  it("answers a worker deployed without its bucket with no-store", async () => {
    const ctx = { waitUntil: () => {}, passThroughOnException: () => {} };

    const response = await worker.fetch(
      new Request("https://demo-dl.5stack.gg/landing/intro.mp4"),
      { ...env, BUCKET_NAME: "" },
      ctx as any,
    );

    assert.equal(response.status, 500);
    assert.equal(response.headers.get("Cache-Control"), "no-store");
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
      version: "2",
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
  const SIGNED = signed(CLIP);
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
    await send("GET", `${CLIP}?name=ace.mp4&v=1&${SIGNED}`);

    assert.equal(viewCalls().length, 1);
  });

  it("does not count a request marked noview", async () => {
    await send("GET", `${CLIP}?name=ace.mp4&v=1&noview=1&${SIGNED}`);

    assert.equal(viewCalls().length, 0);
  });

  it("keeps one edge copy of a clip whether or not the request is marked noview", async () => {
    await send("GET", `${CLIP}?name=ace.mp4&v=1&noview=1&${SIGNED}`);
    const marked = [...cacheKeys];
    cacheKeys = [];
    await send("GET", `${CLIP}?name=ace.mp4&v=1&${SIGNED}`);

    assert.deepEqual(marked, cacheKeys);
    assert.ok(cacheKeys.every((key) => !key.includes("noview")));
  });

  it("drops noview from the cache key without re-encoding the rest", async () => {
    await send("GET", `${CLIP}?name=ace%20on%20B.mp4&noview=1&v=1&${SIGNED}`);

    assert.ok(
      cacheKeys.every(
        (key) =>
          key ===
          `https://cf.5stack.gg/${CLIP}?name=ace%20on%20B.mp4&v=1#origin=`,
      ),
    );
  });

  it("still keeps a named download apart from the inline copy", async () => {
    await send("GET", `${CLIP}?name=ace.mp4&v=1&dl=1&${SIGNED}`);
    const download = [...cacheKeys];
    cacheKeys = [];
    await send("GET", `${CLIP}?name=ace.mp4&v=1&${SIGNED}`);

    assert.notDeepEqual(download, cacheKeys);
  });

  it("refuses a POST to a clip without counting or fetching it", async () => {
    const response = await send("POST", `${CLIP}?name=ace.mp4&v=1`, {
      Origin: ORIGIN,
    });

    assert.equal(response.status, 405);
    assert.equal(viewCalls().length, 0);
    assert.equal(upstream.mock.callCount(), 0);
    assert.deepEqual(cacheKeys, []);
  });

  it("does not offer POST to a browser", async () => {
    const response = await send("OPTIONS", CLIP, { Origin: ORIGIN });

    assert.doesNotMatch(
      response.headers.get("Access-Control-Allow-Methods") ?? "",
      /POST/,
    );
  });
});

describe("backblaze-proxy signed clip links", () => {
  const CLIP = "clips/76561198000000001/0b7c.mp4";
  const LINEUP_STILL =
    "clips/utility/ffe58c95-4581-4320-a14e-f2efb95ccebe/aim.jpg";
  const EVENT_MEDIA =
    "events/media/4f1e2d3c-5b6a-4798-8a7b-6c5d4e3f2a1b/0123456789abcdef01234567.jpg";

  let cacheKeys: string[];
  let cached: Response | undefined;
  let requireSigned: boolean;

  beforeEach(() => {
    cacheKeys = [];
    cached = undefined;
    requireSigned = true;
    (globalThis as any).caches = {
      default: {
        match: async (request: Request) => {
          cacheKeys.push(request.url);
          return cached;
        },
        put: async (request: Request) => {
          cacheKeys.push(request.url);
        },
      },
    };
  });

  async function send(
    path: string,
    init: { method?: string; headers?: Record<string, string> } = {},
  ) {
    const ctx = { waitUntil: () => {}, passThroughOnException: () => {} };
    return worker.fetch(
      new Request(`https://cf.5stack.gg/${path}`, {
        method: init.method ?? "GET",
        headers: { Origin: ORIGIN, ...init.headers },
      }),
      requireSigned ? { ...env, REQUIRE_SIGNED_CLIPS: "1" } : env,
      ctx as any,
    );
  }

  async function refused(path: string, method = "GET") {
    const response = await send(path, { method });

    assert.equal(response.status, 403);
    assert.equal(response.headers.get("Cache-Control"), "no-store");
    assert.equal(response.headers.get("Access-Control-Allow-Origin"), ORIGIN);
    assert.equal(upstream.mock.callCount(), 0);
    assert.deepEqual(cacheKeys, []);
  }

  const now = () => Math.floor(Date.now() / 1000);

  it("refuses a clip without a signature, before the cache or B2", async () => {
    await refused(`${CLIP}?name=ace.mp4&v=1`);
  });

  it("refuses the HEAD a player sends first, too", async () => {
    await refused(CLIP, "HEAD");
  });

  it("refuses a utility lineup file without a signature", async () => {
    await refused(`${LINEUP_STILL}?v=1`);
  });

  it("refuses a clip named by ?file= on another route", async () => {
    await refused(`demo?file=${encodeURIComponent(CLIP)}`);
  });

  it("refuses an expired link", async () => {
    await refused(`${CLIP}?${signed(CLIP, now() - 1)}`);
  });

  it("refuses a link signed for another file", async () => {
    await refused(`${CLIP}?${signed(LINEUP_STILL)}`);
  });

  it("refuses a link whose expiry was pushed out", async () => {
    const sig = new URLSearchParams(signed(CLIP)).get("sig");
    await refused(`${CLIP}?exp=${now() + 365 * 86400}&sig=${sig}`);
  });

  it("refuses a forged signature", async () => {
    await refused(`${CLIP}?exp=${now() + 600}&sig=${"A".repeat(43)}`);
  });

  it("refuses a link signed with another bucket's secret", async () => {
    const exp = now() + 600;
    const otherKey = createHmac("sha256", "another-secret")
      .update("5stack-file-url-v1")
      .digest();
    const sig = createHmac("sha256", otherKey)
      .update(`${CLIP}\n${exp}`)
      .digest("base64url");
    await refused(`${CLIP}?exp=${exp}&sig=${sig}`);
  });

  for (const path of [
    `maps/%252e%252e/${CLIP}`,
    `maps//${CLIP}`,
    `maps/%5C..%5C${CLIP}`,
    `demo?file=${encodeURIComponent(`/${CLIP}`)}`,
  ]) {
    it(`refuses ${path}, which B2 could resolve into clips/`, async () => {
      await refused(path);
    });
  }

  // The api serves event media itself, checking on every request who may see
  // the event, and never links it through the worker.
  it("refuses event media without a signature, before the cache or B2", async () => {
    await refused(EVENT_MEDIA);
  });

  it("refuses event media to a HEAD without a signature", async () => {
    await refused(EVENT_MEDIA, "HEAD");
  });

  it("refuses event media named by ?file= on another route", async () => {
    await refused(`news?file=${encodeURIComponent(EVENT_MEDIA)}`);
  });

  it("does not hand a cached copy of event media to a request without a signature", async () => {
    cached = new Response("cached banner", { status: 200 });

    const response = await send(EVENT_MEDIA);

    assert.equal(response.status, 403);
    assert.deepEqual(cacheKeys, []);
  });

  it("serves event media on a signed link", async () => {
    const response = await send(`${EVENT_MEDIA}?${signed(EVENT_MEDIA)}`);

    assert.equal(response.status, 200);
    assert.equal(
      String(upstream.mock.calls[0].arguments[0]),
      `https://5stack.s3.example.test/${EVENT_MEDIA}`,
    );
  });

  it("does not hand a cached copy of a clip to a request without a signature", async () => {
    cached = new Response("cached clip", { status: 200 });

    const response = await send(CLIP);

    assert.equal(response.status, 403);
    assert.deepEqual(cacheKeys, []);
  });

  it("serves a clip on a link the api signed, by the key B2 holds it under", async () => {
    const response = await send(`${CLIP}?name=ace.mp4&v=1&${signed(CLIP)}`);

    assert.equal(response.status, 200);
    assert.equal(response.headers.get("Content-Type"), "video/mp4");
    assert.equal(
      response.headers.get("Content-Disposition"),
      'inline; filename="ace.mp4"',
    );
    assert.equal(
      String(upstream.mock.calls[0].arguments[0]),
      `https://5stack.s3.example.test/${CLIP}`,
    );
  });

  it("serves a signed link as a named download when asked", async () => {
    const response = await send(`${CLIP}?${signed(CLIP)}&dl=1&name=ace.mp4`);

    assert.equal(response.status, 200);
    assert.equal(
      response.headers.get("Content-Disposition"),
      'attachment; filename="ace.mp4"',
    );
  });

  it("answers a range on a signed link out of the cached copy", async () => {
    cached = new Response("ace", {
      status: 206,
      headers: { "Content-Range": "bytes 0-2/100" },
    });

    const response = await send(`${CLIP}?v=1&${signed(CLIP)}`, {
      headers: { Range: "bytes=0-2" },
    });

    assert.equal(response.status, 206);
    assert.equal(upstream.mock.callCount(), 0);
  });

  it("keeps one edge copy of a file for every link signed for it", async () => {
    await send(`${CLIP}?name=ace.mp4&v=1&${signed(CLIP, now() + 21600)}`);
    const first = [...cacheKeys];
    cacheKeys = [];
    await send(`${CLIP}?name=ace.mp4&v=1&${signed(CLIP, now() + 43200)}`);

    assert.deepEqual(first, cacheKeys);
    assert.ok(
      cacheKeys.every(
        (key) =>
          key ===
          `https://cf.5stack.gg/${CLIP}?name=ace.mp4&v=1#origin=${ORIGIN}`,
      ),
    );
  });

  for (const path of [
    "maps/25537370/manifest.json",
    "news/9a3c.webp",
    "demo/0b7c.dem",
  ]) {
    it(`serves ${path} without a signature`, async () => {
      const response = await send(path);

      assert.equal(response.status, 200);
      assert.equal(upstream.mock.callCount(), 1);
    });
  }

  // Deployed this way until ./backblaze-proxy.sh has seen the panel's api sign
  // with this S3_SECRET: enforcing in front of an api that does not would
  // refuse every clip.
  describe("without REQUIRE_SIGNED_CLIPS", () => {
    beforeEach(() => {
      requireSigned = false;
    });

    for (const [label, path] of [
      ["a clip without a signature", `${CLIP}?name=ace.mp4&v=1`],
      ["a lineup file without a signature", `${LINEUP_STILL}?v=1`],
      ["an expired link", `${CLIP}?${signed(CLIP, now() - 1)}`],
      ["a forged link", `${CLIP}?exp=${now() + 600}&sig=${"A".repeat(43)}`],
    ]) {
      it(`serves ${label}, as before signed links`, async () => {
        const response = await send(path);

        assert.equal(response.status, 200);
        assert.equal(upstream.mock.callCount(), 1);
      });
    }

    for (const [label, path] of [
      ["event media without a signature", EVENT_MEDIA],
      ["event media with a forged signature", `${EVENT_MEDIA}?exp=${now() + 600}&sig=${"A".repeat(43)}`],
      ["a key that B2 could resolve into events/", `news/%252e%252e/${EVENT_MEDIA}`],
      ["a key with an empty segment", `news//${EVENT_MEDIA}`],
    ]) {
      it(`still refuses ${label}`, async () => {
        await refused(path);
      });
    }

    it("keeps one edge copy of a clip for its signed and unsigned links", async () => {
      await send(`${CLIP}?name=ace.mp4&v=1`);
      const unsigned = [...cacheKeys];
      cacheKeys = [];
      await send(`${CLIP}?name=ace.mp4&v=1&${signed(CLIP)}`);

      assert.deepEqual(unsigned, cacheKeys);
    });
  });
});

describe("backblaze-proxy content types", () => {
  // What B2 holds is the type the object was stored with, which an upload
  // once took from the uploader's own label.
  function stored(contentType: string, body = "<script>alert(1)</script>") {
    upstream = mock.fn(
      async () =>
        new Response(body, {
          status: 200,
          headers: { "Content-Type": contentType },
        }),
    );
    globalThis.fetch = upstream as unknown as typeof fetch;
  }

  for (const [path, type] of [
    ["news/images/0123abcd.png", "image/png"],
    ["news/images/0123abcd.JPG", "image/jpeg"],
    ["news/images/0123abcd.webp", "image/webp"],
    ["news/images/0123abcd.gif", "image/gif"],
    ["news/images/0123abcd.mp4", "video/mp4"],
    ["news/images/0123abcd.mp3", "audio/mpeg"],
    ["maps/latest.json", "application/json"],
  ] as const) {
    it(`serves ${path} as ${type}, whatever it was stored as`, async () => {
      stored("text/html");

      const { response } = await get(path);

      assert.equal(response.headers.get("Content-Type"), type);
      assert.equal(response.headers.get("X-Content-Type-Options"), "nosniff");
      assert.match(
        response.headers.get("Content-Disposition") ?? "",
        /^inline/,
      );
    });
  }

  for (const path of [
    "news/images/0123abcd.html",
    "news/images/0123abcd.svg",
    "news/images/0123abcd",
    "demo/0b7c.dem",
    "maps/25537370/de_mirage.tri.gz",
  ]) {
    it(`makes ${path} a download`, async () => {
      stored("text/html");

      const { response } = await get(path);

      assert.equal(
        response.headers.get("Content-Type"),
        "application/octet-stream",
      );
      assert.equal(response.headers.get("X-Content-Type-Options"), "nosniff");
      assert.match(
        response.headers.get("Content-Disposition") ?? "",
        /^attachment/,
      );
    });
  }

  // Without REQUIRE_SIGNED_CLIPS too: B2 resolves dot and empty segments and
  // escapes, so a key that only starts with clips/ could name any object.
  async function send(path: string) {
    const ctx = { waitUntil: () => {}, passThroughOnException: () => {} };
    return worker.fetch(
      new Request(`https://demo-dl.5stack.gg/${path}`, {
        headers: { Origin: ORIGIN },
      }),
      env,
      ctx as any,
    );
  }

  for (const path of [
    `demo?file=${encodeURIComponent("clips/../events/x.html")}`,
    "clips//x.html",
    "clips/%252e%252e/events/x.html",
    "clips/..%2Fevents/x.html",
    "clips%2F..%2Fevents%2Fx.html",
    "clips/%5C..%5Cevents/x.html",
    `news?file=${encodeURIComponent("clips/./x.html")}`,
  ]) {
    it(`refuses ${path} before the cache or B2`, async () => {
      stored("text/html");
      const cacheKeys: string[] = [];
      (globalThis as any).caches = {
        default: {
          match: async (request: Request) => {
            cacheKeys.push(request.url);
          },
          put: async () => {},
        },
      };

      const response = await send(path);

      assert.equal(response.status, 403);
      assert.equal(response.headers.get("Cache-Control"), "no-store");
      assert.equal(upstream.mock.callCount(), 0);
      assert.deepEqual(cacheKeys, []);
    });
  }

  // A Request resolves this itself, to event media without a signature.
  it("refuses what clips/%2e%2e/events/x.html resolves to", async () => {
    stored("text/html");

    const response = await send("clips/%2e%2e/events/x.html");

    assert.equal(response.status, 403);
    assert.equal(upstream.mock.callCount(), 0);
  });

  for (const [path, type] of [
    ["clips/76561198000000001/0b7c.mp4", "video/mp4"],
    ["clips/76561198000000001/0b7c.jpg", "image/jpeg"],
    ["events/media/4f1e2d3c-5b6a-4798-8a7b-6c5d4e3f2a1b/0123abcd.webp", "image/webp"],
  ] as const) {
    it(`still serves ${path} as ${type}`, async () => {
      stored("text/html");

      const response = await send(`${path}?${signed(path)}`);

      assert.equal(response.status, 200);
      assert.equal(response.headers.get("Content-Type"), type);
      assert.equal(response.headers.get("X-Content-Type-Options"), "nosniff");
    });
  }

  it("makes a file under clips/ outside the list a download too", async () => {
    stored("text/html");

    const response = await send("clips/76561198000000001/0b7c.html");

    assert.equal(
      response.headers.get("Content-Type"),
      "application/octet-stream",
    );
    assert.match(
      response.headers.get("Content-Disposition") ?? "",
      /^attachment/,
    );
  });

  it("pins the type on a copy the edge cached before", async () => {
    (globalThis as any).caches = {
      default: {
        match: async () =>
          new Response("<script>alert(1)</script>", {
            status: 200,
            headers: {
              "Content-Type": "text/html",
              "Content-Disposition": 'inline; filename="0123abcd.html"',
            },
          }),
        put: async () => {},
      },
    };
    const ctx = { waitUntil: () => {}, passThroughOnException: () => {} };

    const image = await worker.fetch(
      new Request("https://demo-dl.5stack.gg/news/images/0123abcd.png"),
      env,
      ctx as any,
    );
    const page = await worker.fetch(
      new Request("https://demo-dl.5stack.gg/news/images/0123abcd.html"),
      env,
      ctx as any,
    );

    assert.equal(image.headers.get("Content-Type"), "image/png");
    assert.equal(image.headers.get("X-Content-Type-Options"), "nosniff");
    assert.equal(page.headers.get("Content-Type"), "application/octet-stream");
    assert.match(page.headers.get("Content-Disposition") ?? "", /^attachment/);
  });
});
