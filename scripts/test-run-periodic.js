const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { mkdtempSync, writeFileSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const { once } = require('node:events');

test('delays failed runs without overlap and forwards shutdown to the active job', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'periodic-test-'));
  const fixture = join(directory, 'job.js');
  writeFileSync(fixture, `
    console.log('JOB_START ' + Date.now());
    process.on('SIGTERM', () => { console.log('JOB_STOP'); process.exit(0); });
    setTimeout(() => { console.log('JOB_END ' + Date.now()); process.exit(1); }, 150);
  `);
  const runner = spawn(process.execPath, [join(__dirname, 'run-periodic.js'), '0.1', fixture]);
  const closed = once(runner, 'close');
  let output = '';
  let terminated = false;
  const timeout = setTimeout(() => runner.kill('SIGKILL'), 5000);
  runner.stdout.on('data', data => {
    output += data;
    if (!terminated && (output.match(/JOB_START/g) || []).length === 2) {
      terminated = true;
      runner.kill('SIGTERM');
    }
  });
  try {
    const [code, signal] = await closed;
    assert.equal(code, 0, output);
    assert.equal(signal, null);
    assert.match(output, /code=1/);
    assert.match(output, /JOB_STOP/);
    const starts = [...output.matchAll(/JOB_START (\d+)/g)].map(match => Number(match[1]));
    const ends = [...output.matchAll(/JOB_END (\d+)/g)].map(match => Number(match[1]));
    assert.equal(starts.length, 2);
    assert.equal(ends.length, 1);
    assert(starts[1] - ends[0] >= 100, output);
  } finally {
    clearTimeout(timeout);
    runner.kill('SIGKILL');
    rmSync(directory, { recursive: true, force: true });
  }
});

test('rejects a zero interval instead of looping', async () => {
  const runner = spawn(process.execPath, [join(__dirname, 'run-periodic.js'), '0', 'unused.js']);
  const [code] = await once(runner, 'close');
  assert.equal(code, 1);
});
