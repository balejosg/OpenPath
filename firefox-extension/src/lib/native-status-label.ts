import { t } from './i18n.js';

export function formatNativeHostStatusLabel(input: {
  available: boolean;
  version?: string | null | undefined;
}): string {
  if (!input.available) {
    return t('popupNativeHostUnavailable');
  }

  const version = input.version?.trim();
  return version ? t('popupNativeHostVersion', version) : t('popupNativeHostAvailable');
}
