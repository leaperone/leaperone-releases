import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const artifactRoot = join(root, ".artifacts", "telemetry-selfcheck");
const digest = value => createHash("sha256").update(value).digest("hex");
const bundle = "exact-build-source-map-bundle";

async function fixture(t) {
  await mkdir(artifactRoot, { recursive: true });
  const directory = await mkdtemp(join(artifactRoot, "case-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await mkdir(join(directory, "bin"));
  return directory;
}

function run(command, args, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: root, env: { ...process.env, ...env }, timeout: 15_000 });
    let output = "";
    child.stdout.on("data", data => { output += data; });
    child.stderr.on("data", data => { output += data; });
    child.on("error", reject);
    child.on("close", (code, signal) => resolve({ code, signal, output }));
  });
}

async function executable(directory, name, source) {
  await writeFile(join(directory, "bin", name), source, { mode: 0o700 });
}

async function runSentryUploadStep(t, { createStatus = 0, uploadStatus = 0, finalizeStatus = 0 } = {}) {
  const directory = await fixture(t);
  const workflow = await readFile(join(root, ".github/workflows/upload-telemetry-sourcemaps.yml"), "utf8");
  const script = workflow.match(/- name: Upload to Sentry[\s\S]*?        run: \|\n([\s\S]*?)\n      - name:/)[1].replace(/^ {10}/gm, "");
  await executable(directory, "pnpm", `#!/usr/bin/env bash
if env | grep -q '^POSTHOG_'; then exit 98; fi
echo "$*" >> "$FIXTURE/calls"
if [[ "$*" = *"releases info"* ]]; then exit 1; fi
if [[ "$*" = *"releases new"* ]]; then exit "$CREATE_STATUS"; fi
if [[ "$*" = *"sourcemaps upload"* ]]; then
  if [[ "$UPLOAD_STATUS" != 0 ]]; then echo "synthetic-sentry-cli-error" >&2; fi
  exit "$UPLOAD_STATUS"
fi
if [[ "$*" = *"releases finalize"* ]]; then exit "$FINALIZE_STATUS"; fi
exit 99
`);
  const environment = { ...process.env,
    PATH: `${join(directory, "bin")}:${process.env.PATH}`, FIXTURE: directory,
    RUNNER_TEMP: directory, GITHUB_RUN_ID: "1", GITHUB_RUN_ATTEMPT: "1", SOURCE_MAP_DIR: directory,
    SENTRY_AUTH_TOKEN: "synthetic-token", SENTRY_URL: "http://127.0.0.1:1", SENTRY_RELEASE: "test-release",
    CREATE_STATUS: String(createStatus), UPLOAD_STATUS: String(uploadStatus), FINALIZE_STATUS: String(finalizeStatus),
  };
  for (const key of Object.keys(environment)) if (key.startsWith("POSTHOG_")) delete environment[key];
  const result = await new Promise((resolve, reject) => {
    const child = spawn("bash", ["-euo", "pipefail", "-c", script], { cwd: root, env: environment });
    let output = "";
    child.stdout.on("data", data => { output += data; });
    child.stderr.on("data", data => { output += data; });
    child.on("error", reject);
    child.on("close", code => resolve({ code, output }));
  });
  const calls = (await readFile(join(directory, "calls"), "utf8")).trim().split("\n");
  assert.ok(calls.some(line => line.includes("releases new test-release")), result.output);
  assert.equal(calls.some(line => line.includes(`sourcemaps upload --release test-release ${directory}`)), createStatus === 0, result.output);
  assert.equal(calls.some(line => line.includes("releases finalize test-release")), createStatus === 0 && uploadStatus === 0, result.output);
  return result;
}

test("Sentry-only upload succeeds without PostHog environment or processes", async t => {
  const result = await runSentryUploadStep(t);
  assert.equal(result.code, 0, result.output);
  assert.match(result.output, /Sentry source maps uploaded successfully/);
});

for (const stage of ["create", "upload", "finalize"]) {
  test(`Sentry ${stage} failure stops the workflow even when later commands could succeed`, async t => {
    const result = await runSentryUploadStep(t, { [`${stage}Status`]: 42 });
    assert.equal(result.code, 1, result.output);
    assert.match(result.output, /ERROR: Sentry source map upload failed/);
    if (stage === "upload") assert.match(result.output, /synthetic-sentry-cli-error/);
  });
}

