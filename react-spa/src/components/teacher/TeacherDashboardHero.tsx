import React from 'react';
import { Loader2, ShieldCheck, ShieldOff } from 'lucide-react';

interface TeacherDashboardHeroProps {
  classroomsLoading: boolean;
  activeCount: number;
  classroomsError: string | null;
  onRetry: () => void;
}

export const TeacherDashboardHero: React.FC<TeacherDashboardHeroProps> = ({
  classroomsLoading,
  activeCount,
  classroomsError,
  onRetry,
}) => (
  <div className="bg-white border border-slate-200 rounded-lg p-6 shadow-sm flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
    <div className="min-w-0">
      <h2 className="text-2xl font-bold text-slate-800 flex items-center gap-2">Hello, Teacher!</h2>
      <p className="text-slate-500 text-sm mt-1 mb-4">
        Manage classroom internet access quickly from here.
      </p>

      {classroomsLoading ? (
        <div className="flex items-center gap-2 mt-3 text-sm text-slate-500">
          <Loader2 size={14} className="animate-spin text-slate-400" />
          Verificando estado...
        </div>
      ) : activeCount > 0 ? (
        <div className="flex items-center gap-2 text-green-700 bg-green-50 px-3 py-2 rounded-lg border border-green-200 w-fit">
          <ShieldCheck size={20} />
          <span className="font-medium text-sm">
            There are {activeCount} classroom(s) with an active group right now.
          </span>
        </div>
      ) : (
        <div className="flex items-center gap-2 text-slate-600 bg-slate-50 px-3 py-2 rounded-lg border border-slate-200 w-fit">
          <ShieldOff size={20} />
          <span className="font-medium text-sm">No classrooms have an active group right now.</span>
        </div>
      )}

      {classroomsError && !classroomsLoading && (
        <div className="mt-3 text-sm text-red-600">
          {classroomsError}{' '}
          <button type="button" onClick={onRetry} className="underline hover:text-red-800">
            Retry
          </button>
        </div>
      )}
    </div>
  </div>
);
