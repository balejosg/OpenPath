// Phase 5.3 P2: real-browser check of the first-visit fixture page logic.
//
// Loads the fixture in floor mode with every fixture hostname routed back to
// the local fixture (the original Host header is preserved, so the server's
// virtual hosting still applies) and requires the three waves plus the web
// font. Playwright Firefox is used because the lane's target browser is
// Firefox; there is no Firefox job in CI, so this is the documented mandatory
// local verification for the lane (docs/windows-first-visit-lab.md).
//
// Usage:
//   node tests/e2e/ci/first-visit/test_fixture_browser.mjs [--fixture-path PATH] [--timeout 30]
//
// Exit 0 = all waves true, exit 1 = any missing (prints the observed flags).

import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const { firefox } = require('playwright');

const here = path.dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  const options = { fixturePath: path.join(here, 'fixture_server.py'), timeout: 30 };
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--fixture-path') {
      options.fixturePath = argv[index + 1];
      index += 1;
    } else if (argv[index] === '--timeout') {
      options.timeout = Number(argv[index + 1]);
      index += 1;
    }
  }
  return options;
}

function requestFixture(port, hostHeader, method, pathName, body) {
  return new Promise((resolve, reject) => {
    const request = http.request(
      {
        host: '127.0.0.1',
        port,
        method,
        path: pathName,
        headers: {
          host: hostHeader,
          'accept-encoding': 'identity',
          'content-type': 'application/json',
        },
      },
      (response) => {
        const chunks = [];
        response.on('data', (chunk) => chunks.push(chunk));
        response.on('end', () =>
          resolve({
            status: response.statusCode,
            headers: response.headers,
            body: Buffer.concat(chunks),
          })
        );
      }
    );
    request.on('error', reject);
    if (body) request.write(body);
    request.end();
  });
}

async function waitForServer(port, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const response = await requestFixture(port, '127.0.0.1', 'GET', '/plan.json', null);
      if (response.status === 200) return JSON.parse(response.body.toString('utf8'));
    } catch {
      // not up yet
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error('fixture server did not start');
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const port = 24000 + Math.floor(Math.random() * 1000);
  const stateDir = `/tmp/opencode/phase53-fixture-${Date.now()}`;
  const fixtureSource = readFileSync(options.fixturePath, 'utf8');
  const args = [
    options.fixturePath,
    '--state-dir',
    stateDir,
    '--port',
    String(port),
    '--listen',
    '127.0.0.1',
    '--run-id',
    'browser-test',
    '--ip',
    '127.0.0.1',
  ];
  // Older fixtures (pre-Phase 5.3 B4) have no --scenario/floor support.
  if (fixtureSource.includes('floorMode')) args.push('--scenario', 'floor');
  const server = spawn('python3', args, { stdio: ['ignore', 'pipe', 'pipe'] });
  let serverOutput = '';
  server.stdout.on('data', (chunk) => (serverOutput += chunk.toString()));
  server.stderr.on('data', (chunk) => (serverOutput += chunk.toString()));

  let browser = null;
  const result = { fixture: options.fixturePath, waves: null, marks: null, error: '' };
  try {
    const plan = await waitForServer(port, 15000);
    browser = await firefox.launch({ headless: true });
    const context = await browser.newContext();
    await context.route('**/*', async (route) => {
      const request = route.request();
      const url = new URL(request.url());
      if (url.hostname === '127.0.0.1') {
        await route.continue();
        return;
      }
      const upstream = await requestFixture(
        port,
        url.host,
        request.method(),
        url.pathname + url.search,
        request.postDataBuffer()
      );
      await route.fulfill({
        status: upstream.status,
        headers: upstream.headers,
        body: upstream.body,
      });
    });
    const page = await context.newPage();
    const anchorHost = plan.anchors.a1.host;
    await page.goto(`http://${anchorHost}/`, {
      waitUntil: 'domcontentloaded',
      timeout: options.timeout * 1000,
    });
    try {
      await page.waitForFunction(
        () => window.__firstVisit && window.__firstVisit.waves.apiPainted === true,
        null,
        { timeout: options.timeout * 1000 }
      );
    } catch {
      // record the observed flags below
    }
    await page.waitForTimeout(1500);
    const observed = await page.evaluate(() => {
      const px = document.getElementById('px');
      return {
        waves: window.__firstVisit ? { ...window.__firstVisit.waves } : null,
        marks: window.__firstVisit ? { ...window.__firstVisit.marks } : null,
        image: px ? { complete: px.complete, naturalWidth: px.naturalWidth, src: px.src } : null,
      };
    });
    result.waves = observed.waves;
    result.marks = observed.marks;
    result.image = observed.image;
  } catch (error) {
    result.error = String(error);
  } finally {
    if (browser) await browser.close();
    server.kill('SIGTERM');
  }

  const required = [
    'cssApplied',
    'coreExecuted',
    'imageLoaded',
    'deferredExecuted',
    'apiPainted',
    'fontLoaded',
  ];
  const missing = result.waves ? required.filter((key) => result.waves[key] !== true) : required;
  const passed = missing.length === 0 && !result.error;
  result.missing = missing;
  result.passed = passed;
  console.log(JSON.stringify(result, null, 2));
  if (!passed) {
    console.log('server output:', serverOutput.slice(-1500));
    process.exit(1);
  }
  process.exit(0);
}

main().catch((error) => {
  console.error(error);
  process.exit(2);
});
