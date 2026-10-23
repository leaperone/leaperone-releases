import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { setTimeout as delay } from "node:timers/promises";

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

for (const stopMode of ["zero", "descendant", "resistant"]) test(`PostHog routing: interrupted child ${stopMode}`, async t => {
  const directory = await fixture(t);
  await executable(directory, "pnpm", `#!/usr/bin/env node
const fs=require('node:fs');
process.on('SIGTERM',()=>{if(process.env.STOP_MODE!=='resistant') process.exit(0);});
if(process.env.STOP_MODE==='descendant') require('node:child_process').spawn(process.execPath,['-e',
  "process.on('SIGTERM',()=>{});require('node:fs').writeFileSync(process.env.FIXTURE+'/descendant',String(process.pid));setInterval(()=>{},1000);"
],{stdio:'inherit'});
fs.writeFileSync(process.env.FIXTURE+'/ready',JSON.stringify({pid:process.pid,adapter:process.env.POSTHOG_CLI_HOST}));
setInterval(()=>{},1000);
`);
  const child = spawn(process.execPath, ["scripts/upload-posthog-sourcemaps.mjs"], { cwd: root, env: {
    ...process.env, PATH: `${join(directory, "bin")}:${process.env.PATH}`, FIXTURE: directory, STOP_MODE: stopMode,
    POSTHOG_CLI_HOST: "http://127.0.0.1:1", POSTHOG_CLI_API_KEY: "synthetic-token", POSTHOG_CLI_PROJECT_ID: "2",
    SOURCE_MAP_DIR: directory, POSTHOG_RELEASE_NAME: "test-release", POSTHOG_RELEASE_VERSION: "abcdef0",
  } });
  const watchdog = setTimeout(() => child.kill("SIGKILL"), 15_000);
  t.after(() => clearTimeout(watchdog));
  t.after(() => { if (child.exitCode === null) child.kill(); });
  const closed = new Promise(resolve => child.on("exit", (code, signal) => resolve({ code, signal })));
  let ready, descendant;
  t.after(() => {
    if (ready) {
      try { process.kill(-ready.pid, "SIGKILL"); } catch (error) { if (error.code !== "ESRCH") throw error; }
    }
  });
  for (let i = 0; i < 100 && (!ready || (stopMode === "descendant" && !descendant)); i++) {
    ready = await readFile(join(directory, "ready"), "utf8").then(JSON.parse).catch(() => null);
    if (ready && stopMode === "descendant") {
      descendant = await readFile(join(directory, "descendant"), "utf8").then(Number).catch(() => null);
    }
    if (!ready || (stopMode === "descendant" && !descendant)) await delay(20);
  }
  assert(ready, "CLI did not start");
  if (stopMode === "descendant") assert(descendant, "CLI descendant did not start");
  child.kill("SIGTERM");
  assert.deepEqual(await closed, { code: 143, signal: null });
  assert.throws(() => process.kill(ready.pid, 0), { code: "ESRCH" });
  if (descendant) {
    for (let i = 0; i < 100; i++) {
      try { process.kill(descendant, 0); } catch (error) { if (error.code === "ESRCH") break; throw error; }
      await delay(10);
    }
    assert.throws(() => process.kill(descendant, 0), { code: "ESRCH" });
  }
  await assert.rejects(fetch(ready.adapter));
});

async function executable(directory, name, source) {
  await writeFile(join(directory, "bin", name), source, { mode: 0o700 });
}

for (const source of [
  { name: "incomplete", sha: "", ref: "main" },
  { name: "empty-ref", sha: "a".repeat(40), ref: "" },
  { name: "control-character", sha: "a".repeat(40), ref: "main\nother" },
]) test(`PostHog rejects a ${source.name} source coordinate before launching the CLI`, async t => {
  const directory = await fixture(t);
  await executable(directory, "pnpm", "#!/usr/bin/env bash\nexit 42\n");
  const result = await run(process.execPath, ["scripts/upload-posthog-sourcemaps.mjs"], {
    PATH: `${join(directory, "bin")}:${process.env.PATH}`,
    POSTHOG_CLI_HOST: "http://127.0.0.1:1", POSTHOG_CLI_API_KEY: "synthetic-token", POSTHOG_CLI_PROJECT_ID: "2",
    SOURCE_MAP_DIR: directory, POSTHOG_RELEASE_NAME: "test-release", POSTHOG_RELEASE_VERSION: "abcdef0",
    POSTHOG_SOURCE_REPOSITORY: "test-owner/source-app", POSTHOG_SOURCE_SHA: source.sha, POSTHOG_SOURCE_REF: source.ref,
  });
  assert.equal(result.code, 1);
  assert.match(result.output, /Invalid PostHog source coordinate/);
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
  assert.equal(evaluate(workflow.match(/^\s+posthog_release_version: (.+)$/m)[1]), source.slice(0, 7));
  assert.equal(evaluate(workflow.match(/^\s+posthog_source_sha: (.+)$/m)[1]), source);
  assert.equal(evaluate(workflow.match(/^\s+posthog_source_ref: (.+)$/m)[1]), "main");
  assert.equal(workflow.match(/^\s+posthog_source_repository: (.+)$/m)[1], workflow.match(/^\s+repository: (.+)$/m)[1]);
});

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

