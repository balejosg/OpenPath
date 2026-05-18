import { describe, test } from 'node:test';
import assert from 'node:assert';
import { extractTabHostname } from '../src/lib/popup-state.js';

function formatErrorTypes(errors: string[]): string {
  const errorLabels: Record<string, string> = {
    NS_ERROR_UNKNOWN_HOST: 'DNS bloqueado',
    NS_ERROR_CONNECTION_REFUSED: 'Conexión rechazada',
    NS_ERROR_NET_TIMEOUT: 'Timeout de red',
    NS_ERROR_PROXY_CONNECTION_REFUSED: 'Proxy bloqueado',
  };

  return errors.map((error) => errorLabels[error] ?? error).join(', ');
}

function escapeHtml(text: string): string {
  const escapeMap: Record<string, string> = {
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;',
  };
  return text.replace(/[&<>"']/g, (char) => escapeMap[char] ?? char);
}

void describe('popup formatting and hostname extraction', () => {
  void test('formats known and unknown network errors for display', () => {
    assert.strictEqual(formatErrorTypes(['NS_ERROR_UNKNOWN_HOST']), 'DNS bloqueado');
    assert.strictEqual(formatErrorTypes(['NS_ERROR_CONNECTION_REFUSED']), 'Conexión rechazada');
    assert.strictEqual(formatErrorTypes(['NS_ERROR_NET_TIMEOUT']), 'Timeout de red');
    assert.strictEqual(formatErrorTypes(['NS_ERROR_PROXY_CONNECTION_REFUSED']), 'Proxy bloqueado');
    assert.strictEqual(
      formatErrorTypes(['NS_ERROR_UNKNOWN_HOST', 'CUSTOM_ERROR']),
      'DNS bloqueado, CUSTOM_ERROR'
    );
    assert.strictEqual(formatErrorTypes([]), '');
  });

  void test('extracts tab hostnames from browser-facing URLs', () => {
    assert.strictEqual(extractTabHostname('https://www.example.com/page'), 'www.example.com');
    assert.strictEqual(extractTabHostname('http://example.com'), 'example.com');
    assert.strictEqual(extractTabHostname(undefined), 'Unknown');
    assert.strictEqual(extractTabHostname(''), 'Unknown');
    assert.strictEqual(extractTabHostname('not-a-valid-url'), 'Local page');

    const aboutResult = extractTabHostname('about:blank');
    assert.ok(aboutResult === '' || aboutResult === 'Local page');

    assert.strictEqual(extractTabHostname('http://localhost:3000/api'), 'localhost');
    assert.strictEqual(
      extractTabHostname('https://search.example.com?q=test&page=1'),
      'search.example.com'
    );
    assert.strictEqual(
      extractTabHostname('https://docs.example.com#section-1'),
      'docs.example.com'
    );
    assert.strictEqual(extractTabHostname('http://192.168.1.1/admin'), '192.168.1.1');
    assert.strictEqual(extractTabHostname('file:///home/user/doc.html'), '');
    assert.strictEqual(extractTabHostname('moz-extension://abc123/popup.html'), 'abc123');
    assert.strictEqual(extractTabHostname('chrome-extension://abc123/popup.html'), 'abc123');
  });

  void test('escapes HTML and preserves privacy-sensitive URL parsing rules', () => {
    assert.strictEqual(escapeHtml('<script>'), '&lt;script&gt;');
    assert.strictEqual(escapeHtml('a > b'), 'a &gt; b');
    assert.strictEqual(escapeHtml('a & b'), 'a &amp; b');
    assert.strictEqual(escapeHtml('say "hello"'), 'say &quot;hello&quot;');
    assert.strictEqual(escapeHtml("it's"), 'it&#39;s');
    assert.strictEqual(
      escapeHtml('<a href="test">Link</a>'),
      '&lt;a href=&quot;test&quot;&gt;Link&lt;/a&gt;'
    );
    assert.strictEqual(escapeHtml('Hola mundo 日本語'), 'Hola mundo 日本語');
    assert.strictEqual(
      escapeHtml('<script>alert("XSS")</script>'),
      '&lt;script&gt;alert(&quot;XSS&quot;)&lt;/script&gt;'
    );
    assert.strictEqual(escapeHtml('&amp;lt;'), '&amp;amp;lt;');

    const longEscaped = escapeHtml('<script>'.repeat(1000));
    assert.ok(!longEscaped.includes('<script>'));
    assert.ok(longEscaped.length > '<script>'.repeat(1000).length);

    const sensitiveUrl = 'https://example.com/secret/path/to/resource?query=sensitive';
    const parsed = extractTabHostname(sensitiveUrl);
    assert.strictEqual(parsed, 'example.com');
    assert.ok(!parsed.includes('secret'));
    assert.ok(!parsed.includes('query'));

    const credentialUrl = new URL('/path', 'https://example.com');
    credentialUrl.username = 'user';
    credentialUrl.password = 'redacted';
    const credentialHost = extractTabHostname(credentialUrl.toString());
    assert.strictEqual(credentialHost, 'example.com');
    assert.ok(!credentialHost.includes('user'));
    assert.ok(!credentialHost.includes('password'));

    const localhostUrl = extractTabHostname('http://localhost:8080/sensitive-api');
    assert.strictEqual(localhostUrl, 'localhost');
    assert.ok(!localhostUrl.includes('8080'));
    assert.ok(!localhostUrl.includes('sensitive'));
  });

  void test('covers integrated display scenarios', () => {
    const errors = [
      'NS_ERROR_UNKNOWN_HOST',
      'NS_ERROR_CONNECTION_REFUSED',
      'NS_ERROR_NET_TIMEOUT',
      'NS_ERROR_PROXY_CONNECTION_REFUSED',
    ];

    const result = formatErrorTypes(errors);
    ['DNS bloqueado', 'Conexión rechazada', 'Timeout de red', 'Proxy bloqueado'].forEach(
      (label) => {
        assert.ok(result.includes(label));
      }
    );

    const originHost = extractTabHostname('https://main-site.com/article');
    assert.strictEqual(originHost, 'main-site.com');
    assert.ok(escapeHtml('domain<script>alert(1)</script>.com').includes('&lt;script&gt;'));
  });
});
