#!/usr/bin/env node
/**
 * check-ps-datetime-culture.mjs
 *
 * Guards against culture-sensitive PowerShell DateTime parsing.
 *
 * WHY: [DateTime]::Parse(str) and [DateTime]::ParseExact(str, ...) without an
 * explicit InvariantCulture argument silently swap day and month on d/M locales
 * (e.g. es-ES). On a Spanish-locale Windows host, a date string like "06/12/2026"
 * is parsed as 12 June instead of 6 December, causing silent data corruption in
 * captive-portal expiry handling and any other date-aware logic.
 *
 * WHAT IT FLAGS: any line containing [DateTime]::Parse( or [DateTime]::ParseExact(
 * (case-insensitive) that does NOT also contain "InvariantCulture" on the same line.
 *
 * ESCAPE HATCH: add a comment containing "# ps-culture-allow: <justification>" on
 * the same line or on the line directly above the flagged call. Use this only when
 * you have a verified reason the call is safe (e.g. the input is a fixed numeric
 * format and locale cannot affect it, and you have a test proving it).
 *
 * USAGE:
 *   node scripts/check-ps-datetime-culture.mjs              # scan all tracked .ps1/.psm1
 *   node scripts/check-ps-datetime-culture.mjs file.ps1 ... # lint-staged mode
 *   node scripts/check-ps-datetime-culture.mjs --self-check  # run embedded fixture tests
 */

