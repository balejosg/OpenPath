import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

interface BuildWindowsStudentSummaryOptions {
  artifactsDir: string;
  mode: 'failure' | 'success';
}

interface SummarySection {
  fileName: string;
  excerpt: string;
}

const SUMMARY_FILES = [
  'windows-student-policy-trace.log',
  'windows-diagnostics.txt',
  'reconcile-student-scenario.log',
  'reconcile-student-scenario.err.log',
  'windows-student-policy-sse.log',
  'windows-student-policy-sse.err.log',
  'windows-student-policy-fallback.log',
  'windows-student-policy-fallback.err.log',
] as const;

const MAX_LINES_PER_SECTION = 80;

function redactSensitiveValues(content: string): string {
  return content
    .replace(/(machineToken"\s*:\s*")([^"]+)(")/g, '$1[redacted]$3')
    .replace(/(whitelistUrl"\s*:\s*")([^"]*\/w\/)([^/]+)(\/[^"]*")/g, '$1$2[redacted]$4')
    .replace(/(\/w\/)([^/]+)(\/whitelist\.txt)/g, '$1[redacted]$3');
}

function readExcerpt(filePath: string): string {
  if (!fs.existsSync(filePath)) {
    return `${path.basename(filePath)}: missing`;
  }

  const content = fs.readFileSync(filePath, 'utf8').trim();
  if (!content) {
    return `${path.basename(filePath)}: empty`;
  }

  const lines = redactSensitiveValues(content).split(/\r?\n/);
  const truncated = lines.length > MAX_LINES_PER_SECTION;
  const excerpt = (truncated ? lines.slice(-MAX_LINES_PER_SECTION) : lines).join('\n').trim();

  return truncated ? `${excerpt}\n... [truncated]` : excerpt;
}

// Phase 8 H1: the compiled native host state (build diagnostics, build
// manifest, executable hash and messaging manifest target) must be visible in
// the failure/success summary, not only inside windows-diagnostics.txt.
function readNativeHostState(artifactsDir: string): string {
  const statePath = path.join(artifactsDir, 'native-host', 'native-host-state.json');
  if (!fs.existsSync(statePath)) {
    return 'native-host/native-host-state.json: missing';
  }

  const content = redactSensitiveValues(fs.readFileSync(statePath, 'utf8').trim());
  if (!content) {
    return 'native-host/native-host-state.json: empty';
  }

  return content.length > 4000 ? `${content.slice(0, 4000)}\n... [truncated]` : content;
}

function buildSections(artifactsDir: string): SummarySection[] {
  const sections = SUMMARY_FILES.map((fileName) => ({
    fileName,
    excerpt: readExcerpt(path.join(artifactsDir, fileName)),
  }));
  sections.push({
    fileName: 'native-host/native-host-state.json',
    excerpt: readNativeHostState(artifactsDir),
  });

  return sections;
}

export function buildWindowsStudentSummary({
  artifactsDir,
  mode,
}: BuildWindowsStudentSummaryOptions): string {
  const sections = buildSections(artifactsDir).map(({ fileName, excerpt }) => {
    return `## ${fileName}\n\n\`\`\`text\n${excerpt}\n\`\`\``;
  });

  return [`# Windows Student Policy Diagnostics (${mode})`, '', ...sections, ''].join('\n');
}

export function buildWindowsStudentAnnotations({
  artifactsDir,
  mode,
}: BuildWindowsStudentSummaryOptions): string[] {
  return buildSections(artifactsDir).map(({ fileName, excerpt }) => {
    const payload = `${mode} ${fileName}: ${excerpt.replace(/\r?\n/g, ' | ')}`;
    return `::error title=Windows Student Policy Diagnostics::${payload}`;
  });
}

function getOption(name: string): string {
  const index = process.argv.indexOf(name);
  const value = index >= 0 ? process.argv[index + 1] : undefined;
  if (!value) {
    throw new Error(`Missing required option: ${name}`);
  }

  return value;
}

function runCli(): void {
  const artifactsDir = path.resolve(getOption('--artifacts-dir'));
  const mode = getOption('--mode');
  if (mode !== 'failure' && mode !== 'success') {
    throw new Error(`Unsupported mode: ${mode}`);
  }

  process.stdout.write(buildWindowsStudentSummary({ artifactsDir, mode }));
}

const isMainModule =
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;

if (isMainModule) {
  runCli();
}
