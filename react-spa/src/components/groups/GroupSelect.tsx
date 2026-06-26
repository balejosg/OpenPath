import React, { useMemo } from 'react';
import { cn } from '../../lib/utils';
import { isGroupEnabled, type GroupLike } from './GroupLabel';
import { useT } from '../../i18n/product-i18n';

type InactiveBehavior = 'hide' | 'disable';

export interface GroupSelectProps {
  id: string;
  value: string;
  onChange: (next: string) => void;
  groups: readonly GroupLike[];

  includeNoneOption?: boolean;
  noneLabel?: string;

  inactiveBehavior?: InactiveBehavior;

  unknownValueLabel?: string;
  unknownValueDisabled?: boolean;

  emptyLabel?: string;

  disabled?: boolean;
  className?: string;
}

export const GroupSelect: React.FC<GroupSelectProps> = ({
  id,
  value,
  onChange,
  groups,
  includeNoneOption = true,
  noneLabel,
  inactiveBehavior = 'hide',
  unknownValueLabel,
  unknownValueDisabled = true,
  emptyLabel,
  disabled,
  className,
}) => {
  const t = useT();
  const resolvedNoneLabel = noneLabel ?? t('groups.select.noneLabel');
  const resolvedEmptyLabel = emptyLabel ?? t('groups.select.emptyLabel');
  const options = useMemo(() => {
    const groupIds = new Set(groups.map((g) => g.id));
    const opts: { value: string; label: string; disabled?: boolean }[] = [];

    if (includeNoneOption) {
      opts.push({ value: '', label: resolvedNoneLabel });
    }

    if (value && !groupIds.has(value)) {
      opts.push({
        value,
        label: unknownValueLabel ?? value,
        disabled: unknownValueDisabled,
      });
    }

    const filtered =
      inactiveBehavior === 'hide' ? groups.filter((g) => isGroupEnabled(g)) : [...groups];

    if (!includeNoneOption && filtered.length === 0) {
      opts.push({ value: '', label: resolvedEmptyLabel, disabled: true });
      return opts;
    }

    for (const g of filtered) {
      const enabled = isGroupEnabled(g);
      const base = g.displayName ?? g.name;
      const label =
        !enabled && inactiveBehavior === 'disable'
          ? `${base} ${t('groups.select.inactiveSuffix')}`
          : base;
      opts.push({
        value: g.id,
        label,
        disabled: !enabled && inactiveBehavior === 'disable',
      });
    }

    return opts;
  }, [
    groups,
    includeNoneOption,
    resolvedNoneLabel,
    inactiveBehavior,
    value,
    unknownValueLabel,
    unknownValueDisabled,
    resolvedEmptyLabel,
    t,
  ]);

  return (
    <select
      id={id}
      value={value}
      onChange={(e) => onChange(e.target.value)}
      disabled={disabled}
      className={cn(className)}
    >
      {options.map((o) => (
        <option key={o.value !== '' ? o.value : o.label} value={o.value} disabled={o.disabled}>
          {o.label}
        </option>
      ))}
    </select>
  );
};
