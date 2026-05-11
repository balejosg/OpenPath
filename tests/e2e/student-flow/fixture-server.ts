import http, { type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import { pathToFileURL } from 'node:url';

export interface StudentFixtureHosts {
  portal: string;
  cdnPortal: string;
  site: string;
  apiSite: string;
}

export interface StudentFixtureUrls {
  portalOk: string;
  portalSubdomainScript: string;
  siteOk: string;
  sitePrivate: string;
  siteIframePrivate: string;
  siteXhrPrivate: string;
  siteFetchPrivate: string;
  dnsDiscoverySpike: {
    origin: string;
    fetch: string;
    xhr: string;
    script: string;
    image: string;
    css: string;
    font: string;
  };
}

export interface StartedStudentFixtureServer {
  host: string;
  port: number;
  fixtures: StudentFixtureHosts;
  urls: StudentFixtureUrls;
  server: Server;
  close: () => Promise<void>;
}

export interface StudentFixtureServerOptions {
  host?: string;
  port?: number;
}

interface CliArgs {
  host?: string;
  port?: number;
}

const DEFAULT_HOST = '127.0.0.1';

function getStudentHostSuffix(): string {
  return (process.env.OPENPATH_STUDENT_HOST_SUFFIX ?? '127.0.0.1.sslip.io')
    .trim()
    .replace(/^\.+|\.+$/g, '');
}

export function getStudentFixtureHosts(): StudentFixtureHosts {
  const suffix = getStudentHostSuffix();
  return {
    portal: `portal.${suffix}`,
    cdnPortal: `cdn.portal.${suffix}`,
    site: `site.${suffix}`,
    apiSite: `api.site.${suffix}`,
  };
}

export function buildStudentFixtureUrls(
  port: number,
  fixtures = getStudentFixtureHosts()
): StudentFixtureUrls {
  const withPort = (hostname: string, path: string) => `http://${hostname}:${String(port)}${path}`;
  const suffix = getStudentHostSuffix();

  return {
    portalOk: withPort(fixtures.portal, '/ok'),
    portalSubdomainScript: withPort(fixtures.cdnPortal, '/asset.js'),
    siteOk: withPort(fixtures.site, '/ok'),
    sitePrivate: withPort(fixtures.site, '/private'),
    siteIframePrivate: withPort(fixtures.site, '/iframe/private'),
    siteXhrPrivate: withPort(fixtures.site, '/xhr/private.json'),
    siteFetchPrivate: withPort(fixtures.site, '/fetch/private.json'),
    dnsDiscoverySpike: {
      origin: withPort(fixtures.site, '/ok'),
      fetch: withPort(`api.dns-discovery-fetch.${suffix}`, '/fetch/private.json'),
      xhr: withPort(`api.dns-discovery-xhr.${suffix}`, '/xhr/private.json'),
      script: withPort(`cdn.dns-discovery-script.${suffix}`, '/asset.js'),
      image: withPort(`image.dns-discovery-image.${suffix}`, '/pixel.png'),
      css: withPort(`style.dns-discovery-css.${suffix}`, '/style.css'),
      font: withPort(`font.dns-discovery-font.${suffix}`, '/font.woff2'),
    },
  };
}

function getRequestHost(req: IncomingMessage): string {
  const hostHeader = req.headers.host ?? '';
  return hostHeader.split(':')[0]?.toLowerCase() ?? '';
}

function setHtmlHeaders(res: ServerResponse): void {
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
}

function setJsonHeaders(res: ServerResponse): void {
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
}

function setScriptHeaders(res: ServerResponse): void {
  res.setHeader('Content-Type', 'application/javascript; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
}

function setCssHeaders(res: ServerResponse): void {
  res.setHeader('Content-Type', 'text/css; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
}

function setImageHeaders(res: ServerResponse): void {
  res.setHeader('Content-Type', 'image/png');
  res.setHeader('Cache-Control', 'no-store');
}

function setFontHeaders(res: ServerResponse): void {
  res.setHeader('Content-Type', 'font/woff2');
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Access-Control-Allow-Origin', '*');
}

function notFound(res: ServerResponse): void {
  res.statusCode = 404;
  setHtmlHeaders(res);
  res.end('<!doctype html><title>Not Found</title><p>Not Found</p>');
}

function portalPageHtml(fixtures: StudentFixtureHosts): string {
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>OpenPath Portal Fixture</title>
  </head>
  <body>
    <main>
      <h1>Portal Fixture</h1>
      <p id="page-status">ok</p>
      <p id="subdomain-status">pending</p>
      <button id="rerun-subdomain-probe" type="button">Rerun subdomain probe</button>
    </main>
    <script>
      (() => {
        const statusNode = document.getElementById('subdomain-status');
        const setStatus = (value) => {
          if (statusNode) {
            statusNode.textContent = value;
          }
        };

        const buildAssetUrl = () => {
          const portSegment = window.location.port ? ':' + window.location.port : '';
          return window.location.protocol + '//${fixtures.cdnPortal}' + portSegment + '/asset.js?cache=' + Date.now();
        };

        const runSubdomainProbe = () => {
          setStatus('pending');
          const script = document.createElement('script');
          script.async = true;
          script.src = buildAssetUrl();
          script.onload = () => setStatus('ok');
          script.onerror = () => setStatus('blocked');
          document.body.appendChild(script);
        };

        window.runSubdomainProbe = runSubdomainProbe;

        const button = document.getElementById('rerun-subdomain-probe');
        if (button) {
          button.addEventListener('click', runSubdomainProbe);
        }

        runSubdomainProbe();
      })();
    </script>
  </body>
</html>`;
}

function sitePageHtml(): string {
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>OpenPath Site Fixture</title>
  </head>
  <body>
    <main>
      <h1>Site Fixture</h1>
      <p id="page-status">ok</p>
      <p id="subdomain-status">pending</p>
      <p id="iframe-status">pending</p>
      <p id="xhr-status">pending</p>
      <p id="fetch-status">pending</p>
      <button id="run-subdomain-probe" type="button">Run subdomain probe</button>
      <button id="run-iframe-probe" type="button">Run iframe probe</button>
      <button id="run-xhr-probe" type="button">Run XHR probe</button>
      <button id="run-fetch-probe" type="button">Run fetch probe</button>
    </main>
    <script>
      (() => {
        const setStatus = (id, value) => {
          const node = document.getElementById(id);
          if (node) {
            node.textContent = value;
          }
        };

        const buildPath = (path) => window.location.origin + path + '?cache=' + Date.now();

        const runSubdomainProbe = () => {
          setStatus('subdomain-status', 'pending');
          const existing = document.getElementById('subdomain-probe-script');
          if (existing) {
            existing.remove();
          }

          const script = document.createElement('script');
          script.id = 'subdomain-probe-script';
          script.async = true;
          script.src = window.location.protocol + '//cdn.' + window.location.hostname + (window.location.port ? ':' + window.location.port : '') + '/asset.js?cache=' + Date.now();
          const timeout = window.setTimeout(() => setStatus('subdomain-status', 'blocked'), 2500);
          script.onload = () => {
            window.clearTimeout(timeout);
            setStatus('subdomain-status', 'ok');
          };
          script.onerror = () => {
            window.clearTimeout(timeout);
            setStatus('subdomain-status', 'blocked');
          };
          document.body.appendChild(script);
        };

        const runIframeProbe = () => {
          setStatus('iframe-status', 'pending');
          const existing = document.getElementById('probe-iframe');
          if (existing) {
            existing.remove();
          }

          const iframe = document.createElement('iframe');
          iframe.id = 'probe-iframe';
          iframe.src = buildPath('/iframe/private');
          const timeout = window.setTimeout(() => setStatus('iframe-status', 'blocked'), 2500);
          iframe.onload = () => {
            window.clearTimeout(timeout);
            setStatus('iframe-status', 'ok');
          };
          iframe.onerror = () => {
            window.clearTimeout(timeout);
            setStatus('iframe-status', 'blocked');
          };
          document.body.appendChild(iframe);
        };

        const runXhrProbe = () => {
          setStatus('xhr-status', 'pending');
          const xhr = new XMLHttpRequest();
          const timeout = window.setTimeout(() => {
            xhr.abort();
            setStatus('xhr-status', 'blocked');
          }, 2500);
          xhr.open('GET', buildPath('/xhr/private.json'));
          xhr.onload = () => {
            window.clearTimeout(timeout);
            setStatus('xhr-status', xhr.status >= 200 && xhr.status < 300 ? 'ok' : 'blocked');
          };
          xhr.onerror = () => {
            window.clearTimeout(timeout);
            setStatus('xhr-status', 'blocked');
          };
          xhr.send();
        };

        const runFetchProbe = async () => {
          setStatus('fetch-status', 'pending');
          try {
            const response = await Promise.race([
              fetch(buildPath('/fetch/private.json')),
              new Promise((_, reject) => window.setTimeout(() => reject(new Error('timeout')), 2500)),
            ]);
            setStatus('fetch-status', response.ok ? 'ok' : 'blocked');
          } catch {
            setStatus('fetch-status', 'blocked');
          }
        };

        window.runSubdomainProbe = runSubdomainProbe;
        window.runIframeProbe = runIframeProbe;
        window.runXhrProbe = runXhrProbe;
        window.runFetchProbe = runFetchProbe;

        document.getElementById('run-subdomain-probe')?.addEventListener('click', runSubdomainProbe);
        document.getElementById('run-iframe-probe')?.addEventListener('click', runIframeProbe);
        document.getElementById('run-xhr-probe')?.addEventListener('click', runXhrProbe);
        document.getElementById('run-fetch-probe')?.addEventListener('click', runFetchProbe);
      })();
    </script>
  </body>
</html>`;
}

function privatePageHtml(label: string): string {
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>${label}</title>
  </head>
  <body>
    <main>
      <h1>${label}</h1>
      <p id="page-status">ok</p>
    </main>
  </body>
</html>`;
}

function sendJson(res: ServerResponse, payload: unknown): void {
  setJsonHeaders(res);
  res.end(JSON.stringify(payload));
}

function sendTransparentPixel(res: ServerResponse): void {
  setImageHeaders(res);
  res.end(
    Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=',
      'base64'
    )
  );
}

function routePortalHost(
  pathname: string,
  res: ServerResponse,
  fixtures: StudentFixtureHosts
): void {
  if (pathname === '/ok') {
    setHtmlHeaders(res);
    res.end(portalPageHtml(fixtures));
    return;
  }

  notFound(res);
}

function routeCdnHost(pathname: string, res: ServerResponse): void {
  if (pathname === '/asset.js') {
    setScriptHeaders(res);
    res.end('window.__openpathPortalAssetLoaded = true;');
    return;
  }

  notFound(res);
}

function routeSiteHost(pathname: string, res: ServerResponse): void {
  if (pathname === '/__preflight__') {
    res.statusCode = 204;
    setJsonHeaders(res);
    res.end();
    return;
  }

  if (pathname === '/ok') {
    setHtmlHeaders(res);
    res.end(sitePageHtml());
    return;
  }

  if (pathname === '/private') {
    setHtmlHeaders(res);
    res.end(privatePageHtml('Private Fixture'));
    return;
  }

  if (pathname === '/iframe/private') {
    setHtmlHeaders(res);
    res.end(privatePageHtml('Iframe Fixture'));
    return;
  }

  if (pathname === '/xhr/private.json') {
    sendJson(res, { status: 'ok', kind: 'xhr-private' });
    return;
  }

  if (pathname === '/fetch/private.json') {
    sendJson(res, { status: 'ok', kind: 'fetch-private' });
    return;
  }

  notFound(res);
}

function routeApiSiteHost(pathname: string, res: ServerResponse): void {
  if (pathname === '/__preflight__') {
    res.statusCode = 204;
    setJsonHeaders(res);
    res.end();
    return;
  }

  if (pathname === '/ok') {
    setHtmlHeaders(res);
    res.end(privatePageHtml('API Site Fixture'));
    return;
  }

  if (pathname === '/fetch/private.json' || pathname === '/xhr/private.json') {
    sendJson(res, { status: 'ok', kind: 'api-site-private' });
    return;
  }

  notFound(res);
}

function routeImageHost(pathname: string, res: ServerResponse): void {
  if (pathname === '/pixel.png') {
    sendTransparentPixel(res);
    return;
  }

  notFound(res);
}

function routeStyleHost(pathname: string, res: ServerResponse): void {
  if (pathname === '/style.css') {
    setCssHeaders(res);
    res.end('body { --openpath-style-probe: loaded; }');
    return;
  }

  notFound(res);
}

function routeFontHost(pathname: string, res: ServerResponse): void {
  if (pathname === '/font.woff2') {
    setFontHeaders(res);
    res.end(Buffer.from('d09GMgABAAAAAA==', 'base64'));
    return;
  }

  notFound(res);
}

export function createStudentFixtureRequestHandler(
  fixtures: StudentFixtureHosts = getStudentFixtureHosts()
): http.RequestListener {
  return (req, res) => {
    const host = getRequestHost(req);
    const pathname = new URL(req.url ?? '/', `http://${req.headers.host ?? fixtures.portal}`)
      .pathname;

    if (host === fixtures.portal) {
      routePortalHost(pathname, res, fixtures);
      return;
    }

    if (host === fixtures.cdnPortal) {
      routeCdnHost(pathname, res);
      return;
    }

    if (host === fixtures.site) {
      routeSiteHost(pathname, res);
      return;
    }

    if (host === fixtures.apiSite) {
      routeApiSiteHost(pathname, res);
      return;
    }

    if (host.endsWith(`.${getStudentHostSuffix()}`)) {
      if (host.startsWith('cdn.')) {
        routeCdnHost(pathname, res);
        return;
      }

      if (host.startsWith('api.')) {
        routeApiSiteHost(pathname, res);
        return;
      }

      if (host.startsWith('image.')) {
        routeImageHost(pathname, res);
        return;
      }

      if (host.startsWith('style.')) {
        routeStyleHost(pathname, res);
        return;
      }

      if (host.startsWith('font.')) {
        routeFontHost(pathname, res);
        return;
      }

      routeSiteHost(pathname, res);
      return;
    }

    notFound(res);
  };
}

export async function startStudentFixtureServer(
  options: StudentFixtureServerOptions = {}
): Promise<StartedStudentFixtureServer> {
  const fixtures = getStudentFixtureHosts();
  const host = options.host ?? DEFAULT_HOST;
  const server = http.createServer(createStudentFixtureRequestHandler(fixtures));

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(options.port ?? 0, host, () => {
      server.off('error', reject);
      resolve();
    });
  });

  const address = server.address();
  if (address === null || typeof address === 'string') {
    throw new Error('Could not resolve fixture server address');
  }

  const port = address.port;

  return {
    host,
    port,
    fixtures,
    urls: buildStudentFixtureUrls(port, fixtures),
    server,
    close: async () => {
      await new Promise<void>((resolve, reject) => {
        server.close((error) => {
          if (error) {
            reject(error);
            return;
          }
          resolve();
        });
      });
    },
  };
}

