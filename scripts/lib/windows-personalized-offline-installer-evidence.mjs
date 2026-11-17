const CREDENTIAL_NAME =
  /(?:enrollment|access|refresh|id|api|auth|canary)?[_-]?token|(?:^|[^a-z0-9])(?:secret|password|passwd|credential|authorization)(?:$|[^a-z0-9])|api[-_ ]?key|private[-_ ]?key/i;
const BEARER_SCHEME = /\bBearer\b/i;
const JWT_VALUE =
  /(?:^|[^A-Za-z0-9_-])eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+(?:$|[^A-Za-z0-9_-])/;
const KNOWN_TOKEN =
  /\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35})\b/;
const LOG_PATH = /\b[A-Za-z0-9._-]+\.log\b/i;
const LOG_LEVEL =
  /(?:^|\n)\s*\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?\s+(?:TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL)\b|(?:^|\n)\s*\[(?:TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL)\]|\b(?:TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL)\b\s*[:|-]\s+\S|(?:^|\n)\s*(?:stdout|stderr)\s*[:=]/m;
const EXCEPTION_KEY = /exception|stacktrace|stack_trace|rawerror|errorrecord/i;
const EXCEPTION_VALUE =
  /Exception\.Message|(?:^|\s)(?:System\.)?[A-Za-z0-9_.]+Exception(?:\s*:|\b)|(?:^|\n)\s*at\s+[A-Za-z0-9_.<>`]+\s*\(|At line:\s*\d+\s+char:\s*\d+|Exception calling\s+"|--- End of stack trace|Unhandled exception|Stack trace:|FullyQualifiedErrorId|CategoryInfo/m;

function isCredentialName(value) {
  return CREDENTIAL_NAME.test(value);
}

function isBearerScheme(value) {
  return BEARER_SCHEME.test(value);
}

function isOpaqueToken(value) {
  const text = value.trim();
  if (text.length < 32 || text.length > 4096) return false;
  if (!/^[A-Za-z0-9_-]+={0,2}$/.test(text)) return false;
  if (/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/i.test(text)) return false;
  if (!/[a-z]/.test(text) || !/[A-Z]/.test(text) || !/[0-9]/.test(text)) return false;
  if (/^[a-z0-9]+(?:-[a-z0-9]+){2,}$/.test(text)) return false;
  return true;
}

function isTokenValue(value) {
  return JWT_VALUE.test(value) || KNOWN_TOKEN.test(value) || isOpaqueToken(value);
}

function isLogPath(value) {
  return LOG_PATH.test(value);
}

function isLogContent(value) {
  return LOG_LEVEL.test(value);
}

function isExceptionKey(key) {
  return EXCEPTION_KEY.test(key);
}

function isExceptionMessage(value) {
  return EXCEPTION_VALUE.test(value);
}

function isLogKey(key) {
  return /(?:^|[_-])(?:log|logs|logpath|logfile|logcontent|logoutput|stdout|stderr)(?:$|[_-])/i.test(
    key
  );
}

function isLogContentKey(key) {
  return /(?:^|[_-])(?:logcontent|logoutput|stdout|stderr)(?:$|[_-])/i.test(key);
}

function childPath(parent, key) {
  const text = String(key);
  if (/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(text)) return `${parent}.${text}`;
  return `${parent}[${JSON.stringify(text)}]`;
}

function addFinding(findings, seen, category, path) {
  const identity = `${category}\0${path}`;
  if (seen.has(identity)) return;
  seen.add(identity);
  findings.push({ category, path });
}

function inspectText(findings, seen, path, value) {
  if (isCredentialName(value)) addFinding(findings, seen, 'credential-field', path);
  if (isBearerScheme(value)) addFinding(findings, seen, 'bearer-scheme', path);
  if (isTokenValue(value)) addFinding(findings, seen, 'token-value', path);
  if (isLogPath(value)) addFinding(findings, seen, 'log-path', path);
  if (isLogContent(value)) addFinding(findings, seen, 'log-content', path);
  if (isExceptionMessage(value)) addFinding(findings, seen, 'exception-message', path);
}

function inspectValue(value, path, findings, seen) {
  if (typeof value === 'string') {
    inspectText(findings, seen, path, value);
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((entry, index) => inspectValue(entry, `${path}[${index}]`, findings, seen));
    return;
  }
  if (value === null || typeof value !== 'object') return;

  for (const [key, entry] of Object.entries(value)) {
    const entryPath = childPath(path, key);
    if (isCredentialName(key)) addFinding(findings, seen, 'credential-field', entryPath);
    if (isBearerScheme(key)) addFinding(findings, seen, 'bearer-scheme', entryPath);
    if (isTokenValue(key)) addFinding(findings, seen, 'token-value', entryPath);
    if (isLogPath(key)) addFinding(findings, seen, 'log-path', entryPath);
    if (isLogKey(key)) {
      addFinding(findings, seen, isLogContentKey(key) ? 'log-content' : 'log-path', entryPath);
    }
    if (isExceptionKey(key)) addFinding(findings, seen, 'exception-message', entryPath);
    inspectValue(entry, entryPath, findings, seen);
  }
}

export function collectEvidenceLeaks(evidence) {
  const findings = [];
  const seen = new Set();
  inspectValue(evidence, '$', findings, seen);
  return findings;
}

export function validateEvidence(evidence) {
  const findings = collectEvidenceLeaks(evidence);
  if (findings.length > 0) {
    const summary = findings.map((finding) => `${finding.category} at ${finding.path}`).join('; ');
    throw new Error('Windows personalized offline installer evidence rejected: ' + summary);
  }
  return { status: 'passed' };
}

export function parseArgs(argv) {
  const options = {};
  const allowed = new Set(['evidence']);
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (!key.startsWith('--') || !allowed.has(key.slice(2))) {
      throw new Error('unknown argument ' + key);
    }
    const name = key.slice(2);
    if (Object.prototype.hasOwnProperty.call(options, name)) {
      throw new Error('duplicate argument ' + key);
    }
    const value = argv[index + 1];
    if (value === undefined || value.startsWith('--')) {
      throw new Error('missing value for ' + key);
    }
    options[name] = value;
    index += 1;
  }
  if (!options.evidence) throw new Error('--evidence is required');
  return options;
}