import { existsSync, readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ALLOW_MARKER = '# ps-culture-allow:';
const PARSE_PATTERN = /\[datetime\]::(parse\(|parseexact\()/i;
const INVARIANT_PATTERN = /invariantculture/i;

/**
 * Returns true if the line is flagged (contains a non-compliant DateTime Parse call).
 * A line is exempt when it contains InvariantCulture, or when it (or the line above)
 * contains the ps-culture-allow escape marker.
 *
 * @param {string} line - the line under test
 * @param {string} prevLine - the line directly above (empty string if first line)
 * @returns {boolean} true when the line should be flagged as a violation
 */
function isViolation(line, prevLine) {
  if (!PARSE_PATTERN.test(line)) {
    return false;
  }
  if (INVARIANT_PATTERN.test(line)) {
    return false;
  }
  if (line.includes(ALLOW_MARKER)) {
    return false;
  }
  if (prevLine.includes(ALLOW_MARKER)) {
    return false;
  }
  return true;
}

/**
 * Check a single file. Returns an array of violation strings ("file:line: content").
 *
 * @param {string} filePath - absolute or relative path to a .ps1 or .psm1 file
 * @returns {string[]} violation report lines
 */
function checkFile(filePath) {
  const violations = [];
  let content;
  try {
    content = readFileSync(filePath, 'utf8');
  } catch {
    return violations;
  }
  const lines = content.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const prevLine = i > 0 ? lines[i - 1] : '';
    if (isViolation(line, prevLine)) {
      violations.push(`${filePath}:${i + 1}: ${line}`);
    }
  }
  return violations;
}

// ---------------------------------------------------------------------------
// --self-check: embedded fixture tests
// ---------------------------------------------------------------------------

function runSelfCheck() {
  const fixtures = [
    // compliant: has InvariantCulture on same line -> must NOT flag
    {
      label: 'compliant Parse with InvariantCulture',
      line: '    [DateTime]::Parse($raw, [System.Globalization.CultureInfo]::InvariantCulture)',
      prev: '',
      expectViolation: false,
    },
    // compliant: ParseExact with InvariantCulture -> must NOT flag
    {
      label: 'compliant ParseExact with InvariantCulture',
      line: "    [DateTime]::ParseExact($s, 'yyyyMMdd', [CultureInfo]::InvariantCulture)",
      prev: '',
      expectViolation: false,
    },
    // violation: bare Parse without InvariantCulture -> must flag
    {
      label: 'violating Parse without InvariantCulture',
      line: '    [DateTime]::Parse($someString)',
      prev: '',
      expectViolation: true,
    },
    // violation: lowercase [datetime]::parseexact -> must flag
    {
      label: 'violating parseexact in lowercase',
      line: "    [datetime]::parseexact($s, 'dd/MM/yyyy', $null)",
      prev: '',
      expectViolation: true,
    },
    // exempt by inline comment -> must NOT flag
    {
      label: 'allowed-by-inline-comment line',
      line: '    [DateTime]::Parse($x) # ps-culture-allow: numeric-only input, locale-safe',
      prev: '',
      expectViolation: false,
    },
    // exempt by preceding-line comment -> must NOT flag
    {
      label: 'allowed-by-preceding-line comment',
      line: '    [DateTime]::Parse($x)',
      prev: '    # ps-culture-allow: verified numeric ISO format',
      expectViolation: false,
    },
    // Parse mentioned only in a plain comment (no bracketed type) -> must NOT flag
    {
      label: 'Parse only in a plain comment, no bracketed type',
      line: '    # We Parse the date here',
      prev: '',
      expectViolation: false,
    },
  ];

  let allPassed = true;
  const failed = [];
  for (const fixture of fixtures) {
    const got = isViolation(fixture.line, fixture.prev);
    const pass = got === fixture.expectViolation;
    const status = pass ? 'PASS' : 'FAIL';
    if (!pass) {
      allPassed = false;
      failed.push(fixture.label);
    }
    console.log(
      `  [${status}] ${fixture.label}: expected ${fixture.expectViolation ? 'violation' : 'clean'}, got ${got ? 'violation' : 'clean'}`
    );
  }

  if (allPassed) {
    console.log('\nSelf-check passed: all fixtures classified correctly.');
    process.exit(0);
  } else {
    console.error(
      `\nSelf-check FAILED: ${failed.length} fixture(s) misclassified: ${failed.map((l) => `"${l}"`).join(', ')}`
    );
    process.exit(1);
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const args = process.argv.slice(2);

if (args.includes('--self-check')) {
  console.log('Running self-check fixtures...\n');
  runSelfCheck();
}

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(__dirname, '..');

let filesToCheck;

if (args.length > 0) {
  // lint-staged mode: filter to .ps1/.psm1 that still exist on disk
  filesToCheck = args.filter((f) => {
    if (!/\.(ps1|psm1)$/i.test(f)) {
      return false;
    }
    return existsSync(f);
  });
} else {
  // full-scan mode: all tracked PowerShell files
  let output;
  try {
    output = execSync("git ls-files '*.ps1' '*.psm1'", {
      cwd: projectRoot,
      encoding: 'utf8',
    });
  } catch {
    output = '';
  }
  filesToCheck = output
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((f) => resolve(projectRoot, f));
}

const allViolations = [];
for (const filePath of filesToCheck) {
  allViolations.push(...checkFile(filePath));
}

if (allViolations.length > 0) {
  for (const v of allViolations) {
    process.stdout.write(v + '\n');
  }
  process.stdout.write(
    '\n' +
      'HOW TO FIX:\n' +
      '  Pass [System.Globalization.CultureInfo]::InvariantCulture (and, for ParseExact,\n' +
      '  [System.Globalization.DateTimeStyles]::RoundtripKind) as the 2nd/3rd arguments:\n' +
      '    [DateTime]::Parse($str, [CultureInfo]::InvariantCulture)\n' +
      '    [DateTime]::ParseExact($str, $fmt, [CultureInfo]::InvariantCulture,\n' +
      '        [System.Globalization.DateTimeStyles]::RoundtripKind)\n' +
      '  ESCAPE HATCH: add "# ps-culture-allow: <justification>" on the flagged line OR\n' +
      '  on the line directly above it (both positions are honored).\n'
  );
  process.exit(1);
}

console.log(`PS DateTime culture check passed (${filesToCheck.length} file(s) scanned).`);
process.exit(0);
