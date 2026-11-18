// Contract for the manual Windows canary publication workflow.
// Guarded files: .github/workflows/publish-windows-canary.yml,
// scripts/build-windows-agent-release.mjs.
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { describe, test } from 'node:test';

import { extractWorkflowJobBlock, projectRoot, readText } from './repo-config/support.mjs';

const WORKFLOW_PATH = '.github/workflows/publish-windows-canary.yml';
const SCRIPT_PATH = 'scripts/build-windows-agent-release.mjs';

describe('publish Windows canary workflow contract', () => {
  test('is manual dispatch only and requires an exact SHA', () => {
    const workflow = readText(WORKFLOW_PATH);

    assert.match(workflow, /^on:\n {2}workflow_dispatch:/m);
    assert.doesNotMatch(workflow, /^ {2}push:/m);
    assert.match(workflow, /inputs:\n {6}sha:\n/);
    assert.match(workflow, /required: true/);
    assert.match(workflow, /ref: \$\{\{ inputs\.sha \}\}/);
  });

  test('publication depends on a successful Windows Pester run for that SHA', () => {
    const workflow = readText(WORKFLOW_PATH);
    const gate = extractWorkflowJobBlock(workflow, 'require-windows-pester');
    const build = extractWorkflowJobBlock(workflow, 'build');
    const publish = extractWorkflowJobBlock(workflow, 'sign-and-publish');

    assert.match(gate, /head_sha=\$\{TARGET_SHA\}/);
    assert.match(gate, /conclusion == "success"/);
    assert.match(gate, /Windows Agent Tests/);
    assert.match(build, /needs: require-windows-pester/);
    assert.match(publish, /needs: build/);
  });

  test('the signing key is available only in the protected environment job', () => {
    const workflow = readText(WORKFLOW_PATH);
    const build = extractWorkflowJobBlock(workflow, 'build');
    const publish = extractWorkflowJobBlock(workflow, 'sign-and-publish');

    assert.match(publish, /environment: windows-canary-release/);
    assert.match(publish, /secrets\.OPENPATH_AGENT_RELEASE_SIGNING_KEY/);
    assert.match(publish, /openssl dgst -sha256 -sign/);
    assert.match(publish, /--publish-only/);
    assert.match(publish, /secrets\.OPENPATH_AGENT_RELEASE_TOKEN/);
    assert.doesNotMatch(build, /OPENPATH_AGENT_RELEASE_SIGNING_KEY/);
    assert.doesNotMatch(build, /OPENPATH_AGENT_RELEASE_TOKEN/);
    assert.equal((workflow.match(/secrets\.OPENPATH_AGENT_RELEASE_SIGNING_KEY/g) ?? []).length, 1);
  });

  test('builds the same file set the API serves and prints the build', () => {
    const workflow = readText(WORKFLOW_PATH);
    const script = readText(SCRIPT_PATH);

    assert.ok(existsSync(`${projectRoot}/${SCRIPT_PATH}`));
    assert.match(workflow, /build-windows-agent-release\.mjs/);
    assert.match(workflow, /--out "\$RUNNER_TEMP\/canary-release"/);
    assert.match(script, /buildWindowsAgentFileManifest/);
    assert.match(script, /openpath-agent-release-v1/);
    assert.match(script, /files\.sort\(\(left, right\)/);
    assert.match(script, /computeBuild/);
    assert.match(script, /contentBase64/);
    assert.match(script, /console\.log\(`build=\$\{build\}`\)/);
  });
});
