import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import {
  GroupLabel,
  resolveClassroomGroupSelectState,
  resolveGroupDisplayName,
  resolveGroupDisplayNameFromLookup,
  resolveGroupLike,
  toDisplayOnlyGroup,
} from '../GroupLabel';
import { translateProductText } from '../../../i18n/product-i18n';

const t = (
  key: Parameters<typeof translateProductText>[1],
  params?: Parameters<typeof translateProductText>[2]
) => translateProductText('en', key, params);

describe('GroupLabel', () => {
  it('renders a known group displayName', () => {
    render(
      <GroupLabel
        groupId="g1"
        group={{ id: 'g1', name: 'n1', displayName: 'Grupo Uno', enabled: true }}
        source="default"
      />
    );

    expect(screen.getByText('Grupo Uno · default')).toBeInTheDocument();
  });

  it('redacts unknown group ids for non-admin users based on source', () => {
    render(<GroupLabel groupId="secret" source="schedule" />);
    expect(screen.getByText('Reserved by another teacher · schedule')).toBeInTheDocument();
  });

  it('reveals unknown group id when requested', () => {
    render(<GroupLabel groupId="secret" source="schedule" revealUnknownId />);
    expect(screen.getByText('secret · schedule')).toBeInTheDocument();
  });
});

describe('resolveGroupDisplayName', () => {
  it('uses noneLabel when groupId is empty', () => {
    const name = resolveGroupDisplayName({ groupId: '', source: 'none', noneLabel: 'No group', t });
    expect(name).toBe('No group');
  });
});

describe('display-only group helpers', () => {
  it('creates a synthetic group when only display metadata is available', () => {
    expect(toDisplayOnlyGroup('hidden-group', 'Plan Visible')).toEqual({
      id: 'hidden-group',
      name: 'Plan Visible',
      displayName: 'Plan Visible',
    });
  });

  it('resolves a group from lookup metadata when the map does not contain it', () => {
    const group = resolveGroupLike({
      groupId: 'hidden-group',
      groupById: new Map(),
      displayName: 'Plan Visible',
    });

    expect(group).toEqual({
      id: 'hidden-group',
      name: 'Plan Visible',
      displayName: 'Plan Visible',
    });
  });

  it('resolves display text from lookup metadata before using fallback copy', () => {
    const name = resolveGroupDisplayNameFromLookup({
      groupId: 'hidden-group',
      groupById: new Map(),
      displayName: 'Plan Visible',
      source: 'schedule',
      t,
    });

    expect(name).toBe('Plan Visible');
  });
});

describe('resolveClassroomGroupSelectState', () => {
  it('returns empty values for no classroom selection', () => {
    const state = resolveClassroomGroupSelectState({ classroom: null, admin: false });

    expect(state).toEqual({
      source: 'none',
      activeGroupValue: '',
      defaultGroupValue: '',
    });
  });

  it('keeps active selector consistent for hidden manual group in non-admin view', () => {
    const state = resolveClassroomGroupSelectState({
      classroom: {
        activeGroup: null,
        currentGroupId: 'group-hidden',
        currentGroupSource: 'manual',
        defaultGroupId: 'group-default',
      },
      admin: false,
    });

    expect(state.source).toBe('manual');
    expect(state.activeGroupValue).toBe('group-hidden');
    expect(state.defaultGroupValue).toBe('group-default');
  });

  it('keeps default selector consistent for hidden default group in non-admin view', () => {
    const state = resolveClassroomGroupSelectState({
      classroom: {
        activeGroup: null,
        currentGroupId: 'group-hidden-default',
        currentGroupSource: 'default',
        defaultGroupId: null,
      },
      admin: false,
    });

    expect(state.source).toBe('default');
    expect(state.activeGroupValue).toBe('');
    expect(state.defaultGroupValue).toBe('group-hidden-default');
  });

  it('does not backfill hidden values for admins', () => {
    const state = resolveClassroomGroupSelectState({
      classroom: {
        activeGroup: null,
        currentGroupId: 'group-hidden-default',
        currentGroupSource: 'default',
        defaultGroupId: null,
      },
      admin: true,
    });

    expect(state.source).toBe('default');
    expect(state.activeGroupValue).toBe('');
    expect(state.defaultGroupValue).toBe('');
  });
});