async function runUploadPolicy(t, optional, posthogStatus, sentryStatus, stalled = false) {
  const directory = await fixture(t);
  const workflow = await readFile(join(root, ".github/workflows/upload-telemetry-sourcemaps.yml"), "utf8");
  const script = workflow.match(/- name: Upload to internal PostHog and Sentry[\s\S]*?        run: \|\n([\s\S]*?)\n      - name:/)[1].replace(/^ {10}/gm, "");
  await executable(directory, "node", `#!/usr/bin/env bash
[[ "$*" = "scripts/upload-posthog-sourcemaps.mjs" ]] || exit 92
echo posthog >> "$FIXTURE/calls"
if [ "$STALLED" = "true" ]; then sleep 10; fi
exit "$POSTHOG_STATUS"
`);
  await executable(directory, "pnpm", `#!/usr/bin/env bash
echo "$*" >> "$FIXTURE/calls"
if [[ "$*" = *"sourcemaps upload"* ]]; then exit "$SENTRY_STATUS"; fi
`);
  await executable(directory, "timeout", `#!/usr/bin/env bash
[[ "$1 $2" = "--kill-after=10s 180s" ]] || exit 93
echo deadline >> "$FIXTURE/calls"
shift 2
if [ "$STALLED" = "true" ]; then exec /usr/bin/timeout --kill-after=0.1s 0.3s "$@"; fi
exec "$@"
`);
  const result = await run("bash", ["-euo", "pipefail", "-c", script], {
    PATH: `${join(directory, "bin")}:${process.env.PATH}`, FIXTURE: directory,
    RUNNER_TEMP: directory, GITHUB_RUN_ID: "1", GITHUB_RUN_ATTEMPT: "1", SOURCE_MAP_DIR: directory,
    ALLOW_POSTHOG_FAILURE: String(optional), POSTHOG_STATUS: String(posthogStatus), SENTRY_STATUS: String(sentryStatus), STALLED: String(stalled),
    POSTHOG_CLI_API_KEY: "synthetic-token", POSTHOG_CLI_PROJECT_ID: "2", POSTHOG_CLI_HOST: "http://127.0.0.1:1",
    SENTRY_AUTH_TOKEN: "synthetic-token", SENTRY_URL: "http://127.0.0.1:1", SENTRY_RELEASE: "test-release",
  });
  const calls = (await readFile(join(directory, "calls"), "utf8")).trim().split("\n");
  assert(calls.includes("posthog"), result.output);
  assert(calls.includes("deadline"), "PostHog must run with the bounded timeout");
  assert(calls.includes(`dlx @sentry/cli@2.58.5 sourcemaps upload --release test-release ${directory}`));
  assert.equal(calls.includes("dlx @sentry/cli@2.58.5 releases finalize test-release"), sentryStatus === 0);
  return result;
}

test("upload policy: only the 2SOMEone Beta caller opts in", async () => {
  const workflow = await readFile(join(root, ".github/workflows/upload-telemetry-sourcemaps.yml"), "utf8");
  assert.match(workflow, /allow_posthog_failure:\n\s+required: false\n\s+type: boolean\n\s+default: false/);
  assert.match(workflow, /ALLOW_POSTHOG_FAILURE: \$\{\{ inputs.allow_posthog_failure \}\}/);
  for (const caller of ["twosomeone", "twssomeren", "leaperone-frontend", "multipost"]) {
    const source = await readFile(join(root, `.github/workflows/deploy-${caller}.yml`), "utf8");
    if (caller === "twosomeone") {
      assert.match(source, /allow_posthog_failure: \$\{\{ needs.prepare.outputs.deploy_env == 'beta' \}\}/);
    } else {
      assert.doesNotMatch(source, /allow_posthog_failure:/);
    }
  }
});

