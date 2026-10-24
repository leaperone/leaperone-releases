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

function resolve(components, ref = 'main') {
  const directory = mkdtempSync(path.join(tmpdir(), 'multipost-components-'));
  const output = path.join(directory, 'outputs');
  const script = resolver
    .replaceAll('${{ github.event.client_payload.ref }}', ref)
    .replaceAll('${{ github.event.client_payload.env }}', 'production')
    .replaceAll('${{ github.event.client_payload.components || github.event.client_payload.build_targets }}', components);
  try {
    const result = spawnSync('bash', ['-eu', '-c', script], { encoding: 'utf8', env: { ...process.env, GITHUB_OUTPUT: output } });
    return { ...result, outputs: result.status === 0 ? readFileSync(output, 'utf8') : '' };
  } finally { rmSync(directory, { recursive: true, force: true }); }
}

for (const [selected, web, backend] of [['web', true, false], ['backend', false, true], ['all', true, true], ['', true, true]]) {
  test(`resolve ${selected || 'default'} retains the selected publishing components`, () => {
    const result = resolve(selected);
    assert.equal(result.status, 0, result.stderr);
    assert.ok(result.outputs.includes(`build_web=${web}\n`));
    assert.ok(result.outputs.includes(`build_backend=${backend}\n`));
    assert.ok(!result.outputs.includes('video_stt'));
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
