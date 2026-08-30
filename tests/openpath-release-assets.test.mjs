import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { describe, test } from 'node:test';

import { verifyGitHubReleaseAssets } from '../scripts/verify-openpath-release-assets.mjs';

describe('OpenPath GitHub Release asset verification', () => {
  test('accepts an existing release only when every authoritative asset matches bytes', () => {
    const localRoot = mkdtempSync(join(tmpdir(), 'openpath-release-local-'));
    const downloadedRoot = mkdtempSync(join(tmpdir(), 'openpath-release-downloaded-'));
    const expectedAssets = [
      { name: 'openpath-linux-v4.1.0.tar.gz', localPath: 'linux.tar.gz' },
      { name: 'openpath-linux-v4.1.0.tar.gz.sha256', localPath: 'linux.tar.gz.sha256' },
    ];
    for (const asset of expectedAssets) {
      const bytes = Buffer.from(`bytes:${asset.name}`);
      writeFileSync(join(localRoot, asset.localPath), bytes);
      writeFileSync(join(downloadedRoot, asset.name), bytes);
    }

    assert.deepEqual(
      verifyGitHubReleaseAssets({
        release: {
          tag_name: 'scripts-v4.1.0-0123456',
          assets: expectedAssets.map(({ name }) => ({ name })),
        },
        expectedTag: 'scripts-v4.1.0-0123456',
        expectedAssets,
        localRoot,
        downloadedRoot,
      }),
      { status: 'identical', assets: expectedAssets.map(({ name }) => name) }
    );
  });

  test('fails closed for missing or different authoritative assets', () => {
    const localRoot = mkdtempSync(join(tmpdir(), 'openpath-release-local-'));
    const downloadedRoot = mkdtempSync(join(tmpdir(), 'openpath-release-downloaded-'));
    const expectedAssets = [{ name: 'payload-manifest.json', localPath: 'payload-manifest.json' }];
    writeFileSync(join(localRoot, 'payload-manifest.json'), 'local\n');
    writeFileSync(join(downloadedRoot, 'payload-manifest.json'), 'remote\n');

    assert.throws(
      () =>
        verifyGitHubReleaseAssets({
          release: { tag_name: 'scripts-v4.1.0-0123456', assets: [] },
          expectedTag: 'scripts-v4.1.0-0123456',
          expectedAssets,
          localRoot,
          downloadedRoot,
        }),
      /missing authoritative asset/i
    );

    assert.throws(
      () =>
        verifyGitHubReleaseAssets({
          release: {
            tag_name: 'scripts-v4.1.0-0123456',
            assets: [{ name: 'payload-manifest.json' }],
          },
          expectedTag: 'scripts-v4.1.0-0123456',
          expectedAssets,
          localRoot,
          downloadedRoot,
        }),
      /different bytes/i
    );
  });
});