test("reusable workflow and all callers omit PostHog upload inputs", async () => {
  const workflow = await readFile(join(root, ".github/workflows/upload-telemetry-sourcemaps.yml"), "utf8");
  assert.doesNotMatch(workflow, /posthog|POSTHOG|upload-posthog-sourcemaps|@posthog\/cli/);
  for (const caller of ["deploy-twosomeone.yml", "deploy-twssomeren.yml", "deploy-multipost.yml", "deploy-leaperone-frontend.yml"]) {
    const source = await readFile(join(root, ".github/workflows", caller), "utf8");
    const start = source.indexOf("  upload-sourcemaps:\n");
    assert(start >= 0, `${caller} must retain the Sentry upload job`);
    const job = source.slice(start).split(/\n(?=  [A-Za-z0-9_-]+:\n)/)[0];
    assert.match(job, /uses: \.\/\.github\/workflows\/upload-telemetry-sourcemaps\.yml/);
    assert.doesNotMatch(job, /posthog_|POSTHOG_|allow_posthog_failure/);
    assert.doesNotMatch(source, /POSTHOG_PERSONAL_API_KEY|posthog_personal_api_key|POSTHOG_CLI_PROJECT_ID|posthog_cli_project_id/);
  }
});

test("2SOMEone build and upload use the same full Sentry source SHA", async t => {
  const directory = await fixture(t);
  const workflow = await readFile(join(root, ".github/workflows/deploy-twosomeone.yml"), "utf8");
  const source = "0123456789abcdef0123456789abcdef01234567";
  await executable(directory, "git", `#!/usr/bin/env bash\nif [ "$*" = "rev-parse HEAD" ]; then echo ${source}; elif [ "$*" = "rev-parse --short=7 HEAD" ]; then echo ${source.slice(0, 7)}; else exit 2; fi\n`);
  const output = join(directory, "output");
  const env = { PATH: `${join(directory, "bin")}:${process.env.PATH}`, GITHUB_OUTPUT: output, EXPECTED_SOURCE_SHA: source };
  const dispatch = {
    "github.event.inputs.ref || github.event.client_payload.ref": "main",
    "github.event.inputs.env || github.event.client_payload.env": "beta",
    "github.event.client_payload.components || github.event.client_payload.build_targets": "web",
    "github.event_name": "repository_dispatch",
  };
  const setRefScript = workflow.match(/id: set-ref[\s\S]*?        run: \|\n([\s\S]*?)\n      - name: Detect web-v/)[1].replace(/^ {10}/gm, "").replace(/\$\{\{ (.+?) \}\}/g, (_, expression) => { assert(expression in dispatch); return dispatch[expression]; });
  assert.equal((await run("bash", ["-euo", "pipefail", "-c", setRefScript], { ...env, RAW_SOURCE_SHA: source })).code, 0);
  const setRef = Object.fromEntries((await readFile(output, "utf8")).trim().split("\n").map(line => line.split("=")));
  await writeFile(output, "");
  const coordinateScript = workflow.match(/id: source-coordinate[\s\S]*?        run: \|\n([\s\S]*?)\n  build-and-push:/)[1].replace(/^ {10}/gm, "");
  assert.equal((await run("bash", ["-euo", "pipefail", "-c", coordinateScript], env)).code, 0);
  const coordinate = Object.fromEntries((await readFile(output, "utf8")).trim().split("\n").map(line => line.split("=")));
  assert.equal(coordinate.source_sha, source);
  assert.equal(coordinate.app_sha, source.slice(0, 7));
  const releaseScript = workflow.match(/id: sentry\n        run: (.+)/)[1];
  assert.equal((await run("bash", ["-euo", "pipefail", "-c", releaseScript], env)).code, 0);
  const release = (await readFile(output, "utf8")).match(/^release=(.+)$/m)[1];
  const context = { "steps.sentry.outputs.release": release, "steps.source-coordinate.outputs.source_sha": coordinate.source_sha, "steps.source-coordinate.outputs.app_sha": coordinate.app_sha, "steps.set-ref.outputs.ref": setRef.ref };
  const evaluate = template => template.replace(/\$\{\{ (.+?) \}\}/g, (_, expression) => { assert.equal(typeof context[expression], "string", `Missing workflow output: ${expression}`); return context[expression]; });
  const prepareOutputs = workflow.match(/  prepare:[\s\S]*?    outputs:\n([\s\S]*?)    steps:/)[1];
  for (const name of ["source_sha", "app_sha", "ref"]) {
    const definition = prepareOutputs.match(new RegExp(`^      ${name}: (.+)$`, "m"))?.[1];
    assert(definition, `prepare must export ${name}`);
    context[`needs.prepare.outputs.${name}`] = evaluate(definition);
  }
  const builds = [...workflow.matchAll(/^\s+SENTRY_RELEASE=(.+)$/gm)].map(match => evaluate(match[1]));
  assert.equal(builds.length, 2);
  const uploaded = evaluate(workflow.match(/^\s+sentry_release: (.+)$/m)[1]);
  assert.deepEqual([...builds, uploaded], Array(3).fill(`2someone-web@${source}`));
});

