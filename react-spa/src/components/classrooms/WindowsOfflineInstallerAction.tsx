import React, { useEffect, useState } from 'react';

import { useT } from '../../i18n/product-i18n';
import { trpc } from '../../lib/trpc';

interface Props {
  classroomId: string;
}

interface InstallerResult {
  fileName: string;
  version: string;
  sha256: string;
  tokenExpiresAt: string;
  downloadUrl: string;
  downloadExpiresAt: string;
}

interface InstallerMetadata {
  fileName: string;
  version: string;
  sha256: string;
  tokenExpiresAt: string;
}

type Progress = 'idle' | 'generating' | 'ready' | 'error';

export default function WindowsOfflineInstallerAction({ classroomId }: Props): React.ReactElement {
  const t = useT();
  const [progress, setProgress] = useState<Progress>('idle');
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<InstallerMetadata | null>(null);
  const [downloadHref, setDownloadHref] = useState<string | undefined>();

  useEffect(() => {
    setProgress('idle');
    setError(null);
    setResult(null);
    setDownloadHref(undefined);
  }, [classroomId]);

  const generateInstaller = (): void => {
    setError(null);
    setResult(null);
    setDownloadHref(undefined);
    setProgress('generating');

    void trpc.windowsOfflineInstaller.generate
      .mutate({ classroomId })
      .then((nextResult: InstallerResult) => {
        setResult({
          fileName: nextResult.fileName,
          version: nextResult.version,
          sha256: nextResult.sha256,
          tokenExpiresAt: nextResult.tokenExpiresAt,
        });
        setDownloadHref(nextResult.downloadUrl);
        setProgress('ready');
      })
      .catch(() => {
        setResult(null);
        setDownloadHref(undefined);
        setError(t('enroll.modal.windowsInstaller.error'));
        setProgress('error');
      });
  };

  const isGenerating = progress === 'generating';
  const linkLabel = isGenerating
    ? t('enroll.modal.windowsInstaller.generating')
    : progress === 'error'
      ? t('enroll.modal.windowsInstaller.retryAction')
      : t('enroll.modal.windowsInstaller.linkAction');

  const handleDownloadClick = (event: React.MouseEvent<HTMLAnchorElement>): void => {
    if (downloadHref) return;
    event.preventDefault();
    if (isGenerating) return;
    generateInstaller();
  };

  const handleDownloadKeyDown = (event: React.KeyboardEvent<HTMLAnchorElement>): void => {
    if (event.key !== 'Enter' && event.key !== ' ') return;
    event.preventDefault();
    event.currentTarget.click();
  };

  return (
    <div className="flex flex-col items-end gap-1" data-testid="windows-offline-installer-action">
      <a
        href={downloadHref}
        download={result?.fileName}
        role="link"
        aria-disabled={isGenerating ? 'true' : undefined}
        tabIndex={isGenerating ? -1 : 0}
        onClick={handleDownloadClick}
        onKeyDown={handleDownloadKeyDown}
        className={`text-xs font-medium underline underline-offset-2 transition-colors ${
          isGenerating
            ? 'pointer-events-none cursor-wait text-slate-400'
            : 'cursor-pointer text-blue-600 hover:text-blue-700'
        }`}
      >
        {linkLabel}
      </a>
      {isGenerating ? (
        <span className="text-[11px] text-slate-500">
          {t('enroll.modal.windowsInstaller.generating')}
        </span>
      ) : null}
      {error ? (
        <span role="alert" className="text-[11px] text-red-600">
          {error}
        </span>
      ) : null}
      {result ? (
        <>
          <span
            className="max-w-md text-right text-[11px] text-slate-500"
            data-testid="windows-offline-installer-metadata"
          >
            {t('enroll.modal.windowsInstaller.metadata', {
              version: result.version,
              sha256: result.sha256.slice(0, 12),
              expiresAt: result.tokenExpiresAt,
            })}
          </span>
          <button
            type="button"
            onClick={generateInstaller}
            className="text-[11px] text-slate-500 underline underline-offset-2 hover:text-slate-700"
          >
            {t('enroll.modal.windowsInstaller.regenerateAction')}
          </button>
        </>
      ) : null}
    </div>
  );
}
