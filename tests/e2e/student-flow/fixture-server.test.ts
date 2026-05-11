import { after, before, describe, test } from 'node:test';
import assert from 'node:assert';
import http from 'node:http';

import { startStudentFixtureServer, type StartedStudentFixtureServer } from './fixture-server.js';

interface HttpResult {
  statusCode: number;
  headers: http.IncomingHttpHeaders;
  body: string;
}

function requestFixture(params: {
  server: StartedStudentFixtureServer;
  host: string;
  path: string;
}): Promise<HttpResult> {
  return new Promise((resolve, reject) => {
    const request = http.request(
      {
        host: params.server.host,
        port: params.server.port,
        path: params.path,
        method: 'GET',
        headers: {
          Host: `${params.host}:${String(params.server.port)}`,
        },
      },
      (response) => {
        const chunks: Buffer[] = [];
        response.on('data', (chunk: Buffer) => {
          chunks.push(chunk);
        });
        response.on('end', () => {
          resolve({
            statusCode: response.statusCode ?? 0,
            headers: response.headers,
            body: Buffer.concat(chunks).toString('utf8'),
          });
        });
      }
    );

    request.on('error', reject);
    request.end();
  });
}

let fixtureServer: StartedStudentFixtureServer;

await describe('student fixture server', async () => {
  before(async () => {
    fixtureServer = await startStudentFixtureServer();
  });

  after(async () => {
    await fixtureServer.close();
  });

  await test('serves the portal page with subdomain probe markers', async () => {
    const response = await requestFixture({
      server: fixtureServer,
      host: fixtureServer.fixtures.portal,
      path: '/ok',
    });

    assert.strictEqual(response.statusCode, 200);
    assert.match(response.headers['content-type'] ?? '', /text\/html/);
    assert.match(response.body, /id="page-status">ok</);
    assert.match(response.body, /id="subdomain-status">pending</);
    assert.match(response.body, /runSubdomainProbe/);
    assert.match(response.body, /cdn\.portal\.127\.0\.0\.1\.sslip\.io/);
  });

  await test('serves the portal subdomain probe against the configured fixture suffix', async () => {
    const previousSuffix = process.env.OPENPATH_STUDENT_HOST_SUFFIX;
    let configuredServer: StartedStudentFixtureServer | undefined;
    process.env.OPENPATH_STUDENT_HOST_SUFFIX = '192-168-56-103.sslip.io';

    try {
      configuredServer = await startStudentFixtureServer();
      const response = await requestFixture({
        server: configuredServer,
        host: configuredServer.fixtures.portal,
        path: '/ok',
      });

      assert.strictEqual(response.statusCode, 200);
      assert.match(response.body, /cdn\.portal\.192-168-56-103\.sslip\.io/);
      assert.doesNotMatch(response.body, /cdn\.portal\.127\.0\.0\.1\.sslip\.io/);
    } finally {
      await configuredServer?.close();
      if (previousSuffix === undefined) {
        delete process.env.OPENPATH_STUDENT_HOST_SUFFIX;
      } else {
        process.env.OPENPATH_STUDENT_HOST_SUFFIX = previousSuffix;
      }
    }
  });

  await test('serves the CDN asset endpoint for subdomain probes', async () => {
    const response = await requestFixture({
      server: fixtureServer,
      host: fixtureServer.fixtures.cdnPortal,
      path: '/asset.js',
    });

    assert.strictEqual(response.statusCode, 200);
    assert.match(response.headers['content-type'] ?? '', /application\/javascript/);
    assert.match(response.body, /__openpathPortalAssetLoaded/);
  });

  await test('serves the site page with iframe, xhr, and fetch probes', async () => {
    const response = await requestFixture({
      server: fixtureServer,
      host: fixtureServer.fixtures.site,
      path: '/ok',
    });

    assert.strictEqual(response.statusCode, 200);
    assert.match(response.body, /id="page-status">ok</);
    assert.match(response.body, /id="subdomain-status">pending</);
    assert.match(response.body, /id="iframe-status">pending</);
    assert.match(response.body, /id="xhr-status">pending</);
    assert.match(response.body, /id="fetch-status">pending</);
    assert.match(response.body, /runSubdomainProbe/);
    assert.match(response.body, /runIframeProbe/);
    assert.match(response.body, /runXhrProbe/);
    assert.match(response.body, /runFetchProbe/);
  });

  await test('serves private site routes and JSON probes', async () => {
    const privateResponse = await requestFixture({
      server: fixtureServer,
      host: fixtureServer.fixtures.site,
      path: '/private',
    });
    assert.strictEqual(privateResponse.statusCode, 200);
    assert.match(privateResponse.body, /Private Fixture/);

    const iframeResponse = await requestFixture({
      server: fixtureServer,
      host: fixtureServer.fixtures.site,
      path: '/iframe/private',
    });
    assert.strictEqual(iframeResponse.statusCode, 200);
    assert.match(iframeResponse.body, /Iframe Fixture/);

    const xhrResponse = await requestFixture({
      server: fixtureServer,
      host: fixtureServer.fixtures.site,
      path: '/xhr/private.json',
    });
    assert.strictEqual(xhrResponse.statusCode, 200);
    assert.match(xhrResponse.headers['content-type'] ?? '', /application\/json/);
    assert.deepStrictEqual(JSON.parse(xhrResponse.body), { status: 'ok', kind: 'xhr-private' });

    const fetchResponse = await requestFixture({
      server: fixtureServer,
      host: fixtureServer.fixtures.site,
      path: '/fetch/private.json',
    });
    assert.strictEqual(fetchResponse.statusCode, 200);
    assert.deepStrictEqual(JSON.parse(fetchResponse.body), { status: 'ok', kind: 'fetch-private' });
  });

  await test('serves host-routed image, stylesheet, and font probes', async () => {
    const suffix = fixtureServer.fixtures.site.replace(/^site\./, '');

    const imageResponse = await requestFixture({
      server: fixtureServer,
      host: `image.ajax-dependency.${suffix}`,
      path: '/pixel.png',
    });
    assert.strictEqual(imageResponse.statusCode, 200);
    assert.match(imageResponse.headers['content-type'] ?? '', /image\/png/);

    const stylesheetResponse = await requestFixture({
      server: fixtureServer,
      host: `style.ajax-dependency.${suffix}`,
      path: '/style.css',
    });
    assert.strictEqual(stylesheetResponse.statusCode, 200);
    assert.match(stylesheetResponse.headers['content-type'] ?? '', /text\/css/);
    assert.match(stylesheetResponse.body, /--openpath-style-probe/);

    const fontResponse = await requestFixture({
      server: fixtureServer,
      host: `font.ajax-dependency.${suffix}`,
      path: '/font.woff2',
    });
    assert.strictEqual(fontResponse.statusCode, 200);
    assert.match(fontResponse.headers['content-type'] ?? '', /font\/woff2/);
  });

  await test('exposes DNS discovery spike URLs with approved site origin and typed dependencies', () => {
    const urls = fixtureServer.urls.dnsDiscoverySpike;

    assert.strictEqual(new URL(urls.origin).hostname, fixtureServer.fixtures.site);

    const expectedHosts = {
      fetch: 'api.dns-discovery-fetch.127.0.0.1.sslip.io',
      xhr: 'api.dns-discovery-xhr.127.0.0.1.sslip.io',
      script: 'cdn.dns-discovery-script.127.0.0.1.sslip.io',
      image: 'image.dns-discovery-image.127.0.0.1.sslip.io',
      css: 'style.dns-discovery-css.127.0.0.1.sslip.io',
      font: 'font.dns-discovery-font.127.0.0.1.sslip.io',
    };

    for (const [type, host] of Object.entries(expectedHosts)) {
      assert.strictEqual(new URL(urls[type as keyof typeof expectedHosts]).hostname, host);
      assert.notStrictEqual(host, fixtureServer.fixtures.site);
      assert.notStrictEqual(host, fixtureServer.fixtures.apiSite);
    }
  });

  await test('returns host-specific 404s for unknown routes or hosts', async () => {
    const unknownRoute = await requestFixture({
      server: fixtureServer,
      host: fixtureServer.fixtures.portal,
      path: '/missing',
    });
    assert.strictEqual(unknownRoute.statusCode, 404);

    const unknownHost = await requestFixture({
      server: fixtureServer,
      host: 'unknown.invalid.test',
      path: '/ok',
    });
    assert.strictEqual(unknownHost.statusCode, 404);
  });
});
