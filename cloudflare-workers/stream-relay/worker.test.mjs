import { beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import worker from "./worker.js";

const HLS = "https://hls.example.gg";
const WEB = "https://example.gg";
const ENV = { WEB_ORIGIN: WEB };
const VIEWER = "session=viewer";
const PLAYER = "session=player";

let now;
let origin;
let cache;

class Origin {
  constructor() {
    this.requests = [];
    this.sequence = 0;
    this.segments = new Map();
    this.blocked = new Set([PLAYER]);
    this.loginRequired = true;
  }

  live(seconds) {
    for (let i = 0; i < seconds; i++) {
      this.segments.set(
        `seg${this.sequence}.mp4`,
        `segment-${this.sequence}-`.padEnd(64, "x"),
      );
      this.sequence++;
    }
    for (const name of [...this.segments.keys()]) {
      if (Number(name.slice(3, -4)) < this.sequence - 7) {
        this.segments.delete(name);
      }
    }
  }

  playlist() {
    const names = [...this.segments.keys()];
    const first = Number(names[0].slice(3, -4));
    return [
      "#EXTM3U",
      "#EXT-X-VERSION:9",
      "#EXT-X-TARGETDURATION:1",
      `#EXT-X-MEDIA-SEQUENCE:${first}`,
      '#EXT-X-MAP:URI="init.mp4"',
      ...names.flatMap((name) => ["#EXTINF:1.00000,", name]),
      "",
    ].join("\n");
  }

  answer(request) {
    this.requests.push(request);
    const url = new URL(request.url);
    const cookie = request.headers.get("Cookie") ?? "";
    const headers = new Headers({
      "Access-Control-Allow-Credentials": "true",
      Vary: "Origin",
      "Set-Cookie": "seen=1",
    });
    const from = request.headers.get("Origin");
    if (from === WEB) {
      headers.set("Access-Control-Allow-Origin", WEB);
    } else {
      headers.set("Access-Control-Allow-Origin", "*");
    }
    if (this.loginRequired && (!cookie || this.blocked.has(cookie))) {
      return new Response(null, { status: 401, headers });
    }
    const [, stream, file] = url.pathname.split("/");
    if (stream !== "match-1") {
      return new Response("no stream", { status: 404, headers });
    }
    if (file === "index.m3u8") {
      headers.set("Content-Type", "application/vnd.apple.mpegurl");
      return new Response(this.playlist(), { status: 200, headers });
    }
    const body =
      file === "init.mp4" ? "init-segment" : this.segments.get(file);
    if (body === undefined) {
      return new Response("not found", { status: 404, headers });
    }
    headers.set("Content-Type", "video/mp4");
    const range = request.headers.get("Range");
    if (range) {
      const [start, end] = range.slice(6).split("-").map(Number);
      headers.set("Content-Range", `bytes ${start}-${end}/${body.length}`);
      return new Response(body.slice(start, end + 1), { status: 206, headers });
    }
    return new Response(body, { status: 200, headers });
  }

  hits(file) {
    return this.requests.filter((r) => new URL(r.url).pathname.endsWith(file))
      .length;
  }
}

beforeEach(() => {
  now = 0;
  origin = new Origin();
  origin.live(7);
  cache = new Map();
  globalThis.fetch = async (input, init) => {
    assert.equal(init?.cache, "no-store");
    return origin.answer(input instanceof Request ? input : new Request(input));
  };
  globalThis.caches = {
    default: {
      async match(request) {
        const hit = cache.get(request.url);
        if (!hit || hit.until <= now) {
          return undefined;
        }
        return hit.response.clone();
      },
      async put(request, response) {
        const age = /max-age=(\d+)/.exec(
          response.headers.get("Cache-Control") ?? "",
        );
        if (response.headers.has("Set-Cookie")) {
          throw new Error("the Cache API was given a Set-Cookie response");
        }
        cache.set(request.url, {
          response: response.clone(),
          until: now + Number(age?.[1] ?? 0) * 1000,
        });
      },
    },
  };
});

async function get(path, { cookie = VIEWER, from = WEB, range } = {}) {
  const headers = new Headers();
  if (cookie) {
    headers.set("Cookie", cookie);
  }
  if (from) {
    headers.set("Origin", from);
  }
  if (range) {
    headers.set("Range", range);
  }
  const pending = [];
  const response = await worker.fetch(
    new Request(`${HLS}${path}`, { headers }),
    ENV,
    { waitUntil: (p) => pending.push(p) },
  );
  await Promise.all(pending);
  return response;
}

describe("stream relay worker", () => {
  it("tells the service it is live without asking the origin", async () => {
    const response = await get("/health");
    assert.deepEqual(await response.json(), {
      ok: true,
      worker: "5stack-stream-relay",
      version: "1",
    });
    assert.equal(origin.requests.length, 0);
  });

  it("sends each segment once and serves every other viewer from the edge", async () => {
    const first = await get("/match-1/seg3.mp4");
    assert.equal(first.status, 200);
    assert.match(await first.text(), /^segment-3-/);
    for (let i = 0; i < 4; i++) {
      const again = await get("/match-1/seg3.mp4", { cookie: `session=v${i}` });
      assert.equal(again.status, 200);
    }
    assert.equal(origin.hits("seg3.mp4"), 1 + 4);
    for (let i = 0; i < 10; i++) {
      assert.match(await (await get("/match-1/seg3.mp4")).text(), /^segment-3-/);
    }
    assert.equal(origin.hits("seg3.mp4"), 5);
  });

  it("keeps a live playlist for at most a second, so viewers see new segments", async () => {
    const first = await (await get("/match-1/index.m3u8")).text();
    assert.match(first, /#EXT-X-MEDIA-SEQUENCE:0/);
    now += 500;
    assert.equal(await (await get("/match-1/index.m3u8")).text(), first);
    assert.equal(origin.hits("index.m3u8"), 1);
    origin.live(2);
    now += 600;
    const next = await (await get("/match-1/index.m3u8")).text();
    assert.match(next, /#EXT-X-MEDIA-SEQUENCE:2/);
    assert.match(next, /seg8\.mp4/);
    assert.equal(origin.hits("index.m3u8"), 2);
  });

  it("follows a live stream the way a player does", async () => {
    const fetched = new Set();
    for (let second = 0; second < 5; second++) {
      for (const viewer of ["a", "b", "c"]) {
        const text = await (
          await get("/match-1/index.m3u8", { cookie: `session=${viewer}` })
        ).text();
        for (const name of text.split("\n").filter((l) => l.endsWith(".mp4"))) {
          const response = await get(`/match-1/${name}`, {
            cookie: `session=${viewer}`,
          });
          assert.equal(response.status, 200);
          fetched.add(name);
        }
      }
      origin.live(1);
      now += 1000;
    }
    assert.ok(fetched.size >= 11);
    for (const name of fetched) {
      assert.equal(origin.hits(name), 1, `${name} reached the origin ${origin.hits(name)} times`);
    }
    assert.ok(origin.hits("index.m3u8") >= 5);
  });

  it("never gives a cached segment to a viewer the panel refuses", async () => {
    await get("/match-1/seg2.mp4");
    const refused = await get("/match-1/seg2.mp4", { cookie: PLAYER });
    assert.equal(refused.status, 401);
    const anonymous = await get("/match-1/seg2.mp4", { cookie: "" });
    assert.equal(anonymous.status, 401);
    const playlist = await get("/match-1/index.m3u8", { cookie: PLAYER });
    assert.equal(playlist.status, 401);
  });

  it("asks the panel again once a viewer's allow is 30 seconds old", async () => {
    await get("/match-1/seg2.mp4");
    now += 29_000;
    await get("/match-1/seg2.mp4");
    assert.equal(origin.hits("seg2.mp4"), 1);
    origin.blocked.add(VIEWER);
    now += 2_000;
    const response = await get("/match-1/seg2.mp4");
    assert.equal(response.status, 401);
  });

  it("passes a 404 from the origin through unchanged and caches nothing", async () => {
    const missing = await get("/match-1/seg99.mp4");
    assert.equal(missing.status, 404);
    assert.equal(await missing.text(), "not found");
    assert.equal(missing.headers.get("Access-Control-Allow-Origin"), WEB);
    origin.segments.set("seg99.mp4", "late");
    const late = await get("/match-1/seg99.mp4");
    assert.equal(late.status, 200);
    assert.equal(await late.text(), "late");
    const noStream = await get("/match-9/index.m3u8");
    assert.equal(noStream.status, 404);
    assert.equal(await noStream.text(), "no stream");
  });

  it("answers a range from the edge copy, and passes a first range through", async () => {
    const first = await get("/match-1/seg4.mp4", { range: "bytes=0-9" });
    assert.equal(first.status, 206);
    assert.equal(await first.text(), "segment-4-");
    assert.equal(first.headers.get("Content-Range"), "bytes 0-9/64");
    const lastRequest = origin.requests.at(-1);
    assert.equal(lastRequest.headers.get("Range"), "bytes=0-9");
    assert.equal(cache.has(`${HLS}/match-1/seg4.mp4`), false);

    await get("/match-1/seg4.mp4");
    const hits = origin.hits("seg4.mp4");
    const ranged = await get("/match-1/seg4.mp4", { range: "bytes=8-11" });
    assert.equal(ranged.status, 206);
    assert.equal(await ranged.text(), "4-xx");
    assert.equal(ranged.headers.get("Content-Range"), "bytes 8-11/64");
    assert.equal(ranged.headers.get("Content-Length"), "4");
    const tail = await get("/match-1/seg4.mp4", { range: "bytes=-3" });
    assert.equal(await tail.text(), "xxx");
    const beyond = await get("/match-1/seg4.mp4", { range: "bytes=100-" });
    assert.equal(beyond.status, 416);
    assert.equal(beyond.headers.get("Content-Range"), "bytes */64");
    assert.equal(origin.hits("seg4.mp4"), hits);
  });

  it("answers CORS for the panel's site the way the panel does, from the edge copy too", async () => {
    await get("/match-1/seg5.mp4", { from: null });
    const fromSite = await get("/match-1/seg5.mp4");
    assert.equal(fromSite.headers.get("Access-Control-Allow-Origin"), WEB);
    assert.equal(fromSite.headers.get("Access-Control-Allow-Credentials"), "true");
    assert.equal(fromSite.headers.get("Vary"), "Origin");
    const elsewhere = await get("/match-1/seg5.mp4", { from: "https://other.example" });
    assert.equal(elsewhere.headers.get("Access-Control-Allow-Origin"), "*");
    assert.equal(elsewhere.headers.get("Access-Control-Allow-Credentials"), null);
    assert.equal(fromSite.headers.get("Set-Cookie"), null);
    assert.match(fromSite.headers.get("Cache-Control"), /^private/);
  });

  it("passes WebRTC signalling and the player page straight through", async () => {
    const seen = [];
    globalThis.fetch = async (input) => {
      seen.push(input instanceof Request ? `${input.method} ${input.url}` : input);
      return new Response("ok", { status: 201 });
    };
    const pending = [];
    const ctx = { waitUntil: (p) => pending.push(p) };
    const whep = await worker.fetch(
      new Request(`${HLS}/match-1/whep`, { method: "POST", body: "offer" }),
      ENV,
      ctx,
    );
    assert.equal(whep.status, 201);
    await worker.fetch(new Request(`${HLS}/match-1/`), ENV, ctx);
    assert.deepEqual(seen, [`POST ${HLS}/match-1/whep`, `GET ${HLS}/match-1/`]);
    assert.equal(cache.size, 0);
  });
});
