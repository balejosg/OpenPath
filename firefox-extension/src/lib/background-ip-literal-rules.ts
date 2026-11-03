import { buildBlockedScreenRedirectUrl, extractHostname, isExtensionUrl } from './path-blocking.js';

/**
 * Navigations to public IP literals skip DNS, so the DNS whitelist never sees
 * them. The extension cancels them; private/LAN literals stay reachable so
 * captive portals and local gateways keep working.
 */
export const PUBLIC_IP_LITERAL_REASON = 'PUBLIC_IP_LITERAL_POLICY';

export interface PublicIpLiteralRequest {
  type?: string;
  url: string;
  originUrl?: string;
  documentUrl?: string;
}

export interface PublicIpLiteralOutcome {
  cancel?: boolean;
  redirectUrl?: string;
  reason: string;
}

const IPV4_PATTERN = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;

function parseIpv4(host: string): number[] | null {
  const match = IPV4_PATTERN.exec(host);
  if (!match) {
    return null;
  }
  const octets = match.slice(1).map(Number);
  return octets.every((octet) => octet <= 255) ? octets : null;
}

function isNonPublicIpv4(octets: number[]): boolean {
  const [a = 0, b = 0] = octets;
  return (
    a === 0 ||
    a === 10 ||
    a === 127 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168)
  );
}

/** Expands an IPv6 literal into 8 16-bit groups, or null if it is not one. */
function parseIpv6(host: string): number[] | null {
  if (!host.includes(':')) {
    return null;
  }
  let text = host;
  const tail: number[] = [];
  const lastColon = text.lastIndexOf(':');
  const embedded = parseIpv4(text.slice(lastColon + 1));
  if (embedded) {
    tail.push(((embedded[0] ?? 0) << 8) | (embedded[1] ?? 0));
    tail.push(((embedded[2] ?? 0) << 8) | (embedded[3] ?? 0));
    // Drop the dotted tail, keeping a trailing '::' but not a lone ':'.
    text = text.slice(0, lastColon + 1);
    if (!text.endsWith('::')) {
      text = text.slice(0, -1);
    }
  } else if (host.includes('.')) {
    return null;
  }

  const halves = text.split('::');
  if (halves.length > 2) {
    return null;
  }
  const parseGroups = (part: string): number[] | null => {
    if (part === '') {
      return [];
    }
    const groups: number[] = [];
    for (const group of part.split(':')) {
      if (!/^[0-9a-f]{1,4}$/i.test(group)) {
        return null;
      }
      groups.push(parseInt(group, 16));
    }
    return groups;
  };

  const head = parseGroups(halves[0] ?? '');
  const rest = halves.length === 2 ? parseGroups(halves[1] ?? '') : [];
  if (!head || !rest) {
    return null;
  }
  const explicit = head.length + rest.length + tail.length;
  if (halves.length === 1) {
    return explicit === 8 ? [...head, ...tail] : null;
  }
  if (explicit > 7) {
    return null;
  }
  return [...head, ...new Array<number>(8 - explicit).fill(0), ...rest, ...tail];
}

function isNonPublicIpv6(groups: number[]): boolean {
  const first = groups[0] ?? 0;
  const leadingZero = groups.slice(0, 5).every((group) => group === 0);
  if (leadingZero && groups[5] === 0xffff) {
    const high = groups[6] ?? 0;
    const low = groups[7] ?? 0;
    return isNonPublicIpv4([high >> 8, high & 0xff, low >> 8, low & 0xff]);
  }
  if (groups.slice(0, 7).every((group) => group === 0) && (groups[7] ?? 0) <= 1) {
    return true; // :: and ::1
  }
  return (first & 0xfe00) === 0xfc00 || (first & 0xffc0) === 0xfe80;
}

/** True when `hostname` (optionally bracketed IPv6) is a public IP literal. */
export function isPublicIpLiteralHost(hostname: string): boolean {
  const host = hostname.replace(/^\[(.*)\]$/, '$1').toLowerCase();
  const ipv4 = parseIpv4(host);
  if (ipv4) {
    return !isNonPublicIpv4(ipv4);
  }
  const ipv6 = parseIpv6(host);
  return ipv6 ? !isNonPublicIpv6(ipv6) : false;
}

export function evaluatePublicIpLiteral(
  details: PublicIpLiteralRequest,
  options: { extensionOrigin?: string } = {}
): PublicIpLiteralOutcome | null {
  if (isExtensionUrl(details.url)) {
    return null;
  }
  const hostname = extractHostname(details.url);
  if (!hostname || !isPublicIpLiteralHost(hostname)) {
    return null;
  }

  const reason = `${PUBLIC_IP_LITERAL_REASON}:${hostname}`;
  if (details.type === 'main_frame' && options.extensionOrigin) {
    return {
      redirectUrl: buildBlockedScreenRedirectUrl({
        extensionOrigin: options.extensionOrigin,
        hostname,
        error: reason,
        origin: extractHostname(details.originUrl ?? details.documentUrl ?? ''),
      }),
      reason,
    };
  }
  return { cancel: true, reason };
}
