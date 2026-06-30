/**
 * Export utilities for rules data.
 * Supports CSV and JSON formats with download functionality.
 */

import { getRuleTypeExportLabel, type Rule } from './rules';
import { toCsv } from './csv';
import { downloadFile } from './download';

/**
 * Convert rules to CSV format.
 * Columns: value, type, type_label, created_at
 */
export function rulesToCSV(rules: Rule[]): string {
  const header = ['value', 'type', 'type_label', 'created_at'];
  const rows = rules.map((rule) => {
    const typeLabel = getRuleTypeExportLabel(rule.type);
    const createdAt = rule.createdAt || '';
    return [rule.value, rule.type, typeLabel, createdAt];
  });

  return toCsv([header, ...rows]);
}

/**
 * Convert rules to JSON format.
 * Returns prettified JSON array.
 */
export function rulesToJSON(rules: Rule[]): string {
  const exportData = rules.map((rule) => ({
    value: rule.value,
    type: rule.type,
    typeLabel: getRuleTypeExportLabel(rule.type),
    createdAt: rule.createdAt || null,
  }));

  return JSON.stringify(exportData, null, 2);
}

/**
 * Convert rules to plain text format (one domain per line).
 * Optionally grouped by type.
 */
export function rulesToText(rules: Rule[], grouped = false): string {
  if (!grouped) {
    return rules.map((r) => r.value).join('\n');
  }

  const whitelist = rules.filter((r) => r.type === 'whitelist');
  const blockedSubdomain = rules.filter((r) => r.type === 'blocked_subdomain');
  const blockedPath = rules.filter((r) => r.type === 'blocked_path');
  const allowedPath = rules.filter((r) => r.type === 'allowed_path');

  const sections: string[] = [];

  if (whitelist.length > 0) {
    sections.push('## WHITELIST');
    sections.push(...whitelist.map((r) => r.value));
    sections.push('');
  }

  if (blockedSubdomain.length > 0) {
    sections.push('## BLOCKED-SUBDOMAINS');
    sections.push(...blockedSubdomain.map((r) => r.value));
    sections.push('');
  }

  if (blockedPath.length > 0) {
    sections.push('## BLOCKED-PATHS');
    sections.push(...blockedPath.map((r) => r.value));
    sections.push('');
  }

  if (allowedPath.length > 0) {
    sections.push('## ALLOWED-PATHS');
    sections.push(...allowedPath.map((r) => r.value));
    sections.push('');
  }

  return sections.join('\n').trim();
}

function sanitizeExportBasename(input: string): string {
  const trimmed = input.trim();
  if (!trimmed) return '';

  // Remove accents/diacritics and normalize to a safe, ASCII-ish filename.
  const withoutDiacritics = trimmed.normalize('NFKD').replace(/[\u0300-\u036f]/g, '');

  const lowered = withoutDiacritics.toLowerCase();
  const replaced = lowered
    .replace(/[^a-z0-9_-]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^[-.]+|[-.]+$/g, '');

  return replaced;
}

export function buildExportFilename(params: {
  format: 'csv' | 'json' | 'txt';
  filename?: string;
  dateStamp?: string;
}): string {
  const extension = params.format;
  const timestamp = params.dateStamp ?? new Date().toISOString().split('T')[0];
  const defaultBasename = `rules-${timestamp}`;

  const rawInput = params.filename ?? defaultBasename;
  const rawInputLower = rawInput.toLowerCase();
  const withoutExtension = rawInputLower.endsWith(`.${extension}`)
    ? rawInput.slice(0, -(extension.length + 1))
    : rawInput;

  const safeBase = sanitizeExportBasename(withoutExtension) || defaultBasename;
  return `${safeBase}.${extension}`;
}

/**
 * Export rules to a file and trigger download.
 */
export function exportRules(
  rules: Rule[],
  format: 'csv' | 'json' | 'txt',
  filename?: string
): void {
  let content: string;
  let mimeType: string;

  switch (format) {
    case 'csv':
      content = rulesToCSV(rules);
      mimeType = 'text/csv;charset=utf-8';
      break;
    case 'json':
      content = rulesToJSON(rules);
      mimeType = 'application/json;charset=utf-8';
      break;
    case 'txt':
      content = rulesToText(rules, true);
      mimeType = 'text/plain;charset=utf-8';
      break;
  }

  downloadFile(content, buildExportFilename({ format, filename }), mimeType);
}

export type ExportFormat = 'csv' | 'json' | 'txt';
