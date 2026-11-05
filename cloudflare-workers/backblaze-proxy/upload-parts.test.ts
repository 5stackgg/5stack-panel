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

const SIZED = { v: 2, s: 100 * MB, c: 64 * MB };
// The last day the worker takes a token from an api older than sized tokens.
const LEGACY_CUTOFF = Date.parse("2026-12-15T00:00:00Z") / 1000;

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
    ["sized but missing the size", { v: 2, c: 64 * MB }],
    ["sized but missing the part size", { v: 2, s: 100 * MB }],
    ["naming only the size, without a version", { s: 100 * MB }],
    ["naming only the part size, without a version", { c: 64 * MB }],
    ["of a version this worker doesn't know", { v: 3, s: 100 * MB, c: 64 * MB }],
    ["one with a part size over 64MiB", { v: 2, s: 200 * MB, c: 128 * MB }],
    [
      "one needing more than 10,000 parts",
      { v: 2, s: 10_001 * 5 * MB, c: 5 * MB },
    ],
    ["one with a fractional size", { v: 2, s: 100 * MB + 0.5, c: 64 * MB }],
    [
      "one with a size given as text",
      { v: 2, s: String(100 * MB), c: 64 * MB },
    ],
  ] as const) {
    it(`refuses a token that is ${label}`, async () => {
      const response = await put("1", 64 * MB, token(fields));

      assert.equal(response.status, 403);
      assert.equal(upstream.mock.callCount(), 0);
    });
  }

  // Minted before tokens carried `v`, but sized all the same: held to its size.
  describe("on a sized token without a version", () => {
    const unversioned = () => token({ s: 100 * MB, c: 64 * MB });

    it("passes on each part of its size", async () => {
      const response = await put("2", 36 * MB, unversioned());

      assert.equal(response.status, 200);
    });

    it("refuses a part past its size", async () => {
      const response = await put("3", 36 * MB, unversioned());

      assert.equal(response.status, 403);
      assert.equal(upstream.mock.callCount(), 0);
    });

    it("refuses a part longer than its share", async () => {
      const response = await put("2", 64 * MB, unversioned());

      assert.equal(response.status, 413);
      assert.equal(upstream.mock.callCount(), 0);
    });
  });

  it("refuses a token whose payload was changed after it was signed", async () => {
    const [, sig] = token(SIZED).split(".");
    const payload = Buffer.from(
      JSON.stringify({
        v: 2,
        k: KEY,
        u: UPLOAD_ID,
        exp: Math.floor(Date.now() / 1000) + 3600,
        s: 1_000 * MB,
        c: 64 * MB,
      }),
    ).toString("base64url");

    const response = await put("1", 64 * MB, `${payload}.${sig}`);

    assert.equal(response.status, 403);
    assert.equal(upstream.mock.callCount(), 0);
  });

  it("refuses a token signed with another secret", async () => {
    const response = await put("1", 64 * MB, token(SIZED, "another"));

    assert.equal(response.status, 403);
    assert.equal(upstream.mock.callCount(), 0);
  });

  // Minted by an api from before sized tokens: one worker can serve several
  // panels, not all of them updated, so these keep the old limit until the
  // cutoff.
  describe("on a token from an api older than sized tokens", () => {
    const legacy = () => token({});

    it("refuses one that expires after the cutoff", async () => {
      const response = await put(
        "1",
        64 * MB,
        token({ exp: LEGACY_CUTOFF + 3600 }),
      );

      assert.equal(response.status, 403);
      assert.equal(upstream.mock.callCount(), 0);
    });

    for (const partNumber of ["1", "3", "10000"]) {
      it(`passes on part ${partNumber} of up to 64MiB`, async () => {
        const response = await put(partNumber, 64 * MB, legacy());

        assert.equal(response.status, 200);
        assert.equal(upstream.mock.callCount(), 1);
      });
    }

    for (const [label, length] of [
      ["a part over 64MiB", 64 * MB + 1],
      ["a part without a Content-Length", null],
    ] as const) {
      it(`refuses ${label}`, async () => {
        const response = await put("1", length, legacy());

        assert.equal(response.status, 413);
        assert.equal(upstream.mock.callCount(), 0);
      });
    }

    for (const partNumber of ["0", "10001", "1.5", "01"]) {
      it(`refuses part ${partNumber}`, async () => {
        const response = await put(partNumber, MB, legacy());

        assert.equal(response.status, 403);
        assert.equal(upstream.mock.callCount(), 0);
      });
    }
  });
});
