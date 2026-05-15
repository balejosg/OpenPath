#!/usr/bin/env node
import { readFileSync } from 'node:fs';

function usage() {
  console.error('Usage: node scripts/check-npm-audit-critical.mjs <audit-report.json>');
}

function fail(message) {
  console.error(`npm audit critical check failed: ${message}`);
  process.exit(1);
}

const reportPath = process.argv[2];

if (!reportPath || process.argv.length > 3) {
  usage();
  process.exit(1);
}

let report;
try {
  report = JSON.parse(readFileSync(reportPath, 'utf8'));
} catch (error) {
  fail(`could not read valid JSON from ${reportPath}: ${error.message}`);
}

const vulnerabilities = report?.metadata?.vulnerabilities;

if (!vulnerabilities || typeof vulnerabilities !== 'object') {
  fail('missing metadata.vulnerabilities from npm audit JSON');
}

const critical = vulnerabilities.critical;
const high = vulnerabilities.high;

if (!Number.isInteger(critical) || critical < 0) {
  fail('metadata.vulnerabilities.critical must be a non-negative integer');
}

if (high !== undefined && (!Number.isInteger(high) || high < 0)) {
  fail('metadata.vulnerabilities.high must be a non-negative integer when present');
}

if (critical > 0) {
  fail(`found ${critical} critical npm audit vulnerabilities`);
}

const highSummary = Number.isInteger(high) ? ` high=${high}` : '';
console.log(`npm audit critical check passed: critical=${critical}${highSummary}`);
