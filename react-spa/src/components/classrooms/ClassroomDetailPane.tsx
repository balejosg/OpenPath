import React from 'react';
import { Clock, Cog, Monitor, Plus } from 'lucide-react';
import type {
  Classroom,
  ClassroomExemption,
  CurrentGroupSource,
  OneOffScheduleWithPermissions,
  ScheduleWithPermissions,
} from '../../types';
import type { GroupLike } from '../groups/GroupLabel';
import ClassroomConfigCard from './ClassroomConfigCard';
import ClassroomMachinesCard from './ClassroomMachinesCard';
import ClassroomScheduleCard from './ClassroomScheduleCard';
import { useT } from '../../i18n/product-i18n';
import Tabs from '../ui/Tabs';

interface CalendarGroupDisplay {
  id: string;
  displayName: string;
}

interface ClassroomDetailPaneProps {
  admin: boolean;
  allowedGroups: readonly GroupLike[];
  calendarGroupsForDisplay: CalendarGroupDisplay[];
  classroomConfigError: string;
  activeGroupSelectValue: string;
  defaultGroupSelectValue: string;
  selectedClassroom: Classroom | null;
  selectedClassroomSource: CurrentGroupSource;
  groupById: ReadonlyMap<string, GroupLike>;
  schedules: ScheduleWithPermissions[];
  sortedOneOffSchedules: OneOffScheduleWithPermissions[];
  loadingSchedules: boolean;
  scheduleError: string;
  activeSchedule: ScheduleWithPermissions | OneOffScheduleWithPermissions | null;
  exemptionByMachineId: ReadonlyMap<string, ClassroomExemption>;
  exemptionMutating: Partial<Record<string, boolean>>;
  exemptionsError: string | null;
  loadingExemptions: boolean;
  enrollModalLoadingToken: boolean;
  onOpenNewModal: () => void;
  onOpenDeleteDialog: () => void;
  onRequestActiveGroupChange: (next: string) => void;
  onDefaultGroupChange: (next: string) => void | Promise<void>;
  onCaptivePortalDomainsChange: (domains: string[]) => void | Promise<void>;
  onOpenEnrollModal: () => void | Promise<void>;
  onCreateExemption: (machineId: string) => void | Promise<void>;
  onCreateOperationalExemption: (
    machineId: string,
    durationHours: number,
    reason: string
  ) => void | Promise<void>;
  onDeleteExemption: (machineId: string) => void | Promise<void>;
  onOpenScheduleCreate: (dayOfWeek?: number, startTime?: string) => void;
  onOpenScheduleEdit: (schedule: ScheduleWithPermissions) => void;
  onRequestScheduleDelete: (schedule: ScheduleWithPermissions) => void;
  onOpenOneOffScheduleCreate: () => void;
  onOpenOneOffScheduleEdit: (schedule: OneOffScheduleWithPermissions) => void;
  onRequestOneOffScheduleDelete: (schedule: OneOffScheduleWithPermissions) => void;
}

type ClassroomDetailTab = 'settings' | 'machines' | 'schedule';

