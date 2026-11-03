import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import {
  PUBLIC_IP_LITERAL_REASON,
  evaluatePublicIpLiteral,
  isPublicIpLiteralHost,
} from '../src/lib/background-ip-literal-rules.js';

const EXTENSION_ORIGIN = 'moz-extension://unit-test/';

function randomInt(min: number, max: number): number {
  return min + Math.floor(Math.random() * (max - min + 1));
}

function octet(min: number, max: number): string {
  return String(randomInt(min, max));
}

/** A random IPv4 address in 11.0.0.0-99.255.255.255, which holds no non-public range. */
function randomPublicIpv4(): string {
  return [randomInt(11, 99), randomInt(0, 255), randomInt(0, 255), randomInt(1, 254)].join('.');
}

/** A random global-unicast IPv6 address (2000::/3, outside fc00::/7 and fe80::/10). */
function randomPublicIpv6(): string {
  const hex = (): string => randomInt(0, 0xffff).toString(16);
  return [
    randomInt(0x2001, 0x3fff).toString(16),
    hex(),
    hex(),
    hex(),
    hex(),
    hex(),
    hex(),
    hex(),
  ].join(':');
}

void describe('Firefox public IP-literal blocking', () => {
  void test('blocks main_frame to a random public IPv4 literal', () => {
    const ip = randomPublicIpv4();
    const outcome = evaluatePublicIpLiteral(
      { type: 'main_frame', url: `http://${ip}/index.html` },
      { extensionOrigin: EXTENSION_ORIGIN }
    );

    assert.ok(outcome, ip);
    assert.equal(outcome.reason, `${PUBLIC_IP_LITERAL_REASON}:${ip}`);
    assert.equal(outcome.cancel, undefined);
    const redirect = new URL(outcome.redirectUrl ?? '');
    assert.equal(redirect.pathname, '/blocked/blocked.html');
    assert.equal(redirect.searchParams.get('domain'), ip);
    assert.equal(redirect.searchParams.get('error'), outcome.reason);
  });

  void test('blocks a bracketed public IPv6 literal', () => {
    const ip = randomPublicIpv6();
    const outcome = evaluatePublicIpLiteral(
      { type: 'main_frame', url: `https://[${ip}]:8443/` },
      { extensionOrigin: EXTENSION_ORIGIN }
    );

    assert.ok(outcome, ip);
    assert.match(outcome.redirectUrl ?? '', /\/blocked\/blocked\.html/);
    assert.equal(isPublicIpLiteralHost(`[${ip}]`), true);
    assert.equal(isPublicIpLiteralHost(ip), true);
  });

  void test('blocks public literals written in non-dotted IPv4 forms', () => {
    // The URL parser normalizes hex/decimal IPv4 forms; 0x0b000001 is 11.0.0.1.
    const outcome = evaluatePublicIpLiteral({ type: 'main_frame', url: 'http://0x0b000001/' });
    assert.ok(outcome);
    assert.equal(outcome.cancel, true);
  });

  void test('allows RFC1918, CGNAT, link-local and loopback literals', () => {
    const nonPublic = [
      `10.${octet(0, 255)}.${octet(0, 255)}.${octet(1, 254)}`,
      `172.${octet(16, 31)}.${octet(0, 255)}.${octet(1, 254)}`,
      `192.168.${octet(0, 255)}.${octet(1, 254)}`,
      `100.${octet(64, 127)}.${octet(0, 255)}.${octet(1, 254)}`,
      `127.${octet(0, 255)}.${octet(0, 255)}.${octet(1, 254)}`,
      `169.254.${octet(0, 255)}.${octet(1, 254)}`,
      `0.${octet(0, 255)}.${octet(0, 255)}.${octet(0, 255)}`,
      '[::1]',
      '[::]',
      `[fd${randomInt(0, 255).toString(16).padStart(2, '0')}::${randomInt(1, 0xffff).toString(16)}]`,
      `[fc00::${randomInt(1, 0xffff).toString(16)}]`,
      `[fe80::${randomInt(1, 0xffff).toString(16)}]`,
      '[::ffff:192.168.1.1]',
    ];

    for (const host of nonPublic) {
      const url = `http://${host}/`;
      assert.equal(
        evaluatePublicIpLiteral({ type: 'main_frame', url }, { extensionOrigin: EXTENSION_ORIGIN }),
        null,
        url
      );
    }
    // Boundaries just outside the private blocks are public.
    assert.equal(isPublicIpLiteralHost('172.32.0.1'), true);
    assert.equal(isPublicIpLiteralHost('100.128.0.1'), true);
    assert.equal(isPublicIpLiteralHost('[::ffff:b00:1]'), true);
    // Dotted-tail and full-length IPv6 forms when called without URL normalization.
    assert.equal(isPublicIpLiteralHost('::ffff:10.1.2.3'), false);
    assert.equal(isPublicIpLiteralHost('64:ff9b::11.0.0.1'), true);
    assert.equal(isPublicIpLiteralHost('2a01:1:2:3:4:5:11.0.0.1'), true);
    assert.equal(isPublicIpLiteralHost('2a01:1:2:3:4:5:6:7'), true);
  });

  void test('ignores normal hostnames and hostnames that merely contain digits', () => {
    const hosts = [
      'example.test',
      `${randomPublicIpv4()}.example.test`,
      `host${octet(1, 999)}.example.test`,
      '',
      '1.2.3',
      '1.2.3.256',
      '[not:an:ip]',
      '[1::2::3]',
      '2a01:1:2:3:4:5:6',
      '1:2:3:4::5:6:7:8',
      '2a01::1.2.3',
    ];
    for (const host of hosts) {
      assert.equal(isPublicIpLiteralHost(host), false, host);
    }
    assert.equal(
      evaluatePublicIpLiteral({
        type: 'main_frame',
        url: `https://${randomPublicIpv4()}.example.test/`,
      }),
      null
    );
    assert.equal(evaluatePublicIpLiteral({ type: 'main_frame', url: 'not a url' }), null);
    assert.equal(
      evaluatePublicIpLiteral({
        type: 'main_frame',
        url: `${EXTENSION_ORIGIN}blocked/blocked.html`,
      }),
      null
    );
  });

  void test('cancels non-main_frame subresources to public literals', () => {
    const ip = randomPublicIpv4();
    assert.deepEqual(
      evaluatePublicIpLiteral(
        { type: 'xmlhttprequest', url: `https://${ip}/api` },
        { extensionOrigin: EXTENSION_ORIGIN }
      ),
      { cancel: true, reason: `${PUBLIC_IP_LITERAL_REASON}:${ip}` }
    );
  });
});
