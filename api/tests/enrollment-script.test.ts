import assert from 'node:assert/strict';
import { afterEach, describe, test } from 'node:test';

import { buildLinuxEnrollmentScript } from '../src/lib/enrollment-script.js';

const originalNodeEnv = process.env.NODE_ENV;

afterEach(() => {
  if (originalNodeEnv === undefined) {
    delete process.env.NODE_ENV;
  } else {
    process.env.NODE_ENV = originalNodeEnv;
  }
});

void describe('Linux enrollment bootstrap script generation', () => {
  void test('pins the requested linux agent version when one is available', () => {
    const script = buildLinuxEnrollmentScript({
      publicUrl: 'https://control.example',
      classroomId: 'cls_123',
      classroomName: 'Aula 1',
      enrollmentToken: 'token-123',
      aptRepoUrl: 'https://repo.example/apt',
      linuxAgentVersion: '4.1.10',
    });

    assert.match(script, /LINUX_AGENT_VERSION='4\.1\.10'/);
    assert.match(script, /--package-version "\$LINUX_AGENT_VERSION"/);
  });

  void test('omits package pinning when no published linux agent version should be forced', () => {
    const script = buildLinuxEnrollmentScript({
      publicUrl: 'https://control.example',
      classroomId: 'cls_123',
      classroomName: 'Aula 1',
      enrollmentToken: 'token-123',
      aptRepoUrl: 'https://repo.example/apt',
      linuxAgentVersion: '',
    });

    assert.doesNotMatch(script, /LINUX_AGENT_VERSION=/);
    assert.doesNotMatch(script, /--package-version "\$LINUX_AGENT_VERSION"/);
    assert.match(script, /bootstrap_cmd\+=\(--api-url "\$API_URL" --classroom "\$CLASSROOM_NAME"/);
  });

  void test('uses the unstable APT track when requested by release metadata', () => {
    const script = buildLinuxEnrollmentScript({
      publicUrl: 'https://control.example',
      classroomId: 'cls_123',
      classroomName: 'Aula 1',
      enrollmentToken: 'token-123',
      aptRepoUrl: 'https://repo.example/apt',
      linuxAgentVersion: '0.0.1380',
      linuxAgentAptSuite: 'unstable',
    });

    assert.match(script, /LINUX_AGENT_APT_SUITE='unstable'/);
    assert.match(script, /bootstrap_cmd\+=\(--unstable\)/);
    assert.match(script, /bootstrap_cmd\+=\(--package-version "\$LINUX_AGENT_VERSION"\)/);
  });

  void test('exports the selected APT repo URL for the downloaded bootstrap script', () => {
    const script = buildLinuxEnrollmentScript({
      publicUrl: 'https://control.example',
      classroomId: 'cls_123',
      classroomName: 'Aula 1',
      enrollmentToken: 'token-123',
      aptRepoUrl: 'https://repo.example/apt',
      linuxAgentVersion: '0.0.1380',
      linuxAgentAptSuite: 'unstable',
    });

    assert.match(script, /OPENPATH_APT_REPO_URL='https:\/\/repo\.example\/apt'/);
    assert.match(script, /curl -fsSL --proto '=https' --tlsv1\.2 "\$APT_BOOTSTRAP_URL"/);
  });

  void test('requires the final health check to pass before reporting success', () => {
    const script = buildLinuxEnrollmentScript({
      publicUrl: 'https://control.example',
      classroomId: 'cls_123',
      classroomName: 'Aula 1',
      enrollmentToken: 'token-123',
      aptRepoUrl: 'https://repo.example/apt',
      linuxAgentVersion: '',
    });

    assert.match(script, /\nopenpath health\n/);
    assert.doesNotMatch(script, /openpath health \|\| true/);
  });

  void test('rejects remote plain HTTP URLs outside test environments', () => {
    process.env.NODE_ENV = 'production';

    assert.throws(
      () =>
        buildLinuxEnrollmentScript({
          publicUrl: 'http://control.remote.example.net',
          classroomId: 'cls_123',
          classroomName: 'Aula 1',
          enrollmentToken: 'token-123',
          aptRepoUrl: 'https://repo.example/apt',
          linuxAgentVersion: '',
        }),
      /publicUrl must use HTTPS outside local or test environments/
    );

    assert.throws(
      () =>
        buildLinuxEnrollmentScript({
          publicUrl: 'https://control.example',
          classroomId: 'cls_123',
          classroomName: 'Aula 1',
          enrollmentToken: 'token-123',
          aptRepoUrl: 'http://repo.remote.example.net/apt',
          linuxAgentVersion: '',
        }),
      /aptRepoUrl must use HTTPS outside local or test environments/
    );
  });

  void test('allows local and fixture HTTP URLs for development and tests', () => {
    process.env.NODE_ENV = 'development';

    const localhostScript = buildLinuxEnrollmentScript({
      publicUrl: 'http://localhost:3000',
      classroomId: 'cls_123',
      classroomName: 'Aula 1',
      enrollmentToken: 'token-123',
      aptRepoUrl: 'http://127.0.0.1:8080/apt',
      linuxAgentVersion: '',
    });
    assert.match(localhostScript, /API_URL='http:\/\/localhost:3000'/);
    assert.match(
      localhostScript,
      /APT_BOOTSTRAP_URL='http:\/\/127\.0\.0\.1:8080\/apt\/apt-bootstrap\.sh'/
    );

    process.env.NODE_ENV = 'test';

    const testFixtureScript = buildLinuxEnrollmentScript({
      publicUrl: 'http://control.fixture.invalid',
      classroomId: 'cls_123',
      classroomName: 'Aula 1',
      enrollmentToken: 'token-123',
      aptRepoUrl: 'http://repo.fixture.invalid/apt',
      linuxAgentVersion: '',
    });
    assert.match(testFixtureScript, /API_URL='http:\/\/control\.fixture\.invalid'/);
  });
});
