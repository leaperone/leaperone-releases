#!/usr/bin/env node
import { spawn } from "node:child_process";
import { createServer } from "node:http";

const env = process.env;
for (const name of ["POSTHOG_CLI_HOST", "POSTHOG_CLI_API_KEY", "POSTHOG_CLI_PROJECT_ID", "SOURCE_MAP_DIR", "POSTHOG_RELEASE_NAME", "POSTHOG_RELEASE_VERSION"]) {
  if (!env[name]) throw new Error(`Missing ${name}`);
}
if (!/^\d+$/.test(env.POSTHOG_CLI_PROJECT_ID)) throw new Error("Invalid PostHog project ID");
const hasSource = [env.POSTHOG_SOURCE_REPOSITORY, env.POSTHOG_SOURCE_SHA, env.POSTHOG_SOURCE_REF].some(Boolean);
if (hasSource && (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(env.POSTHOG_SOURCE_REPOSITORY ?? "") || !/^[0-9a-f]{40}$/.test(env.POSTHOG_SOURCE_SHA ?? "") || !/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(env.POSTHOG_SOURCE_REF ?? ""))) {
  throw new Error("Invalid PostHog source coordinate");
}
const sourceEnv = hasSource ? {
  GITHUB_ACTIONS: "true", GITHUB_REPOSITORY: env.POSTHOG_SOURCE_REPOSITORY,
  GITHUB_SHA: env.POSTHOG_SOURCE_SHA, GITHUB_REF_NAME: env.POSTHOG_SOURCE_REF,
  GITHUB_SERVER_URL: env.GITHUB_SERVER_URL || "https://github.com",
} : {};
const internal = new URL(env.POSTHOG_CLI_HOST);
if (!["http:", "https:"].includes(internal.protocol) || internal.username || internal.password || internal.pathname !== "/" || internal.search || internal.hash) {
  throw new Error("Invalid internal PostHog base URL");
}

function routeUploads(document) {
  if (!document.id_map || typeof document.id_map !== "object" || Array.isArray(document.id_map)) throw new Error("Invalid upload response");
  for (const entry of Object.values(document.id_map)) {
    const form = entry?.presigned_url;
    if (!form || typeof form.url !== "string" || !form.fields || typeof form.fields !== "object" || Array.isArray(form.fields) || !Object.values(form.fields).every(value => typeof value === "string") || !/^[A-Za-z0-9+/]+={0,2}$/.test(form.fields.policy) || form.fields.policy.length % 4 !== 0) {
      throw new Error("Invalid signed upload form");
    }
    const url = new URL(form.url);
    const policy = JSON.parse(Buffer.from(form.fields.policy, "base64").toString("utf8"));
    if (url.protocol !== "https:" || url.username || url.password || url.port || url.search || url.hash || !/^\/[a-z0-9][a-z0-9.-]*$/.test(url.pathname)) {
      throw new Error("Unexpected object upload URL");
    }
    if (!Array.isArray(policy.conditions)) throw new Error("Invalid signed upload policy");
    let hasBucket = false;
    for (const condition of policy.conditions) {
      const fields = Array.isArray(condition) ? [condition[1]] : Object.keys(condition);
      if (fields.some(field => /^\$?host$/i.test(field))) throw new Error("Object upload policy binds Host");
      const bucket = Array.isArray(condition) && condition[0] === "eq" && condition[1] === "$bucket" ? condition[2] : condition.bucket;
      if (bucket !== undefined) {
        if (bucket !== url.pathname.slice(1)) throw new Error("Object upload path does not match signed bucket");
        hasBucket = true;
      }
    }
    if (!hasBucket) throw new Error("Object upload policy does not bind bucket");
    form.url = internal.origin + url.pathname;
  }
}

let routingFailed = false;
const server = createServer(async (request, response) => {
  try {
    const target = new URL(request.url, internal);
    const project = env.POSTHOG_CLI_PROJECT_ID;
    const path = target.pathname.replace(/\/$/, "");
    const prefix = `/api/(?:projects|environments)/${project}/error_tracking/`;
    const allowed = request.method === "POST" ? new RegExp(`^${prefix}(?:symbol_sets/(?:bulk_start_upload|bulk_finish_upload)|releases)$`) : request.method === "GET" && new RegExp(`^${prefix}releases/hash/[0-9a-f]{128}$`);
    if (target.origin !== internal.origin || target.search || request.headers.authorization !== `Bearer ${env.POSTHOG_CLI_API_KEY}` || !allowed || !allowed.test(path)) {
      throw new Error("Unexpected PostHog API scope");
    }
    const chunks = [];
    let length = 0;
    for await (const chunk of request) {
      length += chunk.length;
      if (length > 1024 * 1024) throw new Error("PostHog metadata request is too large");
      chunks.push(chunk);
    }
    const upstream = await fetch(target, {
      method: request.method,
      headers: { authorization: request.headers.authorization ?? "", "content-type": request.headers["content-type"] ?? "application/json" },
      body: request.method === "POST" ? Buffer.concat(chunks) : undefined,
      redirect: "error",
      signal: AbortSignal.timeout(120_000),
    });
    let body = Buffer.from(await upstream.arrayBuffer());
    if (upstream.ok && path.endsWith("/bulk_start_upload")) {
      const document = JSON.parse(body.toString("utf8"));
      routeUploads(document);
      body = Buffer.from(JSON.stringify(document));
    }
    response.writeHead(upstream.status, { "content-type": upstream.headers.get("content-type") ?? "application/json", "content-length": body.length });
    response.end(body);
  } catch {
    routingFailed = true;
    console.error("ERROR: internal PostHog upload routing failed");
    response.writeHead(502);
    response.end("Internal PostHog upload routing failed");
  }
});

await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const child = spawn("pnpm", [
  "dlx", "@posthog/cli@0.8.4", "sourcemap", "upload",
  "--directory", env.SOURCE_MAP_DIR, "--batch-size", "10", "--concurrency", "2",
  "--release-name", env.POSTHOG_RELEASE_NAME, "--release-version", env.POSTHOG_RELEASE_VERSION,
], { stdio: "inherit", detached: true, env: { ...env, ...sourceEnv, RUST_LOG: "error", POSTHOG_CLI_HOST: `http://127.0.0.1:${server.address().port}` } });
let interrupted;
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => {
  interrupted = signal === "SIGINT" ? 130 : 143;
  if (child.pid && child.exitCode === null && child.signalCode === null) {
    try { process.kill(-child.pid, signal); } catch (error) { if (error.code !== "ESRCH") throw error; }
  }
});
try {
  process.exitCode = await new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("close", (code, signal) => resolve(interrupted ?? (code === 0 && routingFailed ? 1 : (code ?? (signal === "SIGINT" ? 130 : 143)))));
  });
} finally {
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
}
