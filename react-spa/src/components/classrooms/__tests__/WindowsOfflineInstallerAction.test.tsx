import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it, vi } from 'vitest';

import WindowsOfflineInstallerAction from '../WindowsOfflineInstallerAction';

const { generateMutate } = vi.hoisted(() => ({
  generateMutate: vi.fn(),
}));

vi.mock('../../../lib/trpc', () => ({
  trpc: {
    windowsOfflineInstaller: {
      generate: {
        mutate: (input: unknown): Promise<unknown> => generateMutate(input) as Promise<unknown>,
      },
    },
  },
}));

vi.mock('../../../i18n/product-i18n', () => ({
  useT: () => (key: string, params?: Record<string, string | number>) => {
    const messages: Record<string, string> = {
      'enroll.modal.windowsInstaller.linkAction': 'Download Windows installer (.exe)',
      'enroll.modal.windowsInstaller.generating': 'Generating installer…',
      'enroll.modal.windowsInstaller.retryAction': 'Retry download',
      'enroll.modal.windowsInstaller.regenerateAction': 'Generate a new installer',
      'enroll.modal.windowsInstaller.error': 'Could not generate the installer.',
      'enroll.modal.windowsInstaller.metadata': `v${String(params?.version)} · SHA-256 ${String(params?.sha256)}… · token expires ${String(params?.expiresAt)}`,
    };
    return messages[key] ?? key;
  },
}));

function buildResult(downloadUrl: string) {
  return {
    fileName: 'OpenPath-Lab-Windows-Setup.exe',
    version: '4.1.0',
    sha256: 'a'.repeat(64),
    tokenExpiresAt: '2026-08-25T20:00:00.000Z',
    downloadUrl,
    downloadExpiresAt: '2026-08-25T19:45:00.000Z',
  };
}

afterEach(() => {
  vi.restoreAllMocks();
  generateMutate.mockReset();
});

describe('WindowsOfflineInstallerAction', () => {
  it('shows a visible user-activated link without generating on mount', () => {
    const click = vi
      .spyOn(HTMLAnchorElement.prototype, 'click')
      .mockImplementation(() => undefined);

    render(<WindowsOfflineInstallerAction classroomId="classroom-mount" />);

    expect(
      screen.getByRole('link', { name: 'Download Windows installer (.exe)' })
    ).not.toHaveAttribute('href');
    expect(generateMutate).not.toHaveBeenCalled();
    expect(click).not.toHaveBeenCalled();
  });

  it('leaves a visible download link and generates a fresh reference on explicit regeneration', async () => {
    const click = vi
      .spyOn(HTMLAnchorElement.prototype, 'click')
      .mockImplementation(() => undefined);
    generateMutate
      .mockResolvedValueOnce(buildResult('/api/windows-offline-installer/download?ref=A'))
      .mockResolvedValueOnce(buildResult('/api/windows-offline-installer/download?ref=B'));

    const user = userEvent.setup();
    render(<WindowsOfflineInstallerAction classroomId="classroom-cache" />);
    const link = screen.getByRole('link', { name: 'Download Windows installer (.exe)' });

    await user.click(link);
    await waitFor(() =>
      expect(link).toHaveAttribute('href', '/api/windows-offline-installer/download?ref=A')
    );
    expect(click).not.toHaveBeenCalled();

    await user.click(screen.getByRole('button', { name: 'Generate a new installer' }));
    await waitFor(() =>
      expect(link).toHaveAttribute('href', '/api/windows-offline-installer/download?ref=B')
    );
    expect(generateMutate).toHaveBeenNthCalledWith(1, { classroomId: 'classroom-cache' });
    expect(generateMutate).toHaveBeenNthCalledWith(2, { classroomId: 'classroom-cache' });
  });

  it('turns generation errors into a localized retry action', async () => {
    generateMutate.mockRejectedValueOnce(new Error('network'));
    const user = userEvent.setup();
    render(<WindowsOfflineInstallerAction classroomId="classroom-error" />);

    await user.click(screen.getByRole('link', { name: 'Download Windows installer (.exe)' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Could not generate the installer.');
    expect(screen.getByRole('link', { name: 'Retry download' })).toBeInTheDocument();
  });
});
