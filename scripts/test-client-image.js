const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const probe = fs.readFileSync(path.join(__dirname, 'check-client-image.js'), 'utf8');
const environment = {
  REACT_APP_CONFIG_ENV: 'prerelease',
  REACT_APP_API_INFLUENCE: 'https://api.test.invalid',
  REACT_APP_STARKNET_PROVIDER: 'https://starknet.test.invalid',
  REACT_APP_ETHEREUM_PROVIDER: 'https://ethereum.test.invalid',
  REACT_APP_API_IPFS: 'https://ipfs.test.invalid',
  REACT_APP_API_AVNU: 'https://avnu.test.invalid'
};

async function runProbe({ runtime = environment, html, bundleType = 'application/javascript', health = 204 } = {}) {
  const result = { exitCode: 0, errors: [], paths: [] };
  const context = {
    require, URL, AbortSignal,
    process: { env: environment, exit: (code) => { result.exitCode = code; } },
    console: { log() {}, error: (message) => result.errors.push(message) },
    fetch: async (url, options) => {
      assert.equal(url.origin, 'http://127.0.0.1:3000');
      assert.equal(options.redirect, 'error');
      assert.equal(options.headers['x-forwarded-proto'], 'https');
      result.paths.push(url.pathname);
      switch (url.pathname) {
        case '/healthz': return new Response(null, { status: health });
        case '/runtime-config.js': return new Response(
          `window.INFLUENCE_RUNTIME_CONFIG = Object.freeze(${JSON.stringify(runtime)});`,
          { headers: { 'content-type': 'application/javascript', 'cache-control': 'no-store' } }
        );
        case '/index.html': return new Response(html ??
          '<script src="/runtime-config.js"></script><script defer src="/static/js/main.js"></script>',
          { headers: { 'content-type': 'text/html' } }
        );
        case '/static/js/main.js': return new Response('console.log("built application");',
          { headers: { 'content-type': bundleType } }
        );
        default: throw new Error(`Unexpected request: ${url.pathname}`);
      }
    }
  };
  await vm.runInNewContext(probe, context);
  return result;
}

test('checks configured runtime values and local application assets', async () => {
  const result = await runProbe();
  assert.equal(result.exitCode, 0);
  assert.deepEqual(result.errors, []);
  assert.deepEqual(result.paths, ['/healthz', '/runtime-config.js', '/index.html', '/static/js/main.js']);
});

test('rejects an image serving a different environment or API', async () => {
  for (const name of ['REACT_APP_CONFIG_ENV', 'REACT_APP_API_INFLUENCE']) {
    const result = await runProbe({ runtime: { ...environment, [name]: 'wrong' } });
    assert.equal(result.exitCode, 1);
    assert.match(result.errors[0], /Runtime configuration mismatch/);
  }
});

test('rejects an unhealthy client', async () => {
  assert.equal((await runProbe({ health: 503 })).exitCode, 1);
});

test('rejects HTML without a runtime configuration script or bundle', async () => {
  for (const html of ['<script src="/static/js/main.js"></script>', '<script src="/runtime-config.js"></script>']) {
    assert.equal((await runProbe({ html })).exitCode, 1);
  }
});

test('rejects runtime configuration loaded after the application bundle', async () => {
  const result = await runProbe({
    html: '<script src="/static/js/main.js"></script><script src="/runtime-config.js"></script>'
  });
  assert.equal(result.exitCode, 1);
  assert.match(result.errors[0], /must precede/);
});

test('rejects an HTML fallback masquerading as a missing JavaScript asset', async () => {
  assert.equal((await runProbe({ bundleType: 'text/html' })).exitCode, 1);
});
