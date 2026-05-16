function bashSingleQuote(value: string): string {
  const escaped = value.replace(/'/g, "'\\''");
  return `'${escaped}'`;
}

const LOCAL_HTTP_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]', '::1']);

function isTestFixtureHost(hostname: string): boolean {
  return hostname === 'example' || hostname.endsWith('.example') || hostname.endsWith('.test');
}

function assertSafeEnrollmentUrl(value: string, label: string): void {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error(`${label} must be a valid URL`);
  }

  if (url.protocol !== 'http:') {
    return;
  }

  if (process.env.NODE_ENV === 'test') {
    return;
  }

  const hostname = url.hostname;
  if (LOCAL_HTTP_HOSTS.has(hostname) || isTestFixtureHost(hostname)) {
    return;
  }

  throw new Error(`${label} must use HTTPS outside local or test environments`);
}

export interface LinuxEnrollmentScriptParams {
  publicUrl: string;
  classroomId: string;
  classroomName: string;
  enrollmentToken: string;
  aptRepoUrl: string;
  linuxAgentVersion: string;
  linuxAgentAptSuite?: string;
}

export function buildLinuxEnrollmentScript({
  publicUrl,
  classroomId,
  classroomName,
  enrollmentToken,
  aptRepoUrl,
  linuxAgentVersion,
  linuxAgentAptSuite = 'stable',
}: LinuxEnrollmentScriptParams): string {
  assertSafeEnrollmentUrl(publicUrl, 'publicUrl');
  assertSafeEnrollmentUrl(aptRepoUrl, 'aptRepoUrl');

  const aptSuite = linuxAgentAptSuite === 'unstable' ? 'unstable' : 'stable';
  const bootstrapSuiteOverride = aptSuite === 'unstable' ? 'bootstrap_cmd+=(--unstable)' : '';
  const bootstrapVersionOverride = linuxAgentVersion
    ? 'bootstrap_cmd+=(--package-version "$LINUX_AGENT_VERSION")'
    : '';

  return `#!/bin/bash
set -euo pipefail

API_URL=${bashSingleQuote(publicUrl)}
CLASSROOM_ID=${bashSingleQuote(classroomId)}
CLASSROOM_NAME=${bashSingleQuote(classroomName)}
ENROLLMENT_TOKEN=${bashSingleQuote(enrollmentToken)}
APT_BOOTSTRAP_URL=${bashSingleQuote(`${aptRepoUrl}/apt-bootstrap.sh`)}
OPENPATH_APT_REPO_URL=${bashSingleQuote(aptRepoUrl)}
export OPENPATH_APT_REPO_URL
LINUX_AGENT_APT_SUITE=${bashSingleQuote(aptSuite)}
${linuxAgentVersion ? `LINUX_AGENT_VERSION=${bashSingleQuote(linuxAgentVersion)}` : ''}

 echo ''
echo '==============================================='
echo ' OpenPath Enrollment: '"$CLASSROOM_NAME"
echo '==============================================='
echo ''

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run with sudo"
    exit 1
fi

echo "[1/2] Instalando y registrando en aula..."
tmpfile="$(mktemp)"
trap 'rm -f "$tmpfile"' EXIT
curl -fsSL --proto '=https' --tlsv1.2 "$APT_BOOTSTRAP_URL" -o "$tmpfile"
bootstrap_cmd=(bash "$tmpfile")
${bootstrapSuiteOverride}
${bootstrapVersionOverride}
bootstrap_cmd+=(--api-url "$API_URL" --classroom "$CLASSROOM_NAME" --classroom-id "$CLASSROOM_ID" --enrollment-token "$ENROLLMENT_TOKEN")
"\${bootstrap_cmd[@]}"

echo "[2/2] Verificando..."
openpath health

echo ""
echo "========================================="
echo "  OK - Equipo listo en aula: $CLASSROOM_NAME"
echo "========================================="
echo ""
`;
}
