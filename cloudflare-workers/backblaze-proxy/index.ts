import { AwsClient } from "aws4fetch";

// How many times to re-sign and retry an upstream request that came back
// 403/5xx. B2 intermittently rejects otherwise-valid signed reads; without a
// retry a single bad roll surfaces in the UI as a permanently broken clip,
// because the failure is never cached and every cold request rolls again.
const UPSTREAM_ATTEMPTS = 3;

const IMMUTABLE_TTL = 2592000;

// Every object is immutable except the map-asset pointer, which moves each
// time a new CS2 build is published; the edge and the browser must both let
// go of it within a minute.
const MUTABLE_TTL: Record<string, number> = { "maps/latest.json": 60 };

// Nothing from the client request is forwarded to B2. Every header we sign is
// a header Cloudflare may rewrite between sign() and fetch() — which B2 then
// reads as SignatureDoesNotMatch and answers 403. B2 needs none of them:
// Range is served out of the cached full 200, and conditionals would only
// defeat the edge cache. It also keeps the viewer's session cookie, UA and
// referer from being shipped to Backblaze on every clip view.
async function signedFetch(
  method: string,
  url: string,
  env: { S3_ACCESS_KEY: string; S3_SECRET: string },
  ttl: number,
): Promise<Response> {
  const client = new AwsClient({
    accessKeyId: env.S3_ACCESS_KEY,
    secretAccessKey: env.S3_SECRET,
    service: "s3",
  });

  let response: Response | null = null;
  for (let attempt = 0; attempt < UPSTREAM_ATTEMPTS; attempt++) {
    // Retries must carry a unique query param or they are not retries at all:
    // every attempt shares one Cloudflare cache key, so a cached 403 would be
    // replayed from the edge three times without B2 ever being asked again.
    // S3 ignores unrecognized query params, and signing the busted URL keeps
    // the signature valid.
    const target =
      attempt === 0
        ? url
        : `${url}?x-5stack-retry=${attempt}-${crypto.randomUUID()}`;
    const signed = await client.sign(target, {
      method,
      headers: new Headers(),
    });
    response = await fetch(signed.url, {
      method: signed.method,
      headers: signed.headers,
      cf: {
        cacheEverything: true,
        // 4xx must not be pinned: B2 has no ListBucket grant on our key, so a
        // transient denial and a genuinely missing object both arrive as 403,
        // and caching either one would outlive the condition that caused it.
        cacheTtlByStatus: { "200-299": ttl, "400-499": 0, "500-599": 0 },
      },
    });
    if (response.status !== 403 && response.status < 500) {
      return response;
    }
    // The last attempt is what the client gets, so its body has to survive:
    // handing a cancelled body to a new Response throws, and the client sees
    // Cloudflare's 1101 instead of the 403.
    if (attempt < UPSTREAM_ATTEMPTS - 1) {
      await response.body?.cancel();
    }
  }
  return response!;
}

const VIEW_FRACTION = 0.5;
const BOT_UA =
  /bot|crawl|spider|facebookexternalhit|slack|discord|telegram|whatsapp|preview|unfurl|embed|scrape|metainspector|skype|vkshare|redditbot|pinterest|googlebot|bingbot/i;

// Whether a served response spans the file's VIEW_FRACTION mark, decided from
// Content-Range rather than by counting bytes through the stream. Counting
// meant piping every byte of an 18 MB clip through JS, which is what pushed
// the Worker over its CPU limit; this reads three numbers off a header.
// Tail seeks and end-of-file moov probes still do not qualify. Repeat beacons
// are deduped API-side per viewer.
function spansViewThreshold(status: number, headers: Headers): boolean {
  if (status === 200) {
    return true;
  }
  const contentRange = headers.get("content-range");
  if (!contentRange) {
    return false;
  }
  const match = /^bytes\s+(\d+)-(\d+)\/(\d+)$/.exec(contentRange.trim());
  if (!match) {
    return false;
  }
  const start = Number(match[1]);
  const end = Number(match[2]);
  const total = Number(match[3]);
  if (!Number.isFinite(total) || total <= 0) {
    return false;
  }
  const threshold = total * VIEW_FRACTION;
  return start <= threshold && end >= threshold;
}

