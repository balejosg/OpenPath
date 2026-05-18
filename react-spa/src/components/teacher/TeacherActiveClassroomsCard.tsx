import React from 'react';
import { Calendar, Folder, Loader2 } from 'lucide-react';
import type { useTeacherDashboardViewModel } from '../../hooks/useTeacherDashboardViewModel';
import { GroupLabel } from '../groups/GroupLabel';

type TeacherDashboardViewModel = ReturnType<typeof useTeacherDashboardViewModel>;

interface TeacherActiveClassroomsCardProps {
  viewModel: TeacherDashboardViewModel;
}

export const TeacherActiveClassroomsCard: React.FC<TeacherActiveClassroomsCardProps> = ({
  viewModel,
}) => {
  const { classroomsLoading, activeClassrooms, groupById, handleReleaseClass } = viewModel;

  return (
    <div className="bg-white border border-slate-200 rounded-lg p-6 shadow-sm flex flex-col">
      <h3 className="text-lg font-semibold text-slate-800 mb-4 flex items-center gap-2">
        <Calendar className="text-indigo-500" size={20} />
        Classrooms With Active Group
      </h3>

      <div className="flex-1 overflow-y-auto pr-2 custom-scrollbar space-y-3">
        {classroomsLoading ? (
          <div className="flex items-center justify-center py-8">
            <Loader2 className="w-6 h-6 animate-spin text-slate-400" />
          </div>
        ) : activeClassrooms.length === 0 ? (
          <div className="text-center py-8">
            <Folder className="w-10 h-10 text-slate-300 mx-auto mb-3" />
            <p className="text-slate-500 text-sm">No active classrooms right now.</p>
          </div>
        ) : (
          activeClassrooms.map((c) => (
            <div
              key={c.classroomId}
              className="border border-slate-200 rounded-lg p-4 bg-slate-50 flex items-center justify-between"
            >
              <div>
                <h4 className="font-semibold text-slate-800 text-sm">{c.classroomName}</h4>
                <p className="text-xs text-slate-500 mt-1">
                  Usando:{' '}
                  <GroupLabel
                    variant="text"
                    className="font-medium text-slate-700"
                    groupId={c.groupId}
                    group={c.group}
                    source={c.source}
                  />
                </p>
              </div>
              {c.hasManualOverride && c.source === 'manual' && groupById.has(c.groupId) && (
                <button
                  onClick={() => void handleReleaseClass(c.classroomId)}
                  className="text-xs bg-white border border-slate-300 hover:bg-slate-100 text-slate-700 px-3 py-1.5 rounded-lg transition-colors font-medium shadow-sm"
                >
                  End Class
                </button>
              )}
            </div>
          ))
        )}
      </div>
    </div>
  );
};
