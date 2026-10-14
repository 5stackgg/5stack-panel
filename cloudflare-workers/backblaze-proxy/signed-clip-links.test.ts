import { afterEach, beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash, createHmac } from "node:crypto";
import {
  chmodSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const UTILS = join(import.meta.dirname, "..", "..", "utils");
const SECRET = "bucket-secret";
const KUBECONFIG = "/etc/5stack/kubeconfig";

function keyHash(secret: string) {
  const key = createHmac("sha256", secret)
    .update("5stack-file-url-v1")
    .digest();
  return createHash("sha256").update(key).digest("hex");
}

// Stands in for kubectl: records how it was called and answers the check's two
// queries (the link function, then the stored key's hash) from the environment.
const KUBECTL = `#!/bin/sh
printf '%s\\n' "$*" >> "$STUB_DIR/calls"
if [ -n "$STUB_FAIL" ]; then
    exit 1
fi
for sql; do :; done
case "$sql" in
    *pg_get_functiondef*) printf '%s\\n' "$STUB_SIGNS" ;;
    *sha256*) if [ -n "$STUB_KEY_HASH" ]; then printf '%s\\n' "$STUB_KEY_HASH"; fi ;;
esac
`;

// backblaze-proxy.sh turns on REQUIRE_SIGNED_CLIPS only when this says
// "signing": a worker refusing unsigned clip links in front of an API that does
// not sign them, or signs with another S3_SECRET, refuses every clip.
describe("backblaze-proxy.sh signed clip links check", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "signed-clip-links-"));
    writeFileSync(join(dir, "kubectl"), KUBECTL);
    chmodSync(join(dir, "kubectl"), 0o755);
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  function run(
    script: string,
    stub: Record<string, string>,
    ...args: string[]
  ) {
    const result = spawnSync(
      "bash",
      [
        "-c",
        `source "${UTILS}/colors.sh"; source "${UTILS}/signed_clip_links.sh"; ${script}`,
        "bash",
        ...args,
      ],
      {
        encoding: "utf8",
        env: {
          ...process.env,
          PATH: `${dir}:${process.env.PATH}`,
          PANEL_KUBECONFIG: KUBECONFIG,
          STUB_DIR: dir,
          ...stub,
        },
      },
    );
    return { status: result.status, output: result.stdout.trim() };
  }

  const state = (stub: Record<string, string>) =>
    run('signed_clip_links_state "$1"', stub, SECRET).output;

  const calls = () =>
    readFileSync(join(dir, "calls"), "utf8").trim().split("\n");

  it("is signing when the link function signs with the key the worker's S3_SECRET derives", () => {
    assert.equal(
      state({ STUB_SIGNS: "t", STUB_KEY_HASH: keyHash(SECRET) }),
      "signing",
    );
    for (const call of calls()) {
      assert.match(
        call,
        new RegExp(
          `^--kubeconfig=${KUBECONFIG} -n 5stack exec timescaledb-0 -c timescaledb -- sh -c `,
        ),
      );
    }
  });

  it("never asks for the key itself, only its hash", () => {
    state({ STUB_SIGNS: "t", STUB_KEY_HASH: keyHash(SECRET) });

    assert.match(calls()[1], /encode\(sha256\(key\), 'hex'\)/);
  });

  it("is a mismatch when the API signs with another S3_SECRET", () => {
    assert.equal(
      state({ STUB_SIGNS: "t", STUB_KEY_HASH: keyHash("rotated-secret") }),
      "mismatch",
    );
  });

  it("is unsigned when the database's link function does not sign", () => {
    assert.equal(state({ STUB_SIGNS: "f" }), "unsigned");
    assert.equal(calls().length, 1);
  });

  it("is unsigned when the database predates the link function", () => {
    assert.equal(state({ STUB_SIGNS: "" }), "unsigned");
  });

  it("is unsigned when the API has not stored its key yet", () => {
    assert.equal(state({ STUB_SIGNS: "t" }), "unsigned");
  });

  it("is unreachable when kubectl cannot reach the panel", () => {
    assert.equal(state({ STUB_FAIL: "1" }), "unreachable");
  });

  for (const [current, required] of [
    ["signing", true],
    ["mismatch", false],
    ["unsigned", false],
    ["unreachable", false],
  ] as const) {
    it(`${required ? "requires" : "does not require"} signed links when the panel is ${current}`, () => {
      const { status, output } = run(
        'require_signed_clip_links "$1"',
        {},
        current,
      );

      assert.equal(status === 0, required);
      if (!required) {
        assert.match(output, /can be downloaded by anyone who has its link/);
        assert.match(output, /run this\s+again/i);
      }
    });
  }
});
