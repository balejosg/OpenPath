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

  it('generates and navigates with a fresh ephemeral reference on every click', async () => {
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(function (
      this: HTMLAnchorElement
    ) {
      const href = this.getAttribute('href');
      if (href) navigatedHrefs.push(href);
    });
    generateMutate
      .mockResolvedValueOnce(buildResult('/api/windows-offline-installer/download?ref=A'))
      .mockResolvedValueOnce(buildResult('/api/windows-offline-installer/download?ref=B'));
    const navigatedHrefs: string[] = [];

    const user = userEvent.setup();
    render(<WindowsOfflineInstallerAction classroomId="classroom-cache" />);
    const link = screen.getByRole('link', { name: 'Download Windows installer (.exe)' });

    await user.click(link);
    await waitFor(() =>
      expect(navigatedHrefs).toEqual(['/api/windows-offline-installer/download?ref=A'])
    );
    expect(link).not.toHaveAttribute('href');
    expect(document.querySelectorAll('a[href*="windows-offline-installer/download"]').length).toBe(
      0
    );

    await user.click(link);
    await waitFor(() =>
      expect(navigatedHrefs).toEqual([
        '/api/windows-offline-installer/download?ref=A',
        '/api/windows-offline-installer/download?ref=B',
      ])
    );
    expect(generateMutate).toHaveBeenNthCalledWith(1, { classroomId: 'classroom-cache' });
    expect(generateMutate).toHaveBeenNthCalledWith(2, { classroomId: 'classroom-cache' });
    expect(link).not.toHaveAttribute('href');
    expect(click).toHaveBeenCalledTimes(2);
  });

  it('turns generation errors into a retry that requests a fresh reference', async () => {
    generateMutate.mockRejectedValueOnce(new Error('network'));
    generateMutate.mockResolvedValueOnce(
      buildResult('/api/windows-offline-installer/download?ref=retry')
    );
    const navigatedHrefs: string[] = [];
    vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(function (
      this: HTMLAnchorElement
    ) {
      const href = this.getAttribute('href');
      if (href) navigatedHrefs.push(href);
    });
    const user = userEvent.setup();
    render(<WindowsOfflineInstallerAction classroomId="classroom-error" />);

    await user.click(screen.getByRole('link', { name: 'Download Windows installer (.exe)' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Could not generate the installer.');
    const retry = screen.getByRole('link', { name: 'Retry download' });
    expect(retry).not.toHaveAttribute('href');
    await user.click(retry);
    await waitFor(() =>
      expect(navigatedHrefs).toEqual(['/api/windows-offline-installer/download?ref=retry'])
    );
    expect(generateMutate).toHaveBeenCalledTimes(2);
    expect(retry).not.toHaveAttribute('href');
  });

  it('drops stale generation metadata when the classroom changes', async () => {
    let resolveFirst: ((value: unknown) => void) | undefined;
    generateMutate.mockReturnValueOnce(
      new Promise((resolve) => {
        resolveFirst = resolve;
      })
    );
    generateMutate.mockResolvedValueOnce(
      buildResult('/api/windows-offline-installer/download?ref=B')
    );
    const navigatedHrefs: string[] = [];
    vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(function (
      this: HTMLAnchorElement
    ) {
      const href = this.getAttribute('href');
      if (href) navigatedHrefs.push(href);
    });
    const user = userEvent.setup();
    const view = render(<WindowsOfflineInstallerAction classroomId="classroom-A" />);

    await user.click(screen.getByRole('link', { name: 'Download Windows installer (.exe)' }));
    view.rerender(<WindowsOfflineInstallerAction classroomId="classroom-B" />);
    expect(screen.queryByTestId('windows-offline-installer-metadata')).not.toBeInTheDocument();
    expect(
      screen.getByRole('link', { name: 'Download Windows installer (.exe)' })
    ).not.toHaveAttribute('href');

    resolveFirst?.(buildResult('/api/windows-offline-installer/download?ref=A'));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(navigatedHrefs).toEqual([]);
    expect(screen.queryByTestId('windows-offline-installer-metadata')).not.toBeInTheDocument();

    await user.click(screen.getByRole('link', { name: 'Download Windows installer (.exe)' }));
    await waitFor(() =>
      expect(navigatedHrefs).toEqual(['/api/windows-offline-installer/download?ref=B'])
    );
  });
});
