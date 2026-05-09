#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import process from 'node:process';

export const WINDOWS_STUDENT_POLICY_SSE_GROUPS = [
  'full',
  'request-lifecycle',
  'path-blocking',
  'exemptions',
];

const GROUP_PATTERNS = {
  'request-lifecycle': [
    /^api\/src\/services\/request-/,
    /^api\/src\/services\/public-request\.service\.ts$/,
    /^api\/src\/routes\/public-requests\.ts$/,
    /^api\/src\/lib\/public-request-input\.ts$/,
    /^api\/src\/lib\/request-storage-/,
    /^api\/src\/trpc\/routers\/requests\.ts$/,
    /^firefox-extension\/src\/lib\/blocked-request\.ts$/,
    /^firefox-extension\/src\/lib\/popup-request-/,
    /^firefox-extension\/src\/lib\/popup-controller/,
    /^firefox-extension\/src\/lib\/request-api\.ts$/,
    /^firefox-extension\/src\/popup\.ts$/,
  ],
  'path-blocking': [
    /^firefox-extension\/src\/lib\/path-blocking\.ts$/,
    /^firefox-extension\/src\/lib\/background-path-rules\.ts$/,
    /^firefox-extension\/tests\/background-path-blocking-flow\.test\.ts$/,
  ],
  exemptions: [
    /^api\/src\/services\/classroom-exemption-/,
    /^api\/src\/services\/schedule-/,
    /^api\/src\/lib\/exemption-storage-/,
    /^api\/src\/lib\/schedule-/,
    /^api\/src\/trpc\/routers\/schedules\.ts$/,
  ],
};

const FORCE_FULL_PATTERNS = [
  /^$/,
  /^package\.json$/,
  /^package-lock\.json$/,
  /^shared\//,
  /^runtime\//,
  /^windows\//,
  /^linux\//,
  /^docker-compose\.test\.yml$/,
  /^\.github\//,
  /^scripts\//,
  /^tests\/e2e\//,
  /^tests\/selenium\/(student-policy-(env|harness|driver|driver-.*|flow\.e2e|types)\.ts|package.*)$/,
  /^api\/src\/routes\/machines/,
  /^api\/src\/services\/machine-events\.service\.ts$/,
  /^api\/src\/services\/domain-events/,
  /^api\/src\/services\/groups-/,
  /^api\/src\/lib\/groups-/,
  /^api\/src\/trpc\/routers\/groups/,
];

export function validateWindowsStudentPolicySseGroup(value) {
  if (value === 'auto') return value;
  if (WINDOWS_STUDENT_POLICY_SSE_GROUPS.includes(value)) return value;

  throw new Error(
    `student_policy_sse_group must be one of auto, ${WINDOWS_STUDENT_POLICY_SSE_GROUPS.join(
      ', '
    )}; received ${value}`
  );
}

export function selectWindowsStudentPolicySseGroup(files, options = {}) {
  return selectWindowsStudentPolicySseGroupWithReason(files, options).group;
}

export function selectWindowsStudentPolicySseGroupWithReason(files, options = {}) {
  const override = validateWindowsStudentPolicySseGroup(options.override ?? 'auto');
  if (override !== 'auto') {
    return {
      group: override,
      reason: `manual override selected '${override}'`,
    };
  }

  const normalizedFiles = files.map(normalizeFile).filter(Boolean);
  if (normalizedFiles.length === 0) {
    return {
      group: 'full',
      reason: 'no changed files detected; using full SSE coverage',
    };
  }

  const matchedGroups = new Set();

  for (const file of normalizedFiles) {
    if (FORCE_FULL_PATTERNS.some((pattern) => pattern.test(file))) {
      return {
        group: 'full',
        reason: `${file} requires full SSE coverage`,
      };
    }

    const fileGroups = Object.entries(GROUP_PATTERNS)
      .filter(([, patterns]) => patterns.some((pattern) => pattern.test(file)))
      .map(([group]) => group);

    if (fileGroups.length === 0) {
      return {
        group: 'full',
        reason: `${file} does not match one narrow SSE group; using full SSE coverage`,
      };
    }
    if (fileGroups.length > 1) {
      return {
        group: 'full',
        reason: `${file} matches multiple narrow SSE groups: ${fileGroups.join(
          ', '
        )}; using full SSE coverage`,
      };
    }
    matchedGroups.add(fileGroups[0]);
  }

  if (matchedGroups.size === 1) {
    const group = Array.from(matchedGroups)[0];
    return {
      group,
      reason: `matched narrow SSE group '${group}' for all changed files`,
    };
  }

  return {
    group: 'full',
    reason: `multiple narrow SSE groups matched: ${Array.from(matchedGroups).join(
      ', '
    )}; using full SSE coverage`,
  };
}

function normalizeFile(file) {
  return String(file).trim().replaceAll('\\', '/').replace(/^\.\//, '');
}

function parseArgs(argv) {
  const args = {
    files: [],
    fromStdin: false,
    override: 'auto',
    reason: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--from-stdin') {
      args.fromStdin = true;
      continue;
    }
    if (arg === '--reason') {
      args.reason = true;
      continue;
    }
    if (arg === '--override') {
      args.override = argv[index + 1] ?? 'auto';
      index += 1;
      continue;
    }
    if (arg === '--files') {
      args.files.push(...splitFiles(argv[index + 1] ?? ''));
      index += 1;
      continue;
    }
    args.files.push(...splitFiles(arg));
  }

  return args;
}

function splitFiles(value) {
  return String(value)
    .split(/\r?\n|,/)
    .map((file) => file.trim())
    .filter(Boolean);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const stdinFiles = args.fromStdin ? splitFiles(readFileSync(0, 'utf8')) : [];
  const selection = selectWindowsStudentPolicySseGroupWithReason([...args.files, ...stdinFiles], {
    override: args.override,
  });
  process.stdout.write(`${args.reason ? selection.reason : selection.group}\n`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