export default function ClassroomDetailPane({
  admin,
  allowedGroups,
  calendarGroupsForDisplay,
  classroomConfigError,
  activeGroupSelectValue,
  defaultGroupSelectValue,
  selectedClassroom,
  selectedClassroomSource,
  groupById,
  schedules,
  sortedOneOffSchedules,
  loadingSchedules,
  scheduleError,
  activeSchedule,
  exemptionByMachineId,
  exemptionMutating,
  exemptionsError,
  loadingExemptions,
  enrollModalLoadingToken,
  onOpenNewModal,
  onOpenDeleteDialog,
  onRequestActiveGroupChange,
  onDefaultGroupChange,
  onCaptivePortalDomainsChange,
  onOpenEnrollModal,
  onCreateExemption,
  onCreateOperationalExemption,
  onDeleteExemption,
  onOpenScheduleCreate,
  onOpenScheduleEdit,
  onRequestScheduleDelete,
  onOpenOneOffScheduleCreate,
  onOpenOneOffScheduleEdit,
  onRequestOneOffScheduleDelete,
}: ClassroomDetailPaneProps) {
  const t = useT();
  const [activeTab, setActiveTab] = React.useState<ClassroomDetailTab>('settings');

  React.useEffect(() => {
    if (!selectedClassroom) {
      setActiveTab('settings');
    }
  }, [selectedClassroom]);

  if (!selectedClassroom) {
    return (
      <div
        data-testid="classrooms-empty-state"
        className="bg-white border border-slate-200 rounded-lg p-6 shadow-sm"
      >
        <h2 className="text-2xl font-bold text-slate-900 mb-1">{t('classrooms.empty.title')}</h2>
        <p className="text-slate-500 text-sm">
          {admin ? t('classrooms.empty.adminBody') : t('classrooms.empty.userBody')}
        </p>
        {admin && (
          <button
            onClick={onOpenNewModal}
            className="mt-6 bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg text-sm inline-flex items-center gap-2 transition-colors shadow-sm font-medium"
          >
            <Plus size={16} /> {t('classrooms.empty.create')}
          </button>
        )}
      </div>
    );
  }

  const tabs = [
    { id: 'settings', label: t('classrooms.tabs.settings'), icon: <Cog size={16} /> },
    {
      id: 'machines',
      label: t('classrooms.tabs.machines'),
      count: selectedClassroom.computerCount,
      icon: <Monitor size={16} />,
    },
    {
      id: 'schedule',
      label: t('classrooms.tabs.schedule'),
      count: schedules.length + sortedOneOffSchedules.length,
      icon: <Clock size={16} />,
    },
  ];

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <Tabs
        tabs={tabs}
        activeTab={activeTab}
        onChange={(next) => setActiveTab(next as ClassroomDetailTab)}
        ariaLabel={t('classrooms.tabs.ariaLabel')}
        getTabId={(id) => `classroom-detail-tab-${id}`}
        getPanelId={(id) => `classroom-detail-panel-${id}`}
      />
      <div className="min-h-0 flex-1">
        <section
          id="classroom-detail-panel-settings"
          role="tabpanel"
          aria-labelledby="classroom-detail-tab-settings"
          hidden={activeTab !== 'settings'}
          className="h-full min-h-0 lg:overflow-y-auto custom-scrollbar"
        >
          <ClassroomConfigCard
            admin={admin}
            allowedGroups={allowedGroups}
            classroomConfigError={classroomConfigError}
            activeGroupSelectValue={activeGroupSelectValue}
            defaultGroupSelectValue={defaultGroupSelectValue}
            classroom={selectedClassroom}
            classroomSource={selectedClassroomSource}
            groupById={groupById}
            onOpenDeleteDialog={onOpenDeleteDialog}
            onRequestActiveGroupChange={onRequestActiveGroupChange}
            onDefaultGroupChange={onDefaultGroupChange}
            onCaptivePortalDomainsChange={onCaptivePortalDomainsChange}
          />
        </section>

        <section
          id="classroom-detail-panel-machines"
          role="tabpanel"
          aria-labelledby="classroom-detail-tab-machines"
          hidden={activeTab !== 'machines'}
          className="h-full min-h-0 lg:overflow-y-auto custom-scrollbar"
        >
          <ClassroomMachinesCard
            admin={admin}
            classroom={selectedClassroom}
            hasActiveSchedule={activeSchedule !== null}
            exemptionByMachineId={exemptionByMachineId}
            exemptionMutating={exemptionMutating}
            exemptionsError={exemptionsError}
            loadingExemptions={loadingExemptions}
            enrollModalLoadingToken={enrollModalLoadingToken}
            onOpenEnrollModal={onOpenEnrollModal}
            onCreateExemption={onCreateExemption}
            onCreateOperationalExemption={onCreateOperationalExemption}
            onDeleteExemption={onDeleteExemption}
          />
        </section>

        <section
          id="classroom-detail-panel-schedule"
          role="tabpanel"
          aria-labelledby="classroom-detail-tab-schedule"
          hidden={activeTab !== 'schedule'}
          className="h-full min-h-0 lg:overflow-hidden"
        >
          <ClassroomScheduleCard
            admin={admin}
            calendarGroupsForDisplay={calendarGroupsForDisplay}
            groupById={groupById}
            schedules={schedules}
            sortedOneOffSchedules={sortedOneOffSchedules}
            loadingSchedules={loadingSchedules}
            scheduleError={scheduleError}
            onOpenScheduleCreate={onOpenScheduleCreate}
            onOpenScheduleEdit={onOpenScheduleEdit}
            onRequestScheduleDelete={onRequestScheduleDelete}
            onOpenOneOffScheduleCreate={onOpenOneOffScheduleCreate}
            onOpenOneOffScheduleEdit={onOpenOneOffScheduleEdit}
            onRequestOneOffScheduleDelete={onRequestOneOffScheduleDelete}
            fillAvailable={activeTab === 'schedule'}
          />
        </section>
      </div>
    </div>
  );
}
