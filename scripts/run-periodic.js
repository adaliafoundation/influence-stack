const { spawn } = require('node:child_process');

const [intervalValue, script] = process.argv.slice(2);
const intervalSeconds = Number(intervalValue);
if (!script || !Number.isFinite(intervalSeconds) || intervalSeconds <= 0
  || intervalSeconds * 1000 > 2147483647) {
  console.error('Usage: node run-periodic.js <positive interval seconds> <script>');
  process.exit(1);
}

let child;
let timer;
let stopping = false;

function run() {
  console.log(`Starting periodic job: ${script}`);
  child = spawn(process.execPath, [script], { stdio: 'inherit' });
  child.on('error', error => console.error(`Unable to start ${script}: ${error.message}`));
  child.on('close', (code, signal) => {
    child = undefined;
    if (stopping) {
      process.exit(0);
    }
    console.log(`Periodic job finished: ${script}, code=${code}, signal=${signal}; next run in ${intervalSeconds}s`);
    timer = setTimeout(run, intervalSeconds * 1000);
  });
}

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    stopping = true;
    clearTimeout(timer);
    if (child) child.kill(signal);
    else process.exit(0);
  });
}

run();
