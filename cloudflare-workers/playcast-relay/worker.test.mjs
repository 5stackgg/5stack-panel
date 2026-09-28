import { beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import worker from "./worker.js";

// The worker runs as a route on the relay domain, so the panel it fronts is
// the same host: its fetches to it go to the origin.
const RELAY = "https://tv.example.com";

let originRequests;
let originRoutes;
let cache;

function respond(status, body = "", headers = {}) {
  return new Response(status === 204 ? null : body, { status, headers });
}

beforeEach(() => {
  originRequests = [];
  originRoutes = new Map();
  cache = new Map();

  globalThis.fetch = async (input) => {
    const target = typeof input === "string" ? input : input.url;
    originRequests.push(input);
    const route = originRoutes.get(target);
    return route ? route(input) : respond(404);
  };

  globalThis.caches = {
    default: {
      async match(request) {
        const hit = cache.get(request.url);
        return hit ? hit.clone() : undefined;
      },
      async put(request, response) {
        cache.set(request.url, response.clone());
      },
    },
  };
});

const originUrls = () =>
  originRequests.map((input) =>
    typeof input === "string" ? input : input.url,
  );

async function call(request) {
  const pending = [];
  const response = await worker.fetch(
    request,
    {},
    { waitUntil: (promise) => pending.push(promise) },
  );
  await Promise.all(pending);
  return response;
}

const get = (path) => call(new Request(`${RELAY}${path}`));

function broadcast(token, fragments = {}) {
  originRoutes.set(`${RELAY}/match-1/sync`, () =>
    respond(200, JSON.stringify({ fragment: 42 }), {
      "X-Broadcast-Token": token,
    }),
  );
  for (const [path, body] of Object.entries(fragments)) {
    originRoutes.set(`${RELAY}/match-1/${token}/${path}`, () =>
      respond(200, body),
    );
  }
}

describe("playcast relay worker", () => {
  it("tells the panel it is live, from any page", async () => {
    const response = await get("/health");

    assert.equal(response.status, 200);
    assert.equal(response.headers.get("Access-Control-Allow-Origin"), "*");
    assert.deepEqual(await response.json(), {
      ok: true,
      worker: "5stack-playcast-relay",
      version: "2",
    });
    assert.equal(originRequests.length, 0);
  });

  it("passes a game server's post straight through to the panel", async () => {
    originRoutes.set(
      `${RELAY}/match-1/s1t1/45/full?tick=100`,
      async (request) =>
        respond(
          request.method === "POST" &&
            request.headers.get("x-origin-auth") === "match-1:secret" &&
            (await request.text()) === "fragment-bytes"
            ? 200
            : 400,
        ),
    );

    const response = await call(
      new Request(`${RELAY}/match-1/s1t1/45/full?tick=100`, {
        method: "POST",
        headers: { "x-origin-auth": "match-1:secret" },
        body: "fragment-bytes",
      }),
    );

    assert.equal(response.status, 200);
    assert.equal(cache.size, 0);
  });

  it("serves sync from the panel and keeps it for a few seconds", async () => {
    originRoutes.set(`${RELAY}/match-1/sync?fragment=0`, () =>
      respond(200, JSON.stringify({ fragment: 42 })),
    );

    const first = await get("/match-1/sync?fragment=0");
    assert.equal(first.status, 200);
    assert.equal(first.headers.get("Cache-Control"), "public, max-age=3");
    assert.deepEqual(originUrls(), [`${RELAY}/match-1/sync?fragment=0`]);

    await get("/match-1/sync?fragment=0");
    assert.equal(originRequests.length, 1);
  });

  it("fetches a fragment once and serves every other viewer from the edge", async () => {
    broadcast("s1t1", { "45/full": "full-45" });

    assert.equal(await (await get("/match-1/45/full")).text(), "full-45");
    assert.equal(await (await get("/match-1/45/full")).text(), "full-45");
    assert.equal(await (await get("/match-1/s1t1/45/full")).text(), "full-45");

    assert.equal(
      originUrls().filter((url) => url.endsWith("/45/full")).length,
      1,
    );
  });

  it("lets only the token-scoped url be cached past the edge", async () => {
    broadcast("s1t1", { "45/full": "full-45" });

    const unscoped = await get("/match-1/45/full");
    assert.equal(unscoped.headers.get("Cache-Control"), "no-store");

    const scoped = await get("/match-1/s1t1/45/full");
    assert.match(scoped.headers.get("Cache-Control"), /immutable/);

    const unscopedHit = await get("/match-1/45/full");
    assert.equal(unscopedHit.headers.get("Cache-Control"), "no-store");
  });

  it("never passes on the panel's Content-Encoding", async () => {
    broadcast("s1t1");
    originRoutes.set(`${RELAY}/match-1/s1t1/45/full`, () =>
      respond(200, "full-45", { "Content-Encoding": "gzip" }),
    );

    const response = await get("/match-1/s1t1/45/full");

    assert.equal(response.headers.get("Content-Encoding"), null);
    assert.equal(await response.text(), "full-45");
  });

  it("answers HEAD without a body", async () => {
    broadcast("s1t1", { "45/full": "full-45" });

    const response = await call(
      new Request(`${RELAY}/match-1/s1t1/45/full`, { method: "HEAD" }),
    );

    assert.equal(response.status, 200);
    assert.equal(await response.text(), "");
  });

  it("never serves a new map the fragment an earlier map had at that number", async () => {
    broadcast("s1t1", { "3/full": "old-map" });
    assert.equal(await (await get("/match-1/3/full")).text(), "old-map");

    cache.delete(`${RELAY}/match-1/sync`);
    broadcast("s1t2", { "3/full": "new-map" });

    assert.equal(await (await get("/match-1/3/full")).text(), "new-map");
  });

  it("uses the token a client already has in its url", async () => {
    broadcast("s1t1", { "45/delta": "delta-45" });

    const response = await get("/match-1/s1t1/45/delta");

    assert.equal(await response.text(), "delta-45");
    assert.ok(!originUrls().some((url) => url.endsWith("/sync")));
  });

  it("does not cache a fragment the panel does not have yet", async () => {
    broadcast("s1t1");

    const missing = await get("/match-1/46/full");
    assert.equal(missing.status, 404);
    assert.equal(missing.headers.get("Cache-Control"), "no-store");

    originRoutes.set(`${RELAY}/match-1/s1t1/46/full`, () =>
      respond(200, "full-46"),
    );
    assert.equal(await (await get("/match-1/46/full")).text(), "full-46");
  });

  it("passes start through without caching it", async () => {
    originRoutes.set(`${RELAY}/match-1/42/start`, () =>
      respond(200, "start-42"),
    );

    const response = await get("/match-1/42/start");

    assert.equal(await response.text(), "start-42");
    assert.equal(response.headers.get("Cache-Control"), "no-store");
    assert.equal(cache.size, 0);
  });

  it("answers fragment requests from the panel when no broadcast is running", async () => {
    const response = await get("/match-1/45/full");

    assert.equal(response.status, 404);
    assert.ok(originUrls().includes(`${RELAY}/match-1/45/full`));
  });
});
