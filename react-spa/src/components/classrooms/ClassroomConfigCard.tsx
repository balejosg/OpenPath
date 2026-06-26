import React, { useEffect, useState } from 'react';
import { AlertCircle, Trash2 } from 'lucide-react';
import type { Classroom, CurrentGroupSource } from '../../types';
import {
  GroupLabel,
  resolveGroupDisplayNameFromLookup,
  resolveGroupLike,
  type GroupLike,
} from '../groups/GroupLabel';
import { GroupSelect } from '../groups/GroupSelect';
import { useT, type ProductT } from '../../i18n/product-i18n';

interface ClassroomConfigCardProps {
  admin: boolean;
  allowedGroups: readonly GroupLike[];
  classroomConfigError: string;
  activeGroupSelectValue: string;
  defaultGroupSelectValue: string;
  classroom: Classroom;
  classroomSource: CurrentGroupSource;
  groupById: ReadonlyMap<string, GroupLike>;
  onOpenDeleteDialog: () => void;
  onRequestActiveGroupChange: (next: string) => void;
  onDefaultGroupChange: (next: string) => void | Promise<void>;
  onCaptivePortalDomainsChange: (domains: string[]) => void | Promise<void>;
}

function getSourcePhrase(source: CurrentGroupSource, t: ProductT): string {
  if (source === 'default') return t('classrooms.detail.source.default');
  if (source === 'schedule') return t('classrooms.detail.source.schedule');
  if (source === 'manual') return t('classrooms.detail.source.manual');
  return '';
}

function renderClassroomStatus(classroom: Classroom, t: ProductT) {
  if (classroom.status === 'operational') {
    return (
      <span className="text-green-700 font-medium flex items-center gap-2 text-sm">
        <div className="w-2 h-2 bg-green-500 rounded-full"></div>{' '}
        {t('classrooms.detail.status.operational')}
      </span>
    );
  }

  if (classroom.status === 'degraded') {
    return (
      <span className="text-yellow-700 font-medium flex items-center gap-2 text-sm">
        <div className="w-2 h-2 bg-yellow-500 rounded-full"></div>{' '}
        {t('classrooms.detail.status.degraded')}
      </span>
    );
  }

  return (
    <span className="text-red-700 font-medium flex items-center gap-2 text-sm">
      <div className="w-2 h-2 bg-red-500 rounded-full"></div>{' '}
      {t('classrooms.detail.status.offline')}
    </span>
  );
}