async function viewerKey(request: Request): Promise<string> {
  const ip = request.headers.get("cf-connecting-ip") ?? "";
  const ua = request.headers.get("user-agent") ?? "";
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${ip}\n${ua}`),
  );
  return Array.from(new Uint8Array(digest).slice(0, 16))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

// Whether this request is a viewable clip stream we should track. The
// actual increment is gated on what the response spans (see
// spansViewThreshold).
function shouldTrackView(
  request: Request,
  url: URL,
  key: string | null,
  env: { API_URL?: string },
): boolean {
  if (!env.API_URL || request.method !== "GET" || !key) {
    return false;
  }
  if (!/^clips\/.+\.mp4$/.test(key)) {
    return false;
  }
  if (
    url.searchParams.get("dl") === "1" ||
    url.searchParams.get("download") === "1" ||
    url.searchParams.get("noview") === "1"
  ) {
    return false;
  }
  if (BOT_UA.test(request.headers.get("user-agent") ?? "")) {
    return false;
  }
  return true;
}

function registerView(
  request: Request,
  key: string,
  env: { S3_SECRET: string; API_URL?: string },
  ctx: ExecutionContext,
) {
  ctx.waitUntil(
    viewerKey(request)
      .then((clientKey) =>
        fetch(`${env.API_URL!.replace(/\/+$/, "")}/clip-views/play`, {
          method: "POST",
          headers: {
            "content-type": "application/json",
            authorization: `Bearer ${env.S3_SECRET}`,
          },
          body: JSON.stringify({ file: key, clientKey }),
        }),
      )
      .catch(() => {}),
  );
}

// Decorates a response on its way to the client: mp4 Content-Type fix and the
// view beacon. The body is never read or rewritten here.
function clientResponse(
  source: Response,
  opts: {
    isHead: boolean;
    key: string;
    track: boolean;
    request: Request;
    env: { S3_SECRET: string; API_URL?: string };
    ctx: ExecutionContext;
  },
): Response {
  const headers = new Headers(source.headers);
  if (/\.mp4$/i.test(opts.key)) {
    // B2 stored old clips as binary/octet-stream; players refuse non-video/*.
    headers.set("Content-Type", "video/mp4");
  }
  if (!headers.has("Accept-Ranges")) {
    headers.set("Accept-Ranges", "bytes");
  }
  if (opts.track && spansViewThreshold(source.status, headers)) {
    registerView(opts.request, opts.key, opts.env, opts.ctx);
  }
  // A HEAD keeps the headers (Content-Length included, per spec) and drops the
  // body without reading it.
  if (opts.isHead) {
    opts.ctx.waitUntil(source.body?.cancel() ?? Promise.resolve());
    return new Response(null, {
      status: source.status,
      statusText: source.statusText,
      headers,
    });
  }
  // The body is handed straight through. Nothing inspects, slices or copies
  // it: range slicing is the cache layer's job now (see the cache.match on the
  // hot path), which is native and costs the Worker no CPU.
  return new Response(source.body, {
    status: source.status,
    statusText: source.statusText,
    headers,
  });
}

// Path-style (/clips/<user>/<uuid>.mp4) or query-style (?file=<key>).
function resolveKey(url: URL): string | null {
  const fromQuery = url.searchParams.get("file");
  if (fromQuery) {
    // Older callers built `?file=foo.mp4?dl=1` which parses as
    // file=foo.mp4?dl=1; drop anything past the first `?`.
    const cleaned = fromQuery.split("?")[0];
    return cleaned ? decodeURIComponent(cleaned) : null;
  }
  const fromPath = url.pathname.replace(/^\/+/, "");
  return fromPath ? decodeURIComponent(fromPath) : null;
}

export default {
  async fetch(
    request: Request,
    env: {
      S3_ACCESS_KEY: string;
      S3_SECRET: string;
      BUCKET_NAME: string;
      S3_ENDPOINT: string;
      API_URL?: string;
    },
    ctx: ExecutionContext,
  ) {
    const reqOrigin = request.headers.get("Origin");

    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: corsHeaders(reqOrigin),
      });
    }

    if (request.method === "PUT") {
      return handleUpload(request, env, reqOrigin);
    }

    if (!["GET", "HEAD"].includes(request.method)) {
      return new Response(null, {
        status: 405,
        statusText: "Method Not Allowed",
      });
    }

    const url = new URL(request.url);
    const key = resolveKey(url);
    const track = shouldTrackView(request, url, key, env);
    const rangeHeader =
      request.method === "GET" ? request.headers.get("range") : null;

    // The edge cache stores one full 200 per object. Range requests are sliced
    // out of it by cache.match itself — Cloudflare honours Range on a Cache API
    // lookup and builds the 206 natively, so the Worker never touches a byte of
    // video. Doing that slicing in JS is what burned 170-680ms of CPU per clip
    // request and got the Worker killed mid-stream ("exceeded CPU time limit"),
    // which browsers report as ERR_HTTP2_PROTOCOL_ERROR / ERR_QUIC_PROTOCOL_ERROR.
    //
    // Origin is in the cache key so each caller gets its own
    // Access-Control-Allow-Origin (credentialed fetches can't take `*`).
    const cache = caches.default;
    const cacheUrl = `${request.url}#origin=${reqOrigin ?? ""}`;
    const cacheKey = new Request(cacheUrl, { method: "GET" });
    const isHead = request.method === "HEAD";
    const lookupKey = rangeHeader
      ? new Request(cacheUrl, {
          method: "GET",
          headers: { Range: rangeHeader },
        })
      : cacheKey;
    const cached = await cache.match(lookupKey);
    if (cached) {
      return clientResponse(cached, {
        isHead,
        key: key ?? "",
        track,
        request,
        env,
        ctx,
      });
    }

    if (!key) {
      return new Response("No file provided", { status: 400 });
    }

    if (!env.BUCKET_NAME || !env.S3_ENDPOINT) {
      return new Response(
        "Worker misconfigured: BUCKET_NAME / S3_ENDPOINT not set",
        { status: 500 },
      );
    }
    if (!env.S3_ACCESS_KEY || !env.S3_SECRET) {
      return new Response(
        "Worker misconfigured: S3_ACCESS_KEY / S3_SECRET not set",
        { status: 500 },
      );
    }

    // Always the full object, never a Range: one 200 per object is fetched from
    // B2 and cached, and every later range is served out of that one copy. This
    // is what keeps B2 egress and transactions flat no matter how many range
    // requests a player makes.
    const ttl = MUTABLE_TTL[key] ?? IMMUTABLE_TTL;
    const upstream = await signedFetch(
      "GET",
      `https://${env.BUCKET_NAME}.${env.S3_ENDPOINT}/${key}`,
      env,
      ttl,
    );

    const headers = new Headers(upstream.headers);

    const requestedNameRaw = url.searchParams.get("name") ?? "";
    let requestedName = requestedNameRaw;
    try {
      requestedName = decodeURIComponent(requestedNameRaw);
    } catch {
      requestedName = requestedNameRaw;
    }
    const fallbackName = key.split("/").pop() ?? key;
    const sanitize = (s: string) => s.replace(/[\\\/"\r\n]/g, "").trim();
    const filename =
      sanitize(requestedName) || sanitize(fallbackName) || "clip.mp4";

    // Default to inline so pasting a clip URL plays in the browser;
    // ?dl=1 opts into attachment.
    const wantDownload =
      url.searchParams.get("dl") === "1" ||
      url.searchParams.get("download") === "1";
    headers.set(
      "Content-Disposition",
      `${wantDownload ? "attachment" : "inline"}; filename="${filename}"`,
    );

    if (!headers.has("Accept-Ranges")) {
      headers.set("Accept-Ranges", "bytes");
    }
    // Force long browser cache regardless of what B2 returned — second view
    // of a clip serves from the user's disk cache and never hits the Worker.
    headers.set(
      "Cache-Control",
      ttl === IMMUTABLE_TTL
        ? `public, max-age=${IMMUTABLE_TTL}, immutable`
        : `public, max-age=${ttl}`,
    );
    for (const [k, v] of Object.entries(corsHeaders(reqOrigin))) {
      headers.set(k, v);
    }

    if (/\.mp4$/i.test(key)) {
      // Stored on the cached copy, not patched on the way out, so range hits
      // served straight from cache carry it too.
      headers.set("Content-Type", "video/mp4");
    }

    const stored = new Response(upstream.body, {
      headers,
      status: upstream.status,
      statusText: upstream.statusText,
    });

    if (upstream.status !== 200) {
      return clientResponse(stored, { isHead, key, track, request, env, ctx });
    }

    // clone() rather than a manual tee: one branch fills the cache, the other
    // answers this request. A miss costs one full pass; every subsequent range
    // is served natively out of the stored object.
    ctx.waitUntil(cache.put(cacheKey, stored.clone()).catch(() => {}));

    // This request is answered with the whole object even if it asked for a
    // range. Serving a 200 to a Range request is explicitly allowed, and it
    // avoids slicing in JS on the one path where the cache can't do it yet.
    // Players re-request ranges afterwards and those hit the warm cache.
    return clientResponse(stored, { isHead, key, track, request, env, ctx });
  },
};

// Every write is still individually authorized by the API-minted HMAC token
// below; the prefix list only bounds which trees are writable at all.
// NOTE: a prefix here is necessary but NOT sufficient — the request only
// reaches the worker if one of its routes (ROUTE_PATHS in backblaze-proxy.sh)
// matches its path.
const UPLOAD_PREFIXES = ["demo-uploads/", "events/", "news/"];
// B2 multipart part ceiling we accept; the API chunks at 64MiB so anything
// larger is a malformed/abusive request.
const MAX_PART_BYTES = 64 * 1024 * 1024;

async function handleUpload(
  request: Request,
  env: {
    S3_ACCESS_KEY: string;
    S3_SECRET: string;
    BUCKET_NAME: string;
    S3_ENDPOINT: string;
  },
  reqOrigin: string | null,
): Promise<Response> {
  const url = new URL(request.url);
  const key = url.pathname.replace(/^\/+/, "");
  const partNumber = url.searchParams.get("partNumber");
  const uploadId = url.searchParams.get("uploadId");
  const token = url.searchParams.get("token");

  if (
    !UPLOAD_PREFIXES.some((prefix) => key.startsWith(prefix)) ||
    !partNumber ||
    !uploadId ||
    !token
  ) {
    return new Response("forbidden", {
      status: 403,
      headers: corsHeaders(reqOrigin),
    });
  }
  if (
    !env.BUCKET_NAME ||
    !env.S3_ENDPOINT ||
    !env.S3_ACCESS_KEY ||
    !env.S3_SECRET
  ) {
    return new Response("Worker misconfigured", {
      status: 500,
      headers: corsHeaders(reqOrigin),
    });
  }

  // Authorize the part write: the API mints this token (HMAC over key+uploadId
  // keyed on the shared S3_SECRET) only for authenticated admins. Without this
  // check the worker would sign arbitrary writes for anyone with a valid
  // uploadId.
  if (!(await verifyUploadToken(env.S3_SECRET, token, key, uploadId))) {
    return new Response("forbidden", {
      status: 403,
      headers: corsHeaders(reqOrigin),
    });
  }

  // The streamed body needs an explicit, bounded Content-Length — we forward
  // the client's value but never trust it blindly.
  const contentLengthRaw = request.headers.get("content-length");
  if (
    !contentLengthRaw ||
    !/^\d+$/.test(contentLengthRaw) ||
    Number(contentLengthRaw) > MAX_PART_BYTES
  ) {
    return new Response("invalid content-length", {
      status: 413,
      headers: corsHeaders(reqOrigin),
    });
  }

  const target = `https://${env.BUCKET_NAME}.${env.S3_ENDPOINT}/${key}?partNumber=${encodeURIComponent(
    partNumber,
  )}&uploadId=${encodeURIComponent(uploadId)}`;

  const signed = await new AwsClient({
    accessKeyId: env.S3_ACCESS_KEY,
    secretAccessKey: env.S3_SECRET,
    service: "s3",
  }).sign(target, {
    method: "PUT",
    headers: { "x-amz-content-sha256": "UNSIGNED-PAYLOAD" },
  });

  const headers = new Headers(signed.headers);
  headers.set("content-length", contentLengthRaw);

  const upstream = await fetch(target, {
    method: "PUT",
    headers,
    body: request.body,
  });

  const responseHeaders = new Headers(corsHeaders(reqOrigin));
  const etag = upstream.headers.get("etag");
  if (etag) {
    responseHeaders.set("ETag", etag);
  }

  if (upstream.ok) {
    return new Response(null, {
      status: upstream.status,
      headers: responseHeaders,
    });
  }
  return new Response(await upstream.text(), {
    status: upstream.status,
    statusText: upstream.statusText,
    headers: responseHeaders,
  });
}

function base64urlToBytes(value: string): Uint8Array {
  const b64 = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = b64.padEnd(Math.ceil(b64.length / 4) * 4, "=");
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

// Verifies the API-minted token: HMAC-SHA256 over the `payload` segment, then
// confirms the payload is bound to this exact key+uploadId and not expired.
// crypto.subtle.verify is constant-time, avoiding signature-timing leaks.
async function verifyUploadToken(
  secret: string,
  token: string,
  key: string,
  uploadId: string,
): Promise<boolean> {
  const dot = token.lastIndexOf(".");
  if (dot <= 0) return false;
  const message = token.slice(0, dot);
  const signature = token.slice(dot + 1);

  let signatureBytes: Uint8Array;
  let payloadBytes: Uint8Array;
  try {
    signatureBytes = base64urlToBytes(signature);
    payloadBytes = base64urlToBytes(message);
  } catch {
    return false;
  }

  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const valid = await crypto.subtle.verify(
    "HMAC",
    cryptoKey,
    signatureBytes,
    new TextEncoder().encode(message),
  );
  if (!valid) return false;

  let payload: { k?: unknown; u?: unknown; exp?: unknown };
  try {
    payload = JSON.parse(new TextDecoder().decode(payloadBytes));
  } catch {
    return false;
  }
  if (payload.k !== key || payload.u !== uploadId) return false;
  if (typeof payload.exp !== "number" || payload.exp * 1000 < Date.now()) {
    return false;
  }
  return true;
}

function corsHeaders(reqOrigin: string | null): Record<string, string> {
  // Reflect the request's Origin so credentialed fetches (which can't
  // accept Allow-Origin: *) work. Non-CORS requests (no Origin header)
  // fall back to `*` — same as before, keeps anon <video>/<a> usage
  // unchanged. Vary: Origin keeps shared caches from leaking the wrong
  // value to a different origin.
  const allowOrigin = reqOrigin ?? "*";
  const headers: Record<string, string> = {
    "Access-Control-Allow-Origin": allowOrigin,
    "Access-Control-Allow-Methods": "GET, HEAD, PUT, OPTIONS",
    "Access-Control-Allow-Headers":
      "Range, If-Range, Content-Type, Content-Length",
    "Access-Control-Expose-Headers":
      "Accept-Ranges, Content-Length, Content-Range, Content-Type, ETag, Last-Modified",
    Vary: "Origin",
  };
  if (allowOrigin !== "*") {
    headers["Access-Control-Allow-Credentials"] = "true";
  }
  return headers;
}