function parseCliArgs(argv: string[]): CliArgs {
  const args: CliArgs = {};

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === '--host') {
      const host = argv[index + 1];
      if (host !== undefined && host !== '') {
        args.host = host;
      }
      index += 1;
      continue;
    }

    if (token === '--port') {
      const rawPort = argv[index + 1];
      index += 1;
      if (rawPort !== undefined && rawPort !== '') {
        const parsed = Number.parseInt(rawPort, 10);
        if (Number.isFinite(parsed)) {
          args.port = parsed;
        }
      }
    }
  }

  return args;
}

async function runCli(): Promise<void> {
  const args = parseCliArgs(process.argv.slice(2));
  const started = await startStudentFixtureServer({
    ...(args.host !== undefined ? { host: args.host } : {}),
    ...(args.port !== undefined ? { port: args.port } : {}),
  });

  process.stdout.write(
    `${JSON.stringify(
      {
        host: started.host,
        port: started.port,
        fixtures: started.fixtures,
        urls: started.urls,
      },
      null,
      2
    )}\n`
  );

  const shutdown = async (): Promise<void> => {
    await started.close();
    process.exit(0);
  };

  process.on('SIGINT', () => {
    void shutdown();
  });

  process.on('SIGTERM', () => {
    void shutdown();
  });
}

const isMainModule = import.meta.url === pathToFileURL(process.argv[1] ?? '').href;

if (isMainModule) {
  runCli().catch((error: unknown) => {
    const message = error instanceof Error ? (error.stack ?? error.message) : String(error);
    process.stderr.write(`${message}\n`);
    process.exit(1);
  });
}
