// Phase 8: contract for the native host signing channel.
//
// The workflow source is read as text (docs/contract-tests.md): the signing
// channel is user-gated (code-signing environment secret + variables) and this
// suite proves the workflow can only run on main, only on GitHub-hosted
// runners, never on pull requests, only through the commit-pinned SignPath
// action, and only after searching for an already-signed source hash. The
// native host assembly metadata is pinned here too because the SignPath
// artifact configuration enforces the product name and version.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readText } from './support.mjs';

const WORKFLOW = '.github/workflows/native-host-signing.yml';
const ACTION_PIN =
  'signpath/github-action-submit-signing-request@f6d04783b4569d051e0c80105fe66e82819d0092';

test('signing workflow only runs on main, on hosted runners, with the code-signing environment', () => {
  const workflow = readText(WORKFLOW);

  assert.ok(workflow.includes('branches: [main]'), 'the push trigger must be limited to main');
  assert.ok(
    !workflow.includes('pull_request'),
    'the signing channel must never run for pull requests'
  );
  assert.ok(
    !workflow.includes('self-hosted'),
    'SignPath OSS requires every job to run on GitHub-hosted runners'
  );
  assert.ok(workflow.includes('runs-on: windows-latest'), 'hosted Windows runner required');
  assert.ok(
    workflow.includes('environment: code-signing'),
    'the secret must come from the code-signing environment (main only)'
  );
  assert.ok(
    workflow.includes(
      "github.repository == 'balejosg/OpenPath' && github.ref == 'refs/heads/main'"
    ),
    'the job must fail closed outside the canonical repository and main'
  );
});

test('signing workflow submits through the pinned SignPath action by artifact id', () => {
  const workflow = readText(WORKFLOW);

  assert.ok(
    workflow.includes(ACTION_PIN),
    'the SignPath submit action must be pinned by commit SHA'
  );
  assert.ok(
    !/signpath\/github-action-submit-signing-request@v\d/u.test(workflow),
    'a floating action tag must never be used for the signing channel'
  );
  assert.ok(
    workflow.includes('actions/upload-artifact@v7'),
    'the artifact must be uploaded with actions/upload-artifact before submission'
  );
  assert.ok(
    workflow.includes('github-artifact-id: ${{ steps.upload.outputs.artifact-id }}'),
    'the submission must reference the uploaded artifact id'
  );
});

test('signing workflow searches for an existing signed hash before signing again', () => {
  const workflow = readText(WORKFLOW);

  assert.ok(
    workflow.includes('releases/tags/native-host-signing'),
    'the rolling signing release is the durable storage for signed assets'
  );
  assert.ok(
    workflow.includes('OpenPath-NativeHost-$sourceSha.exe'),
    'the existence probe must check the asset named by the current source hash'
  );
  assert.ok(workflow.includes('signed_exists'), 'the probe result must gate the job steps');
  assert.ok(
    workflow.includes("steps.state.outputs.signed_exists == 'false'"),
    'compile, submit and collect must only run when no signed asset exists'
  );
  assert.ok(
    workflow.includes('signing_request_id'),
    'a failed collect must be recoverable by dispatching the existing request id'
  );
});

test('signing workflow probes the release without leaving a failing native exit code', () => {
  const workflow = readText(WORKFLOW);

  // The Actions pwsh wrapper appends `exit $LASTEXITCODE`; a deliberately
  // failing native probe (a missing release) would fail the whole step without
  // any error text. The probe must be a catchable PowerShell call and the
  // script must not end with a stale failing exit code.
  assert.ok(
    workflow.includes('Invoke-RestMethod'),
    'the existence probe must use a catchable PowerShell call, not a failing native command'
  );
  assert.ok(
    !workflow.includes('gh api "repos/${{ github.repository }}/releases/tags/native-host-signing"'),
    'the release probe must not fail through the native gh exit code'
  );
  assert.ok(
    workflow.includes('$LASTEXITCODE = 0'),
    'the workflow must reset a tolerated native exit code before the step ends'
  );
});

test('signing workflow skips the signature visibly when the secret is absent', () => {
  const workflow = readText(WORKFLOW);

  assert.ok(
    workflow.includes("SIGNPATH_CONFIGURED: ${{ secrets.SIGNPATH_API_TOKEN != ''"),
    'the workflow must detect the configured signing channel through the environment'
  );
  assert.ok(
    workflow.includes("if: env.SIGNPATH_CONFIGURED == 'false'"),
    'the skip notice must run when the channel is not configured'
  );
  assert.ok(
    workflow.includes('::warning title=Native host signing skipped::'),
    'the skip must be visible in the run annotations'
  );
  assert.ok(
    workflow.includes("if: env.SIGNPATH_CONFIGURED == 'true'"),
    'submit and collect must be gated on the configured signing channel'
  );
});

test('native host assembly metadata pins the product name and one version per build', () => {
  const source = readText('windows/native-host/OpenPathNativeHost.cs');

  assert.match(source, /\[assembly: AssemblyProduct\("OpenPath"\)\]/u);
  assert.match(source, /\[assembly: AssemblyTitle\("OpenPath Native Host"\)\]/u);
  const version = source.match(/\[assembly: AssemblyVersion\("(\d+\.\d+\.\d+\.\d+)"\)\]/u);
  const fileVersion = source.match(/\[assembly: AssemblyFileVersion\("(\d+\.\d+\.\d+\.\d+)"\)\]/u);
  assert.ok(version && fileVersion, 'both assembly version attributes must be present');
  assert.equal(
    version[1],
    fileVersion[1],
    'all product version attributes must carry the same value in every build'
  );
  assert.match(
    source,
    /\[assembly: AssemblyInformationalVersion\("([^"]+)"\)\]/u,
    'the informational version must be set for the artifact configuration'
  );
});
