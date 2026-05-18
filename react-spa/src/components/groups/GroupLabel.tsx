import React from 'react';
import type { CurrentGroupSource } from '../../types';
import { cn } from '../../lib/utils';
import { isGroupEnabledLike } from '../../lib/groups';

export interface GroupLike {
  id: string;
  name: string;
  displayName?: string | null;
  enabled?: boolean | number | null;
  status?: string | null;
}

export function toDisplayOnlyGroup(
  groupId: string | null | undefined,
  displayName?: string | null
): GroupLike | null {
  if (!groupId || !displayName) return null;

  return {
    id: groupId,
    name: displayName,
    displayName,
  };
}

export function resolveGroupLike(params: {
  groupId: string | null | undefined;
  groupById: ReadonlyMap<string, GroupLike>;
  displayName?: string | null;
}): GroupLike | null {
  const { groupId, groupById, displayName } = params;
  if (!groupId) return null;

  return groupById.get(groupId) ?? toDisplayOnlyGroup(groupId, displayName);
}

export function isGroupEnabled(group: GroupLike): boolean {
  return isGroupEnabledLike(group);
}

export function inferGroupSource(input: {
  currentGroupSource?: CurrentGroupSource | null;
  activeGroupId?: string | null;
  currentGroupId?: string | null;
  defaultGroupId?: string | null;
}): CurrentGroupSource {
  if (input.currentGroupSource) return input.currentGroupSource;
  if (input.activeGroupId) return 'manual';
  if (!input.currentGroupId) return 'none';
  if (input.defaultGroupId && input.currentGroupId === input.defaultGroupId) return 'default';
  return 'schedule';
}

export interface ClassroomGroupSelectInput {
  activeGroup: string | null;
  currentGroupId: string | null;
  currentGroupSource?: CurrentGroupSource;
  defaultGroupId: string | null;
}

export interface ClassroomGroupSelectState {
  source: CurrentGroupSource;
  activeGroupValue: string;
  defaultGroupValue: string;
}

export function resolveClassroomGroupSelectState(params: {
  classroom: ClassroomGroupSelectInput | null;
  admin: boolean;
}): ClassroomGroupSelectState {
  const { classroom, admin } = params;

  if (!classroom) {
    return {
      source: 'none',
      activeGroupValue: '',
      defaultGroupValue: '',
    };
  }

  const source = inferGroupSource({
    currentGroupSource: classroom.currentGroupSource ?? null,
    activeGroupId: classroom.activeGroup,
    currentGroupId: classroom.currentGroupId,
    defaultGroupId: classroom.defaultGroupId,
  });

  let activeGroupValue = classroom.activeGroup ?? '';
  if (!activeGroupValue && !admin && source === 'manual' && classroom.currentGroupId) {
    activeGroupValue = classroom.currentGroupId;
  }

  let defaultGroupValue = classroom.defaultGroupId ?? '';
  if (!defaultGroupValue && !admin && source === 'default' && classroom.currentGroupId) {
    defaultGroupValue = classroom.currentGroupId;
  }

  return {
    source,
    activeGroupValue,
    defaultGroupValue,
  };
}

export function getGroupSourceTag(source: CurrentGroupSource): string {
  if (source === 'manual') return 'manual';
  if (source === 'schedule') return 'schedule';
  if (source === 'default') return 'default';
  return '';
}

export function getGroupSourcePhrase(source: CurrentGroupSource): string {
  if (source === 'default') return 'by default';
  if (source === 'schedule') return 'by schedule';
  if (source === 'manual') return 'manual';
  return '';
}

export function resolveGroupDisplayName(params: {
  groupId: string | null | undefined;
  group?: GroupLike | null;
  source: CurrentGroupSource;
  revealUnknownId?: boolean;
  noneLabel?: string;
}): string {
  const { groupId, group, source, revealUnknownId, noneLabel } = params;

  if (!groupId) return noneLabel ?? 'No group';
  if (group) return group.displayName ?? group.name;
  if (revealUnknownId) return groupId;

  if (source === 'manual') return 'Applied by another teacher';
  if (source === 'default') return 'Assigned by admin';
  if (source === 'schedule') return 'Reserved by another teacher';

  return 'Group unavailable';
}

export function resolveGroupDisplayNameFromLookup(params: {
  groupId: string | null | undefined;
  groupById: ReadonlyMap<string, GroupLike>;
  displayName?: string | null;
  source: CurrentGroupSource;
  revealUnknownId?: boolean;
  noneLabel?: string;
}): string {
  const { groupId, groupById, displayName, source, revealUnknownId, noneLabel } = params;

  return resolveGroupDisplayName({
    groupId,
    group: resolveGroupLike({ groupId, groupById, displayName }),
    source,
    revealUnknownId,
    noneLabel,
  });
}

export function getGroupBadgeVariant(source: CurrentGroupSource, enabled: boolean): string {
  if (!enabled) return 'bg-slate-100 text-slate-600 border-slate-200';

  if (source === 'manual') return 'bg-blue-50 text-blue-700 border-blue-200';
  if (source === 'schedule') return 'bg-amber-50 text-amber-700 border-amber-200';
  if (source === 'default') return 'bg-emerald-50 text-emerald-700 border-emerald-200';
  return 'bg-slate-100 text-slate-500 border-slate-200';
}

export interface GroupLabelProps {
  groupId: string | null | undefined;
  group?: GroupLike | null;
  source: CurrentGroupSource;
  revealUnknownId?: boolean;
  noneLabel?: string;

  variant?: 'badge' | 'text';
  showSourceTag?: boolean;
  showInactiveTag?: boolean;
  className?: string;
  title?: string;
}

export const GroupLabel: React.FC<GroupLabelProps> = ({
  groupId,
  group,
  source,
  revealUnknownId,
  noneLabel,
  variant = 'badge',
  showSourceTag = true,
  showInactiveTag = false,
  className,
  title,
}) => {
  const enabled = group ? isGroupEnabled(group) : true;
  const name = resolveGroupDisplayName({ groupId, group, source, revealUnknownId, noneLabel });

  const parts: string[] = [name];
  const sourceTag = showSourceTag ? getGroupSourceTag(source) : '';
  if (sourceTag) parts.push(sourceTag);
  if (showInactiveTag && !enabled) parts.push('inactive');
  const text = parts.join(' · ');

  if (variant === 'text') {
    return (
      <span className={className} title={title}>
        {text}
      </span>
    );
  }

  return (
    <span
      className={cn(
        'px-2 py-0.5 rounded-full border',
        getGroupBadgeVariant(source, enabled),
        className
      )}
      title={title}
    >
      {text}
    </span>
  );
};
