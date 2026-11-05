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
const MB = 1024 * 1024;
const KEY = "events/media/4f1e2d3c-5b6a-4798-8a7b-6c5d4e3f2a1b/0123abcd.mp4";
const UPLOAD_ID = "upload-1";

// The token the api's MultipartUploadsService puts on each part link
// (uploadToken.ts): the upload, its size and its part size.
function token(fields: Record<string, unknown>, secret = env.S3_SECRET) {
  const payload = Buffer.from(
    JSON.stringify({
      k: KEY,
      u: UPLOAD_ID,
      exp: Math.floor(Date.now() / 1000) + 3600,
      ...fields,
    }),
  ).toString("base64url");
  const sig = createHmac("sha256", secret).update(payload).digest("base64url");
  return `${payload}.${sig}`;
}

const SIZED = { s: 100 * MB, c: 64 * MB };

const realFetch = globalThis.fetch;
let upstream: ReturnType<typeof mock.fn>;

beforeEach(() => {
  upstream = mock.fn(
    async () => new Response(null, { status: 200, headers: { ETag: '"e"' } }),
  );
  globalThis.fetch = upstream as unknown as typeof fetch;
});

afterEach(() => {
  globalThis.fetch = realFetch;
});

function put(
  partNumber: string,
  contentLength: number | null,
  partToken = token(SIZED),
) {
  const ctx = { waitUntil: () => {}, passThroughOnException: () => {} };
  const headers: Record<string, string> = { Origin: "https://5stack.gg" };
  if (contentLength !== null) {
    headers["content-length"] = String(contentLength);
  }
  return worker.fetch(
    new Request(
      `https://cf.5stack.gg/${KEY}?partNumber=${partNumber}&uploadId=${UPLOAD_ID}&token=${encodeURIComponent(partToken)}`,
      { method: "PUT", headers },
    ),
    env,
    ctx as any,
  );
}

describe("backblaze-proxy multipart parts", () => {
  it("passes on each part of the size the upload was opened with", async () => {
    const first = await put("1", 64 * MB);
    const last = await put("2", 36 * MB);

    assert.equal(first.status, 200);
    assert.equal(last.status, 200);
    assert.equal(upstream.mock.callCount(), 2);
    assert.match(
      String(upstream.mock.calls[1].arguments[0]),
      /\?partNumber=2&uploadId=upload-1$/,
    );
  });

  for (const partNumber of ["3", "10000", "0", "-1", "1.5", "01", "1e1"]) {
    it(`refuses part ${partNumber}, which is not one of the upload's`, async () => {
      const response = await put(partNumber, 36 * MB);

      assert.equal(response.status, 403);
      assert.equal(upstream.mock.callCount(), 0);
    });
  }

  for (const [label, partNumber, length] of [
    ["a first part shorter than a part", "1", 36 * MB],
    ["a last part longer than what is left", "2", 64 * MB],
    ["a last part shorter than what is left", "2", 1],
  ] as const) {
    it(`refuses ${label}`, async () => {
      const response = await put(partNumber, length);

      assert.equal(response.status, 413);
      assert.equal(upstream.mock.callCount(), 0);
    });
  }

  for (const [label, fields] of [
    ["one minted before tokens named the size", {}],
    ["one with a part size over 64MiB", { s: 200 * MB, c: 128 * MB }],
    ["one needing more than 10,000 parts", { s: 10_001 * 5 * MB, c: 5 * MB }],
    ["one with a fractional size", { s: 100 * MB + 0.5, c: 64 * MB }],
    ["one with a size given as text", { s: String(100 * MB), c: 64 * MB }],
  ] as const) {
    it(`refuses a token that is ${label}`, async () => {
      const response = await put("1", 64 * MB, token(fields));

      assert.equal(response.status, 403);
      assert.equal(upstream.mock.callCount(), 0);
    });
  }

  it("refuses a token signed with another secret", async () => {
    const response = await put("1", 64 * MB, token(SIZED, "another"));

    assert.equal(response.status, 403);
    assert.equal(upstream.mock.callCount(), 0);
  });
});
