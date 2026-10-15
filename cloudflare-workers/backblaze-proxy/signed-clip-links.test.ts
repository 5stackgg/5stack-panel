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

// Stands in for curl under cf_api: records the request and the config it was
// handed on stdin, and answers with STUB_SETTINGS.
const CURL = `#!/bin/sh
printf '%s\\n' "$*" >> "$STUB_DIR/curl-calls"
cat >> "$STUB_DIR/curl-config"
printf '%s' "$STUB_SETTINGS"
`;

// backblaze-proxy.sh turns on REQUIRE_SIGNED_CLIPS only when this says
// "signing": a worker refusing unsigned clip links in front of an API that does
// not sign them, or signs with another S3_SECRET, refuses every clip.
describe("backblaze-proxy.sh signed clip links check", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "signed-clip-links-"));
    for (const [name, body] of [
      ["kubectl", KUBECTL],
      ["curl", CURL],
    ]) {
      writeFileSync(join(dir, name), body);
      chmodSync(join(dir, name), 0o755);
    }
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
        `source "${UTILS}/colors.sh"; source "${UTILS}/cloudflare_workers.sh"; source "${UTILS}/signed_clip_links.sh"; ${script}`,
        "bash",
        ...args,
      ],
      {
        encoding: "utf8",
        input: stub.STDIN ?? "",
        env: {
          ...process.env,
          PATH: `${dir}:${process.env.PATH}`,
          PANEL_KUBECONFIG: KUBECONFIG,
          CLOUDFLARE_ACCOUNT_ID: "acc123",
          CF_TOKEN: "cf-token",
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

  describe("whether the deployed worker requires signed links now", () => {
    const worker = (settings: unknown) =>
      run(
        'worker_signed_clip_links "$1"',
        {
          STUB_SETTINGS: JSON.stringify(settings),
        },
        "5stack",
      ).output;

    const settings = (bindings: Array<Record<string, string>>) => ({
      success: true,
      errors: [],
      result: { bindings },
    });

    it("is on when the worker has REQUIRE_SIGNED_CLIPS=1, asked of its settings", () => {
      assert.equal(
        worker(
          settings([
            { type: "plain_text", name: "API_URL", text: "https://api.test" },
            { type: "plain_text", name: "REQUIRE_SIGNED_CLIPS", text: "1" },
            { type: "secret_text", name: "S3_SECRET" },
          ]),
        ),
        "on",
      );
      assert.match(
        readFileSync(join(dir, "curl-calls"), "utf8"),
        /-X GET .*https:\/\/api\.cloudflare\.com\/client\/v4\/accounts\/acc123\/workers\/scripts\/5stack\/settings$/m,
      );
      assert.doesNotMatch(
        readFileSync(join(dir, "curl-calls"), "utf8"),
        /cf-token/,
      );
      assert.match(readFileSync(join(dir, "curl-config"), "utf8"), /cf-token/);
    });

    it("is off when the worker has no REQUIRE_SIGNED_CLIPS", () => {
      assert.equal(
        worker(
          settings([
            { type: "plain_text", name: "API_URL", text: "https://api.test" },
          ]),
        ),
        "off",
      );
    });

    it("is off when REQUIRE_SIGNED_CLIPS is anything but 1", () => {
      assert.equal(
        worker(
          settings([
            { type: "plain_text", name: "REQUIRE_SIGNED_CLIPS", text: "0" },
          ]),
        ),
        "off",
      );
    });

    it("is off when the worker has never been deployed", () => {
      assert.equal(
        worker({
          success: false,
          errors: [
            {
              code: 10007,
              message: "This Worker does not exist on your account.",
            },
          ],
        }),
        "off",
      );
    });

    it("is unknown when Cloudflare will not say", () => {
      assert.equal(
        worker({
          success: false,
          errors: [{ code: 10000, message: "Authentication error" }],
        }),
        "unknown",
      );
      assert.equal(worker("<html>bad gateway</html>"), "unknown");
    });
  });

  // 0 requires signed links on this deploy, 1 deploys without, 2 deploys
  // nothing. STDIN is the operator's answer when they are asked; "" is a run
  // with nobody there to answer.
  describe("what a deploy does about them", () => {
    const decide = (worker: string, state: string, answer = "") =>
      run(
        'require_signed_clip_links "$1" "$2"',
        { STDIN: answer },
        worker,
        state,
      );

    const TABLE: Array<[string, string, string, number]> = [
      ["on", "signing", "", 0],
      ["on", "unreachable", "", 0],
      ["on", "unsigned", "", 2],
      ["on", "unsigned", "n\n", 2],
      ["on", "unsigned", "y\n", 1],
      ["on", "mismatch", "", 2],
      ["on", "mismatch", "n\n", 2],
      ["on", "mismatch", "y\n", 1],
      ["off", "signing", "", 0],
      ["off", "unreachable", "", 1],
      ["off", "unsigned", "", 1],
      ["off", "mismatch", "", 1],
      ["unknown", "signing", "", 0],
      ["unknown", "unreachable", "", 2],
      ["unknown", "unreachable", "y\n", 1],
      ["unknown", "unsigned", "", 2],
      ["unknown", "unsigned", "y\n", 1],
      ["unknown", "mismatch", "", 2],
      ["unknown", "mismatch", "y\n", 1],
    ];

    for (const [worker, state, answer, status] of TABLE) {
      const asked = answer ? ` and answered ${answer.trim()}` : "";
      it(`${["requires them", "deploys without them", "deploys nothing"][status]} when the worker is ${worker}, the panel ${state}${asked}`, () => {
        assert.equal(decide(worker, state, answer).status, status);
      });
    }

    it("keeps requiring them when the panel cannot be asked, and says why", () => {
      const { status, output } = decide("on", "unreachable");

      assert.equal(status, 0);
      assert.match(output, /keeps\s+requiring them/);
      assert.match(output, new RegExp(KUBECONFIG));
    });

    it("says turning them off reaches every panel on the worker before asking", () => {
      const { output } = decide("on", "unsigned");

      assert.match(
        output,
        /turns\s+that off for every panel using this worker/,
      );
    });

    it("warns that every panel on the worker must already sign them when it turns them on", () => {
      for (const worker of ["off", "unknown"]) {
        assert.match(
          decide(worker, "signing").output,
          /Every panel using this worker\s+must\s+already sign them/,
        );
      }
    });

    it("says a private clip stays downloadable while they are off", () => {
      for (const state of ["unreachable", "unsigned", "mismatch"]) {
        assert.match(
          decide("off", state).output,
          /can be downloaded by anyone who has its link/,
        );
      }
    });
  });

  // The block of backblaze-proxy.sh that acts on the decision, run as written
  // with the decision stubbed: only it puts REQUIRE_SIGNED_CLIPS on the deploy.
  describe("the deploy script", () => {
    const script = readFileSync(
      join(import.meta.dirname, "..", "..", "backblaze-proxy.sh"),
      "utf8",
    );
    const block = script.slice(
      script.indexOf('step "Checking that the panel signs clip links"'),
      script.indexOf('step "Ready to deploy"'),
    );

    const deploy = (decision: number) => {
      const result = spawnSync(
        "bash",
        [
          "-c",
          `step() { :; }; warn() { :; }; die() { exit 1; }
worker_signed_clip_links() { echo on; }
signed_clip_links_state() { echo unsigned; }
require_signed_clip_links() { return ${decision}; }
VARS=(--var "BUCKET_NAME:5stack")
${block}
printf '%s\\n' "$SIGNED_CLIPS_REQUIRED" "\${VARS[*]}"`,
        ],
        { encoding: "utf8" },
      );
      return {
        status: result.status,
        lines: result.stdout.trim().split("\n"),
      };
    };

    it("deploys with REQUIRE_SIGNED_CLIPS=1 only when the decision requires it", () => {
      assert.deepEqual(deploy(0), {
        status: 0,
        lines: [
          "true",
          "--var BUCKET_NAME:5stack --var REQUIRE_SIGNED_CLIPS:1",
        ],
      });
      assert.deepEqual(deploy(1), {
        status: 0,
        lines: ["false", "--var BUCKET_NAME:5stack"],
      });
    });

    it("stops before deploying when the operator does not agree to turn them off", () => {
      assert.equal(deploy(2).status, 1);
    });
  });
});
