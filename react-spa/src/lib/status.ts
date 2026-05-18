export const ACTIVE_INACTIVE_LABELS = {
  Active: 'Active',
  Inactive: 'Inactive',
} as const;

export type ActiveInactiveStatus = keyof typeof ACTIVE_INACTIVE_LABELS;

export function normalizeActiveInactiveStatus(value: unknown): ActiveInactiveStatus | null {
  if (value === 'Active' || value === 'Inactive') return value;
  if (typeof value !== 'string') return null;

  const lowered = value.toLowerCase();
  if (lowered === 'active') return 'Active';
  if (lowered === 'inactive') return 'Inactive';
  return null;
}

export function getActiveInactiveLabel(status: ActiveInactiveStatus): string {
  return ACTIVE_INACTIVE_LABELS[status];
}

export function getActiveInactiveLabelSafe(value: unknown, fallback = 'Unknown'): string {
  const normalized = normalizeActiveInactiveStatus(value);
  if (!normalized) return fallback;
  return getActiveInactiveLabel(normalized);
}

export const ACTIVE_INACTIVE_LABELS_ES = ACTIVE_INACTIVE_LABELS;
export const getEsActiveInactiveLabel = getActiveInactiveLabel;
export const getEsActiveInactiveLabelSafe = getActiveInactiveLabelSafe;