for (const optional of [false, true]) {
  for (const posthogStatus of [0, 1]) for (const sentryStatus of [0, 1]) {
    test(`upload policy: optional=${optional}, PostHog=${posthogStatus}, Sentry=${sentryStatus}`, async t => {
      const result = await runUploadPolicy(t, optional, posthogStatus, sentryStatus);
      assert.equal(result.code, sentryStatus !== 0 || (posthogStatus !== 0 && !optional) ? 1 : 0, result.output);
      assert.equal(result.output.includes("::warning::PostHog"), optional && posthogStatus !== 0);
    });
  }
  test(`upload policy: stalled PostHog, optional=${optional}`, { skip: process.platform !== "linux" }, async t => {
    const result = await runUploadPolicy(t, optional, 0, 0, true);
    assert.equal(result.code, optional ? 0 : 1, result.output);
    if (optional) assert.match(result.output, /::warning::PostHog.*124/);
  });
}

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

const conditions = [{ bucket: "posthog" }, ["eq", "$key", "test-source-map"]];
const accepted = ["upload", "bucket-array", "no-trailing-slash", "source-metadata", "source-metadata-tag"];
for (const mode of [...accepted, "host-object", "host-array", "http", "query", "userinfo", "port", "trailing-slash", "encoded-path", "wrong-bucket", "bucket-conflict", "missing-bucket", "invalid-base64", "missing-policy", "malformed", "scope", "api-query", "unknown-endpoint", "no-auth", "wrong-auth", "redirect", "cli-failure"]) {
  test(`PostHog routing: ${mode}`, async t => {
    const directory = await fixture(t);
    const sourceRef = mode === "source-metadata-tag" ? "refs/tags/web-v1.2.3+候选.1" : "source-branch";
    const signedConditions = mode === "host-object" ? [...conditions, { Host: "objects.invalid" }] : mode === "host-array" ? [...conditions, ["eq", "$host", "objects.invalid"]] : mode === "bucket-array" ? [["eq", "$bucket", "posthog"]] : mode === "bucket-conflict" ? [...conditions, { bucket: "other" }] : mode === "missing-bucket" ? [] : conditions;
    const fields = { key: "test-source-map", policy: Buffer.from(JSON.stringify({ conditions: signedConditions })).toString("base64"), "x-amz-signature": "synthetic-signature" };
    if (mode === "invalid-base64") fields.policy = "!" + fields.policy;
    if (mode === "missing-policy") delete fields.policy;
    const uploadUrl = { http: "http://objects.invalid/posthog", query: "https://objects.invalid/posthog?signature=value", userinfo: "https://user@objects.invalid/posthog", port: "https://objects.invalid:444/posthog", "trailing-slash": "https://objects.invalid/posthog/", "encoded-path": "https://objects.invalid/%70osthog", "wrong-bucket": "https://objects.invalid/other" }[mode] ?? "https://objects.invalid/posthog";
    const requests = [];
    const upstream = createServer(async (request, response) => {
      const chunks = [];
      for await (const chunk of request) chunks.push(chunk);
      const body = Buffer.concat(chunks).toString();
      requests.push({ path: request.url, auth: request.headers.authorization, body });
      response.setHeader("content-type", "application/json");
      if (mode === "redirect") { response.writeHead(302, { location: "https://objects.invalid/other" }); response.end(); }
      else if (mode === "malformed") response.end(JSON.stringify({ id_map: [] }));
      else if (request.url.replace(/\/$/, "").endsWith("/bulk_start_upload")) response.end(JSON.stringify({ id_map: { sample: { presigned_url: { url: uploadUrl, fields } } } }));
      else response.end(JSON.stringify({ success: true }));
    });
    await new Promise(resolve => upstream.listen(0, "127.0.0.1", resolve));
    t.after(() => new Promise(resolve => { upstream.closeAllConnections(); upstream.close(resolve); }));
    const internal = `http://127.0.0.1:${upstream.address().port}`;
    await executable(directory, "pnpm", `#!/usr/bin/env node
const assert=require('node:assert/strict'), fs=require('node:fs');
(async()=>{
  const env=process.env, host=env.POSTHOG_CLI_HOST;
  if(env.MODE.startsWith('source-metadata')) assert.deepEqual([env.GITHUB_ACTIONS,env.GITHUB_REPOSITORY,env.GITHUB_SHA,env.GITHUB_REF_NAME,env.GITHUB_SERVER_URL],['true','test-owner/source-app','0123456789abcdef0123456789abcdef01234567',${JSON.stringify(sourceRef)},'https://github.com']);
  else assert.equal(env.GITHUB_REPOSITORY,'test-owner/automation');
  fs.writeFileSync(env.FIXTURE+'/adapter',host);
  assert.deepEqual(process.argv.slice(2),['dlx','@posthog/cli@0.8.4','sourcemap','upload','--directory',env.SOURCE_MAP_DIR,'--batch-size','10','--concurrency','2','--release-name','test-release','--release-version','abcdef0']);
  if(env.MODE==='cli-failure') process.exit(23);
  const route='/api/projects/'+(env.MODE==='scope'?'999':'2')+'/error_tracking/symbol_sets/';
  const endpoint=env.MODE==='unknown-endpoint'?'unknown/':env.MODE==='no-trailing-slash'?'bulk_start_upload':env.MODE==='api-query'?'bulk_start_upload/?next=other':'bulk_start_upload/';
  const headers={'content-type':'application/json'};
  if(env.MODE!=='no-auth') headers.authorization=env.MODE==='wrong-auth'?'Bearer incorrect-token':'Bearer synthetic-token';
  const response=await fetch(host+route+endpoint,{method:'POST',headers,body:JSON.stringify({symbol_sets:[{chunk_id:'sample'}]})});
  if(!['upload','bucket-array','no-trailing-slash','source-metadata','source-metadata-tag'].includes(env.MODE)) { assert.equal(response.status,502); return; }
  assert.equal(response.status,200);
  const form=(await response.json()).id_map.sample.presigned_url;
  assert.equal(form.url,env.INTERNAL+'/posthog');
  assert.deepEqual(form.fields,JSON.parse(env.FIELDS));
  const data=new FormData();
  for(const [key,value] of Object.entries(form.fields)) data.append(key,value);
  data.append('file',new Blob(['source-map-bytes']),'sample.gz');
  assert.equal((await fetch(form.url,{method:'POST',body:data})).status,200);
  assert.equal((await fetch(host+route+'bulk_finish_upload/',{method:'POST',headers:{authorization:'Bearer synthetic-token','content-type':'application/json'},body:JSON.stringify({content_hashes:['sample']})})).status,200);
})().catch(error=>{ console.error(error); process.exitCode=1; });
`);
    const result = await run(process.execPath, ["scripts/upload-posthog-sourcemaps.mjs"], {
      PATH: `${join(directory, "bin")}:${process.env.PATH}`, FIXTURE: directory, MODE: mode, INTERNAL: internal, FIELDS: JSON.stringify(fields),
      POSTHOG_CLI_HOST: internal, POSTHOG_CLI_API_KEY: "synthetic-token", POSTHOG_CLI_PROJECT_ID: "2",
      SOURCE_MAP_DIR: directory, POSTHOG_RELEASE_NAME: "test-release", POSTHOG_RELEASE_VERSION: "abcdef0",
      GITHUB_ACTIONS: "true", GITHUB_REPOSITORY: "test-owner/automation", GITHUB_SHA: "a".repeat(40), GITHUB_REF_NAME: "main", GITHUB_SERVER_URL: "https://github.com",
      POSTHOG_SOURCE_REPOSITORY: mode.startsWith("source-metadata") ? "test-owner/source-app" : "", POSTHOG_SOURCE_SHA: mode.startsWith("source-metadata") ? "0123456789abcdef0123456789abcdef01234567" : "", POSTHOG_SOURCE_REF: mode.startsWith("source-metadata") ? sourceRef : "",
    });
    assert.equal(result.code, accepted.includes(mode) ? 0 : mode === "cli-failure" ? 23 : 1, result.output);
    assert.equal(requests.length, accepted.includes(mode) ? 3 : ["scope", "api-query", "unknown-endpoint", "no-auth", "wrong-auth", "cli-failure"].includes(mode) ? 0 : 1, result.output);
    if (accepted.includes(mode)) {
      assert.equal(requests[0].auth, "Bearer synthetic-token");
      assert.match(requests[1].body, /source-map-bytes/);
      for (const value of Object.values(fields)) assert(requests[1].body.includes(value));
      assert.equal(requests[2].auth, "Bearer synthetic-token");
    }
    const adapter = await readFile(join(directory, "adapter"), "utf8");
    await assert.rejects(fetch(adapter));
    assert(!result.output.includes("synthetic-token") && !result.output.includes("synthetic-signature"));
  });
}
