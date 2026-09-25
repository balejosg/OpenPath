// Lane-side DNS fixture for the Windows student-policy suite.
//
// The product forwards whitelisted domains, including a whitelisted sslip.io
// parent, to its configured upstream. The lab upstream resolver blocks
// sslip.io names, so subdomains such as request-domain-<id>.127.0.0.1.sslip.io
// never resolve on the lab network even though they resolve publicly in
// production. This resolver mirrors the public sslip.io service for the lab:
// it answers embedded-IPv4 sslip names locally and forwards everything else to
// the configured lab resolver.
//
// Usage: node openpath-sslip-resolver.mjs
// Env:   OPENPATH_SSLP_RESOLVER_ADDRESS (default 127.0.0.2)
//        OPENPATH_SSLP_RESOLVER_PORT    (default 53)
//        OPENPATH_SSLP_RESOLVER_UPSTREAM (default 192.168.1.133)

import dgram from 'node:dgram';

const listenAddress = process.env.OPENPATH_SSLP_RESOLVER_ADDRESS ?? '127.0.0.2';
const listenPort = Number(process.env.OPENPATH_SSLP_RESOLVER_PORT ?? '53');
const upstreamAddress = process.env.OPENPATH_SSLP_RESOLVER_UPSTREAM ?? '192.168.1.133';
const upstreamPort = 53;
const upstreamTimeoutMs = 4_000;
const answerTtlSeconds = 60;

const SSLP_IPV4_PATTERN = /(?:^|\.)(\d{1,3}(?:[.-]\d{1,3}){3})\.sslip\.io$/i;

function parseQuestion(message) {
  if (message.length < 12) {
    return null;
  }
  const qdCount = message.readUInt16BE(4);
  if (qdCount !== 1) {
    return null;
  }

  let offset = 12;
  const labels = [];
  while (offset < message.length) {
    const length = message[offset];
    if (length === 0) {
      offset += 1;
      break;
    }
    if (length > 63 || offset + 1 + length > message.length) {
      return null;
    }
    labels.push(message.subarray(offset + 1, offset + 1 + length).toString('ascii'));
    offset += 1 + length;
  }
  if (offset + 4 > message.length) {
    return null;
  }

  const type = message.readUInt16BE(offset);
  const questionEnd = offset + 4;
  return { name: labels.join('.'), type, questionEnd };
}

function embeddedSslipAddress(name) {
  const match = SSLP_IPV4_PATTERN.exec(name);
  if (!match) {
    return null;
  }
  const octets = match[1].split(/[.-]/).map((part) => Number(part));
  if (
    octets.length !== 4 ||
    octets.some((octet) => !Number.isInteger(octet) || octet < 0 || octet > 255)
  ) {
    return null;
  }
  return Buffer.from(octets);
}

function buildResponse(query, question, address) {
  const answerCount = address ? 1 : 0;
  const header = Buffer.alloc(12);
  query.copy(header, 0, 0, 2); // ID
  const rd = query.readUInt16BE(2) & 0x0100;
  header.writeUInt16BE(0x8180 | rd, 2); // QR=1, AA=1, RD copied, RA=1, RCODE=0
  header.writeUInt16BE(1, 4); // QDCOUNT
  header.writeUInt16BE(answerCount, 6); // ANCOUNT
  header.writeUInt16BE(0, 8); // NSCOUNT
  header.writeUInt16BE(0, 10); // ARCOUNT

  const questionBytes = query.subarray(12, question.questionEnd);
  if (!address) {
    return Buffer.concat([header, questionBytes]);
  }

  const answer = Buffer.alloc(16);
  answer.writeUInt16BE(0xc00c, 0); // pointer to the question name
  answer.writeUInt16BE(1, 2); // TYPE A
  answer.writeUInt16BE(1, 4); // CLASS IN
  answer.writeUInt32BE(answerTtlSeconds, 6);
  answer.writeUInt16BE(4, 10); // RDLENGTH
  address.copy(answer, 12);

  return Buffer.concat([header, questionBytes, answer]);
}

const server = dgram.createSocket('udp4');

function forwardToUpstream(query, remote) {
  const upstream = dgram.createSocket('udp4');
  const timer = setTimeout(() => {
    upstream.close();
  }, upstreamTimeoutMs);

  upstream.on('message', (reply) => {
    clearTimeout(timer);
    server.send(reply, remote.port, remote.address, () => upstream.close());
  });
  upstream.on('error', () => {
    clearTimeout(timer);
    try {
      upstream.close();
    } catch {
      // ignore
    }
  });

  upstream.send(query, upstreamPort, upstreamAddress);
}

server.on('message', (query, remote) => {
  const question = parseQuestion(query);
  if (!question) {
    return;
  }

  const sslipAddress = embeddedSslipAddress(question.name);
  if (sslipAddress && question.type === 1) {
    server.send(buildResponse(query, question, sslipAddress), remote.port, remote.address);
    console.log(`sslip A ${question.name} -> ${sslipAddress.join('.')}`);
    return;
  }
  if (sslipAddress && question.type === 28) {
    // NODATA for AAAA keeps clients from preferring a bogus IPv6 answer.
    server.send(buildResponse(query, question, null), remote.port, remote.address);
    console.log(`sslip AAAA ${question.name} -> nodata`);
    return;
  }

  forwardToUpstream(query, remote);
});

server.on('listening', () => {
  console.log(
    `sslip resolver listening on ${listenAddress}:${listenPort}, upstream ${upstreamAddress}:${upstreamPort}`
  );
});

server.bind(listenPort, listenAddress);