export default function ClassroomConfigCard({
  admin,
  allowedGroups,
  classroomConfigError,
  activeGroupSelectValue,
  defaultGroupSelectValue,
  classroom,
  classroomSource,
  groupById,
  onOpenDeleteDialog,
  onRequestActiveGroupChange,
  onDefaultGroupChange,
  onCaptivePortalDomainsChange,
}: ClassroomConfigCardProps) {
  const t = useT();
  const captivePortalDomains = classroom.captivePortalDomains ?? [];
  const [captivePortalEnabled, setCaptivePortalEnabled] = useState(captivePortalDomains.length > 0);

  useEffect(() => {
    setCaptivePortalEnabled(captivePortalDomains.length > 0);
  }, [captivePortalDomains.length]);

  return (
    <div className="bg-white border border-slate-200 rounded-lg p-6 shadow-sm">
      <div className="flex justify-between items-start">
        <div>
          <h2 className="text-2xl font-bold text-slate-900 mb-1">{classroom.name}</h2>
          <p className="text-slate-500 text-sm">{t('classrooms.detail.settingsStatus')}</p>
        </div>
        <div className="flex gap-2">
          {admin && (
            <button
              onClick={onOpenDeleteDialog}
              className="p-2 text-slate-400 hover:text-red-600 hover:bg-red-50 rounded-lg transition-colors border border-transparent hover:border-red-100"
              title={t('classrooms.dialog.deleteClassroom.title')}
              aria-label={t('classrooms.dialog.deleteClassroom.title')}
            >
              <Trash2 size={18} />
            </button>
          )}
        </div>
      </div>

      <div className="mt-6 grid grid-cols-1 md:grid-cols-3 gap-4">
        <div className="bg-slate-50 rounded-lg p-4 border border-slate-200">
          <label
            htmlFor="classroom-active-group"
            className="text-xs font-semibold text-slate-500 uppercase tracking-wider mb-2 block"
          >
            {t('classrooms.detail.activeGroup')}
          </label>
          <GroupSelect
            id="classroom-active-group"
            value={activeGroupSelectValue}
            onChange={onRequestActiveGroupChange}
            groups={allowedGroups}
            includeNoneOption
            noneLabel={t('classrooms.detail.noActiveGroup')}
            inactiveBehavior="hide"
            unknownValueLabel={
              !admin && activeGroupSelectValue && !groupById.get(activeGroupSelectValue)
                ? resolveGroupDisplayNameFromLookup({
                    groupId: activeGroupSelectValue,
                    groupById,
                    displayName: classroom.currentGroupDisplayName,
                    source: 'manual',
                    t,
                  })
                : undefined
            }
            className="w-full bg-white border border-slate-300 rounded-lg px-3 py-2 text-slate-900 focus:border-blue-500 outline-none shadow-sm"
          />
          {!activeGroupSelectValue && classroom.currentGroupId && (
            <p className="mt-2 text-xs text-slate-500 italic">
              {t('classrooms.detail.currentlyUsing')}{' '}
              <GroupLabel
                variant="text"
                className="font-semibold text-slate-700"
                groupId={classroom.currentGroupId}
                group={resolveGroupLike({
                  groupId: classroom.currentGroupId,
                  groupById,
                  displayName: classroom.currentGroupDisplayName,
                })}
                source={classroomSource}
                revealUnknownId={admin}
                showSourceTag={false}
              />
              {(() => {
                const phrase = getSourcePhrase(classroomSource, t);
                return phrase ? ` ${phrase}` : '';
              })()}
            </p>
          )}
        </div>

        <div className="bg-slate-50 rounded-lg p-4 border border-slate-200">
          <label
            htmlFor="classroom-default-group"
            className="text-xs font-semibold text-slate-500 uppercase tracking-wider mb-2 block"
          >
            {t('classrooms.detail.defaultGroup')}
          </label>
          <GroupSelect
            id="classroom-default-group"
            value={defaultGroupSelectValue}
            onChange={(next) => void onDefaultGroupChange(next)}
            disabled={!admin}
            groups={allowedGroups}
            includeNoneOption
            noneLabel={t('classrooms.detail.noDefaultGroup')}
            inactiveBehavior="disable"
            unknownValueLabel={
              !admin && defaultGroupSelectValue && !groupById.get(defaultGroupSelectValue)
                ? resolveGroupDisplayNameFromLookup({
                    groupId: defaultGroupSelectValue,
                    groupById,
                    displayName: classroom.defaultGroupDisplayName,
                    source: 'default',
                    t,
                  })
                : undefined
            }
            className="w-full bg-white border border-slate-300 rounded-lg px-3 py-2 text-slate-900 focus:border-blue-500 outline-none shadow-sm disabled:bg-slate-50 disabled:text-slate-500"
          />
          <p className="mt-2 text-xs text-slate-500 italic">
            {t('classrooms.detail.defaultGroupHelp')}
          </p>
          {classroomConfigError && (
            <p className="mt-2 text-xs text-red-600 flex items-start gap-1">
              <AlertCircle size={12} className="mt-0.5 flex-shrink-0" />
              <span>{classroomConfigError}</span>
            </p>
          )}
        </div>

        <div className="bg-slate-50 rounded-lg p-4 border border-slate-200 flex items-center justify-between">
          <div>
            <label className="text-xs font-semibold text-slate-500 uppercase tracking-wider mb-1 block">
              {t('classrooms.detail.status')}
            </label>
            {renderClassroomStatus(classroom, t)}
          </div>
          {classroom.computerCount > 0 && (
            <span className="text-xs text-slate-500">
              {t('classrooms.detail.onlineMachines', {
                onlineCount: classroom.onlineMachineCount,
                totalCount: classroom.computerCount,
              })}
            </span>
          )}
        </div>
      </div>

      <div className="mt-4 bg-slate-50 rounded-lg p-4 border border-slate-200">
        <label className="flex items-center gap-3 text-sm font-medium text-slate-700">
          <input
            type="checkbox"
            checked={captivePortalEnabled}
            disabled={!admin}
            onChange={(event) => {
              const enabled = event.currentTarget.checked;
              setCaptivePortalEnabled(enabled);
              if (!enabled) {
                void onCaptivePortalDomainsChange([]);
              }
            }}
            className="h-4 w-4 rounded border-slate-300 text-blue-600 focus:ring-blue-500"
          />
          {t('classrooms.detail.captivePortal.enabled')}
        </label>
        <input
          aria-label={t('classrooms.detail.captivePortal.domains')}
          disabled={!admin || !captivePortalEnabled}
          value={captivePortalDomains.join(', ')}
          onChange={(event) => {
            void onCaptivePortalDomainsChange(
              event.currentTarget.value
                .split(',')
                .map((domain) => domain.trim())
                .filter(Boolean)
            );
          }}
          className="mt-3 w-full bg-white border border-slate-300 rounded-lg px-3 py-2 text-slate-900 focus:border-blue-500 outline-none shadow-sm disabled:bg-slate-50 disabled:text-slate-500"
        />
      </div>
    </div>
  );
}
