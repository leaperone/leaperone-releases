import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';

const workflow = readFileSync(new URL('../.github/workflows/deploy-multipost.yml', import.meta.url), 'utf8');
const resolver = workflow.split('      - name: Resolve deploy context\n')[1]
  .split('        run: |\n')[1].split('\n  build-and-push:')[0]
  .split('\n').map((line) => line.startsWith('          ') ? line.slice(10) : line).join('\n');

function parseOutputs(text) {
  const outputs = {};
  for (const line of text.split('\n')) {
    const index = line.indexOf('=');
    if (index > 0) outputs[line.slice(0, index)] = line.slice(index + 1);
  }
  return outputs;
}

function resolve(components, ref = 'main') {
  const directory = mkdtempSync(path.join(tmpdir(), 'multipost-components-'));
  const output = path.join(directory, 'outputs');
  const script = resolver
    .replaceAll('${{ github.event.client_payload.ref }}', ref)
    .replaceAll('${{ github.event.client_payload.env }}', 'production')
    .replaceAll('${{ github.event.client_payload.components || github.event.client_payload.build_targets }}', components);
  try {
    const result = spawnSync('bash', ['-eu', '-c', script], { encoding: 'utf8', env: { ...process.env, GITHUB_OUTPUT: output } });
    return { ...result, outputs: result.status === 0 ? parseOutputs(readFileSync(output, 'utf8')) : {} };
  } finally { rmSync(directory, { recursive: true, force: true }); }
}

for (const [selected, ref, web, backend, migrationMode] of [
  ['', 'main', true, true, 'apply'],
  ['web', 'main', true, false, 'verify-only'],
  ['backend', 'main', false, true, 'apply'],
  ['all', 'main', true, true, 'apply'],
  ['', 'web-v1.2.3', true, false, 'verify-only'],
  ['', 'refs/tags/web-v1.2.3', true, false, 'verify-only'],
  ['web', 'web-v1.2.3', true, false, 'verify-only'],
  ['backend', 'web-v1.2.3', false, true, 'apply'],
  ['all', 'refs/tags/web-v9.0.0', true, true, 'apply'],
]) {
  test(`resolve ${selected || 'default'} @ ${ref} selects components and migration_mode=${migrationMode}`, () => {
    const result = resolve(selected, ref);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.outputs.build_web, String(web));
    assert.equal(result.outputs.build_backend, String(backend));
    assert.equal(result.outputs.migration_mode, migrationMode);
    assert.ok(!JSON.stringify(result.outputs).includes('video_stt'));
  });
}
test('a retired worker component cannot silently deploy another service', () => {
  const result = resolve('video-stt-worker');
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /unknown MultiPost component/);
});
test('an old worker tag requires an explicit remaining component', () => {
  assert.notEqual(resolve('', 'worker-v1.2.3').status, 0);
  const result = resolve('backend', 'worker-v1.2.3');
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.outputs.migration_mode, 'apply');
});
test('PR merge refs cannot invoke deployment', () => {
  assert.notEqual(resolve('web', 'refs/pull/123/merge').status, 0);
});

const deploy = readFileSync(new URL('../compose/multipost/deploy-bluegreen.sh', import.meta.url), 'utf8');
const selection = deploy.slice(deploy.indexOf('DEPLOY_COMPONENTS_RAW='), deploy.indexOf('# ── 部署锁'));
const digest = `sha256:${'a'.repeat(64)}`;
function select(components, digests = `web=${digest},backend=${digest}`) {
  return spawnSync('bash', ['-eu', '-c', selection + '\nprintf "%s,%s" "$WANT_WEB" "$WANT_BACKEND"'], {
    encoding: 'utf8', env: { ...process.env, DEPLOY_COMPONENTS: components, REGISTRY_HOST: 'registry.example.com', COMPONENT_IMAGE_DIGESTS: digests },
  });
}
test('deployment component selection preserves web and backend digest guards', () => {
  for (const [component, expected] of [['web', 'true,false'], ['backend', 'false,true'], ['all', 'true,true']]) {
    const result = select(component);
    assert.equal(result.status, 0, result.stderr);
    assert.ok(result.stdout.endsWith(expected));
  }
  assert.notEqual(select('web', '').status, 0);
  assert.notEqual(select('backend', 'backend=invalid').status, 0);
});
test('deployment rejects retired selectors and digests before locks or Docker', () => {
  assert.notEqual(select('video-stt-worker').status, 0);
  assert.notEqual(select('web', `video-stt-worker=${digest}`).status, 0);
});

const migrateJob = workflow.split('  migrate-production:\n')[1].split('\n  deploy-de:\n')[0];
test('web-only migration path never runs atlas migrate apply', () => {
  assert.ok(migrateJob.includes("migration_mode == 'verify-only'"));
  assert.ok(migrateJob.includes('verify-multipost-no-migrations.py'));
  const verifyStep = migrateJob.split('- name: Verify database unchanged (web-only)')[1]?.split('- name: Run database migrations')[0] ?? '';
  assert.ok(verifyStep);
  assert.ok(!verifyStep.includes('migrate apply'));
  const applyStep = migrateJob.split('- name: Run database migrations (Atlas)')[1] ?? '';
  assert.ok(applyStep.includes("migration_mode == 'apply'"));
  assert.ok(applyStep.includes('atlas migrate apply'));
});
