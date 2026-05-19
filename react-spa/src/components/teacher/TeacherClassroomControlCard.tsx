import React from 'react';
import { Loader2, MonitorPlay } from 'lucide-react';
import type { useTeacherDashboardViewModel } from '../../hooks/useTeacherDashboardViewModel';
import { useT } from '../../i18n/product-i18n';
import { GroupSelect } from '../groups/GroupSelect';

type TeacherDashboardViewModel = ReturnType<typeof useTeacherDashboardViewModel>;

interface TeacherClassroomControlCardProps {
  viewModel: TeacherDashboardViewModel;
  onNavigateToRules?: (group: { id: string; name: string }) => void;
}

export const TeacherClassroomControlCard: React.FC<TeacherClassroomControlCardProps> = ({
  viewModel,
  onNavigateToRules,
}) => {
  const t = useT();
  const {
    classrooms,
    groups,
    groupById,
    groupsLoading,
    groupsError,
    selectedClassroomForControl,
    setSelectedClassroomForControl,
    selectedGroupForControl,
    setSelectedGroupForControl,
    controlLoading,
    controlError,
    handleTakeControl,
    teacherGroupsEnabled,
  } = viewModel;

  return (
    <div className="bg-white border border-slate-200 rounded-lg p-6 shadow-sm">
      <h3 className="text-lg font-semibold text-slate-800 mb-4 flex items-center gap-2">
        <MonitorPlay className="text-blue-500" size={20} />
        {t('teacher.control.title')}
      </h3>
      <p className="text-sm text-slate-500 mb-4">{t('teacher.control.body')}</p>

      <div className="space-y-4">
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">
            {t('teacher.control.classroom')}
          </label>
          <select
            className="w-full bg-slate-50 border border-slate-300 rounded-lg px-3 py-2 text-sm focus:border-blue-500 outline-none"
            value={selectedClassroomForControl}
            onChange={(e) => setSelectedClassroomForControl(e.target.value)}
          >
            <option value="">{t('teacher.control.selectClassroom')}</option>
            {classrooms.map((c) => (
              <option key={c.id} value={c.id}>
                {c.displayName || c.name}
              </option>
            ))}
          </select>
        </div>

        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">
            {t('teacher.control.policyToApply')}
          </label>
          <GroupSelect
            id="teacher-control-group"
            className="w-full bg-slate-50 border border-slate-300 rounded-lg px-3 py-2 text-sm focus:border-blue-500 outline-none"
            value={selectedGroupForControl}
            onChange={setSelectedGroupForControl}
            disabled={groupsLoading || !!groupsError || groups.length === 0}
            groups={groups}
            includeNoneOption
            noneLabel={t('teacher.control.restoreDefault')}
            inactiveBehavior="hide"
          />

          {groupsError && <p className="mt-2 text-xs text-red-600">{groupsError}</p>}

          {!groupsLoading && !groupsError && groups.length === 0 && (
            <p className="mt-2 text-xs text-slate-500 italic">
              {teacherGroupsEnabled
                ? t('teacher.control.noPolicies')
                : t('teacher.control.noAssignedPolicies')}
            </p>
          )}

          {(() => {
            if (!onNavigateToRules) return null;
            if (!selectedGroupForControl) return null;
            const selected = groupById.get(selectedGroupForControl);
            if (!selected) return null;

            return (
              <button
                type="button"
                onClick={() => onNavigateToRules({ id: selected.id, name: selected.name })}
                className="mt-2 text-xs text-blue-600 hover:text-blue-800 font-medium underline"
              >
                {t('teacher.control.manageRules')}
              </button>
            );
          })()}
        </div>

        <button
          onClick={handleTakeControl}
          disabled={!selectedClassroomForControl || controlLoading}
          className="w-full mt-2 bg-blue-600 hover:bg-blue-700 disabled:opacity-50 text-white font-medium py-2 px-4 rounded-lg flex items-center justify-center gap-2 transition-colors"
        >
          {controlLoading && <Loader2 size={16} className="animate-spin" />}
          {selectedGroupForControl
            ? t('teacher.control.applyPolicy')
            : t('teacher.control.releaseClassroom')}
        </button>

        {controlError && <p className="text-xs text-red-600">{controlError}</p>}
      </div>
    </div>
  );
};
