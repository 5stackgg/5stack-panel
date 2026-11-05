const NAME = "5stack-stream-relay";
const VERSION = "1";

const PLAYLIST = /\.m3u8$/i;
const SEGMENT = /\.(ts|m4s|mp4)$/i;
const PLAYLIST_SECONDS = 1;
const SEGMENT_SECONDS = 60;
const ACCESS_SECONDS = 30;
const CORS_HEADERS = [
  "Access-Control-Allow-Origin",
  "Access-Control-Allow-Credentials",
  "Access-Control-Expose-Headers",
];

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return Response.json(
        { ok: true, worker: NAME, version: VERSION },
        {
          headers: {
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-store",
          },
        },
      );
    }
    if (request.method !== "GET") {
      return fetch(request);
    }
    const parts = url.pathname.split("/").filter(Boolean);
    if (parts.length !== 2) {
      return origin(request);
    }
    const [stream, file] = parts;
    if (PLAYLIST.test(file)) {
      return serve(request, env, ctx, stream, PLAYLIST_SECONDS);
    }
    if (SEGMENT.test(file)) {
      return serve(request, env, ctx, stream, SEGMENT_SECONDS);
    }
    return origin(request);
  },
};

function origin(request) {
  return fetch(request, { cache: "no-store" });
}

async function serve(request, env, ctx, stream, seconds) {
  const url = new URL(request.url);
  const key = new Request(`${url.origin}${url.pathname}${url.search}`);
  const pass = await accessKey(request, url, stream);
  const range = request.headers.get("Range");

  if (await caches.default.match(pass)) {
    const hit = await caches.default.match(key);
    if (hit) {
      return fromCache(hit, request, env, range, seconds);
    }
  }

  const response = await origin(request);
  if (response.ok) {
    ctx.waitUntil(
      caches.default.put(
        pass,
        new Response("allowed", {
          headers: { "Cache-Control": `max-age=${ACCESS_SECONDS}` },
        }),
      ),
    );
  }
  if (response.status !== 200 || range) {
    return response;
  }

  const body = await response.arrayBuffer();
  const headers = new Headers(response.headers);
  for (const name of [...CORS_HEADERS, "Set-Cookie", "Vary"]) {
    headers.delete(name);
  }
  headers.set("Cache-Control", `public, max-age=${seconds}`);
  const stored = new Response(body, { status: 200, headers });
  ctx.waitUntil(caches.default.put(key, stored.clone()));
  return fromCache(stored, request, env, null, seconds);
}

async function accessKey(request, url, stream) {
  const cookie = request.headers.get("Cookie") ?? "";
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(cookie),
  );
  const hash = [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return new Request(
    `${url.origin}/__5stack-access/${encodeURIComponent(stream)}/${hash}`,
  );
}

async function fromCache(cached, request, env, range, seconds) {
  const headers = new Headers(cached.headers);
  headers.set("Cache-Control", `private, max-age=${seconds}`);
  cors(headers, request, env);
  if (!range) {
    return new Response(cached.body, { status: 200, headers });
  }
  const body = await cached.arrayBuffer();
  const bounds = byteRange(range, body.byteLength);
  if (!bounds) {
    headers.set("Content-Range", `bytes */${body.byteLength}`);
    headers.delete("Content-Length");
    return new Response(null, { status: 416, headers });
  }
  const [start, end] = bounds;
  headers.set("Content-Range", `bytes ${start}-${end}/${body.byteLength}`);
  headers.set("Content-Length", String(end - start + 1));
  return new Response(body.slice(start, end + 1), { status: 206, headers });
}

function byteRange(header, size) {
  const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!match || (match[1] === "" && match[2] === "")) {
    return null;
  }
  let start;
  let end;
  if (match[1] === "") {
    const suffix = Number(match[2]);
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    start = Number(match[1]);
    end = match[2] === "" ? size - 1 : Math.min(Number(match[2]), size - 1);
  }
  if (start > end || start >= size) {
    return null;
  }
  return [start, end];
}

function cors(headers, request, env) {
  for (const name of CORS_HEADERS) {
    headers.delete(name);
  }
  const from = request.headers.get("Origin");
  if (from && env.WEB_ORIGIN && from === env.WEB_ORIGIN) {
    headers.set("Access-Control-Allow-Origin", from);
    headers.set("Access-Control-Allow-Credentials", "true");
    headers.set("Access-Control-Expose-Headers", "Location");
  } else if (from) {
    headers.set("Access-Control-Allow-Origin", "*");
  }
  headers.set("Vary", "Origin");
}
