import { Browser } from 'webextension-polyfill';

declare global {
  const browser: Browser;

  type DomainStatusState =
    | 'detected'
    | 'pending'
    | 'autoApproved'
    | 'duplicate'
    | 'localUpdateError'
    | 'apiError';

  interface DomainStatus {
    state: DomainStatusState;
    updatedAt: number;
    message?: string;
    messageKey?: string;
    requestType?: string;
  }
}
