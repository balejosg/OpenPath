#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const rootDir = path.resolve(process.cwd());
const ignoreDirs = new Set([
  '.git',
  'node_modules',
  'dist',
  'coverage',
  'playwright-report',
  'test-results',
  '.opencode',
]);

const markdownFiles = [];
const failures = [];
const docsIndexPath = 'docs/INDEX.md';
const asciiOnlyExemptPaths = new Set(['CHANGELOG.md']);
const asciiOnlyExemptPrefixes = ['docs/adr/'];
const draftDocPrefixes = ['docs/plans/'];

function isDraftDoc(relativePath) {
  return draftDocPrefixes.some((prefix) => relativePath.startsWith(prefix));
}

function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory() && ignoreDirs.has(entry.name)) {
      continue;
    }

    if (entry.name.startsWith('.') && entry.name !== '.github') {
      continue;
    }

    const fullPath = path.join(dir, entry.name);
    const relativePath = path.relative(rootDir, fullPath);

    if (entry.isDirectory()) {
      if (isDraftDoc(`${relativePath}/`)) {
        continue;
      }

      walk(fullPath);
      continue;
    }

    if (entry.isFile() && entry.name.endsWith('.md')) {
      if (isDraftDoc(relativePath)) {
        continue;
      }

      markdownFiles.push(relativePath);
    }
  }
}

function normalizeLinkTarget(rawTarget) {
  const trimmed = rawTarget.trim().replace(/^<|>$/g, '');
  if (
    trimmed.length === 0 ||
    trimmed.startsWith('#') ||
    trimmed.startsWith('http://') ||
    trimmed.startsWith('https://') ||
    trimmed.startsWith('mailto:') ||
    trimmed.startsWith('tel:') ||
    trimmed.startsWith('data:') ||
    trimmed.startsWith('app://')
  ) {
    return null;
  }

  return trimmed.split('#')[0].split('?')[0];
}

function toRepoRelative(fromFile, target) {
  const fromDir = path.dirname(path.join(rootDir, fromFile));
  const resolvedPath = path.resolve(fromDir, target);
  return path.relative(rootDir, resolvedPath);
}

function shouldBeAsciiOnly(relativePath) {
  if (asciiOnlyExemptPaths.has(relativePath)) {
    return false;
  }

  return !asciiOnlyExemptPrefixes.some((prefix) => relativePath.startsWith(prefix));
}

walk(rootDir);

const docsIndexContent = fs.readFileSync(path.join(rootDir, docsIndexPath), 'utf8');
const markdownLinkPattern = /!?\[[^\]]*]\(([^)]+)\)/g;
const indexedDocs = new Set();

for (const match of docsIndexContent.matchAll(markdownLinkPattern)) {
  const normalizedTarget = normalizeLinkTarget(match[1]);
  if (!normalizedTarget || !normalizedTarget.endsWith('.md')) {
    continue;
  }

  indexedDocs.add(toRepoRelative(docsIndexPath, normalizedTarget));
}

for (const indexedDoc of indexedDocs) {
  if (indexedDoc.startsWith('docs/plans/')) {
    failures.push(`${docsIndexPath}: canonical index must not include draft plan ${indexedDoc}`);
  }

  if (indexedDoc.startsWith('.github/')) {
    failures.push(
      `${docsIndexPath}: canonical index must not include repo-process doc ${indexedDoc}`
    );
  }
}

for (const relativeFile of markdownFiles) {
  const absoluteFile = path.join(rootDir, relativeFile);
  const content = fs.readFileSync(absoluteFile, 'utf8');

  if (relativeFile.endsWith('.es.md')) {
    failures.push(`${relativeFile}: language-specific Markdown files are not allowed`);
  }

  if (shouldBeAsciiOnly(relativeFile) && /[^\x00-\x7F]/.test(content)) {
    const lines = content.split('\n');
    let firstLineNum = 0;
    let firstCodePoint = 0;
    outer: for (let li = 0; li < lines.length; li++) {
      for (const ch of lines[li]) {
        if (ch.codePointAt(0) > 0x7f) {
          firstLineNum = li + 1;
          firstCodePoint = ch.codePointAt(0);
          break outer;
        }
      }
    }
    const cpHex = firstCodePoint.toString(16).toUpperCase().padStart(4, '0');
    failures.push(
      `${relativeFile}:${firstLineNum}: non-ASCII character U+${cpHex} (expected ASCII-only English documentation)`
    );
  }

  for (const match of content.matchAll(markdownLinkPattern)) {
    const normalizedTarget = normalizeLinkTarget(match[1]);
    if (!normalizedTarget) {
      continue;
    }

    const resolvedPath = path.resolve(path.dirname(absoluteFile), normalizedTarget);
    if (!fs.existsSync(resolvedPath)) {
      failures.push(`${relativeFile}: broken link -> ${match[1]}`);
    }
  }

  if (content.includes('> Status: maintained')) {
    if (!content.includes('> Applies to:')) {
      failures.push(`${relativeFile}: maintained doc missing "> Applies to:" metadata`);
    }

    if (!content.includes('> Last verified:')) {
      failures.push(`${relativeFile}: maintained doc missing "> Last verified:" metadata`);
    }

    if (!content.includes('> Source of truth:')) {
      failures.push(`${relativeFile}: maintained doc missing "> Source of truth:" metadata`);
    }

    if (relativeFile.startsWith('docs/plans/')) {
      failures.push(`${relativeFile}: draft plans must not be marked as maintained`);
    }

    if (relativeFile !== docsIndexPath && !indexedDocs.has(relativeFile)) {
      failures.push(`${relativeFile}: maintained doc is not linked from docs/INDEX.md`);
    }
  }
}

if (failures.length > 0) {
  console.error('Documentation verification failed:\n');
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log(`Documentation verification passed for ${markdownFiles.length} Markdown files.`);