for (const mode of ["resume", "permanent", "exhausted", "mismatch", "invalid-checksum", "unsafe-key"]) {
  test(`fetch: ${mode}`, async t => {
    const directory = await fixture(t);
    await executable(directory, "timeout", '#!/usr/bin/env bash\nshift 2\nexec "$@"\n');
    await executable(directory, "ssh-keyscan", "#!/usr/bin/env bash\necho test-host-key\n");
    await executable(directory, "sleep", "#!/usr/bin/env bash\nexit 0\n");
    await executable(directory, "sha256sum", `#!/usr/bin/env node
const fs=require('node:fs'), crypto=require('node:crypto');
console.log(crypto.createHash('sha256').update(fs.readFileSync(process.argv[2])).digest('hex')+'  bundle');
`);
    await executable(directory, "rsync", `#!/usr/bin/env node
const fs=require('node:fs'), assert=require('node:assert/strict');
const env=process.env, args=process.argv.slice(2), destination=args.at(-1), source=args.at(-2);
if(source.endsWith('.sha256')) {
  fs.writeFileSync(destination, env.MODE==='invalid-checksum'?'bad':env.MODE==='mismatch'?'0'.repeat(64):env.DIGEST); process.exit(0);
}
const log=env.FIXTURE+'/attempts', previous=fs.existsSync(log)?Number(fs.readFileSync(log)):0;
fs.writeFileSync(log,String(previous+1));
assert(args.includes('--partial') && args.includes('--append-verify'));
if(env.MODE==='permanent') process.exit(23);
if(env.MODE==='exhausted') process.exit(124);
if(env.MODE==='resume' && previous===0) { fs.writeFileSync(destination,env.BUNDLE.slice(0,8)); process.exit(124); }
if(env.MODE==='resume') assert.equal(fs.readFileSync(destination,'utf8'),env.BUNDLE.slice(0,8));
fs.writeFileSync(destination,env.BUNDLE);
`);
    const destination = join(directory, "sourcemaps.tar");
    const result = await run("bash", ["scripts/fetch-sourcemap-bundle.sh", mode === "unsafe-key" ? "../other.tar" : "product/1-1-abcdef0.tar", destination], {
      PATH: `${join(directory, "bin")}:${process.env.PATH}`, TMPDIR: directory,
      MODE: mode, FIXTURE: directory, BUNDLE: bundle, DIGEST: digest(bundle),
      SOURCEMAP_SPOOL_HOST: "spool.invalid", SOURCEMAP_SPOOL_USERNAME: "test",
      SOURCEMAP_SPOOL_SSH_KEY: "synthetic-key", SOURCEMAP_SPOOL_ROOT: "/synthetic-spool",
    });
    const attempts = await readFile(join(directory, "attempts"), "utf8").catch(() => "0");
    assert.equal(Number(attempts), { resume: 2, permanent: 1, exhausted: 3, mismatch: 1, "invalid-checksum": 1, "unsafe-key": 0 }[mode], result.output);
    assert.equal(result.code, { resume: 0, permanent: 23, exhausted: 124, mismatch: 1, "invalid-checksum": 1, "unsafe-key": 1 }[mode], result.output);
    if (mode === "resume") assert.equal(digest(await readFile(destination)), digest(bundle));
  });
}
