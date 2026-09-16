// Run through stdin in the temporary client container; no host ports are needed.
const assert = require('node:assert/strict');
const vm = require('node:vm');

const origin = 'http://127.0.0.1:3000';
const headers = {
  'x-forwarded-proto': 'https',
  'user-agent': 'Mozilla/5.0 Chrome/130.0.0.0 Safari/537.36'
};

async function request(path) {
  return fetch(new URL(path, origin), {
    headers,
    redirect: 'error',
    signal: AbortSignal.timeout(10_000)
  });
}

async function checkClientImage() {
  assert.equal((await request('/healthz')).status, 204, 'Client health endpoint');
  const runtime = await request('/runtime-config.js');
  assert.equal(runtime.status, 200, 'Runtime configuration status');
  assert.match(runtime.headers.get('content-type') || '', /javascript/, 'Runtime configuration type');
  assert.match(runtime.headers.get('cache-control') || '', /no-store/, 'Runtime configuration caching');
  const context = { window: {} };
  vm.runInNewContext(await runtime.text(), context, { timeout: 1000 });
  const config = context.window.INFLUENCE_RUNTIME_CONFIG;
  assert.ok(config, 'Client must expose its public runtime configuration');
  for (const name of [
    'REACT_APP_CONFIG_ENV',
    'REACT_APP_API_INFLUENCE',
    'REACT_APP_STARKNET_PROVIDER',
    'REACT_APP_ETHEREUM_PROVIDER',
    'REACT_APP_API_IPFS',
    'REACT_APP_API_AVNU'
  ]) {
    assert.ok(process.env[name], `Missing configured ${name}`);
    assert.equal(config[name], process.env[name], `Runtime configuration mismatch: ${name}`);
  }

  const page = await request('/index.html');
  assert.equal(page.status, 200, 'Client HTML status');
  assert.match(page.headers.get('content-type') || '', /text\/html/, 'Client HTML type');
  const html = await page.text();
  const scripts = [...html.matchAll(/<script\b[^>]*\bsrc=["']([^"']+)["'][^>]*>/gi)]
    .map((match) => new URL(match[1], origin));
  const runtimeIndex = scripts.findIndex((url) => url.origin === origin && url.pathname === '/runtime-config.js');
  const bundles = scripts.filter((url) => url.origin === origin && url.pathname.startsWith('/static/js/'));
  assert.ok(runtimeIndex >= 0, 'HTML must load runtime configuration');
  assert.ok(bundles.length > 0, 'HTML must load a built JavaScript bundle');
  for (const url of bundles) {
    assert.ok(scripts.indexOf(url) > runtimeIndex, 'Runtime configuration must precede the application bundle');
    const bundle = await request(url);
    assert.equal(bundle.status, 200, `Bundle status: ${url.pathname}`);
    assert.match(bundle.headers.get('content-type') || '', /javascript/, `Bundle type: ${url.pathname}`);
    assert.ok((await bundle.arrayBuffer()).byteLength > 0, `Empty bundle: ${url.pathname}`);
  }
  console.log('Client health, runtime configuration, HTML, and JavaScript assets passed');
}

checkClientImage().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
