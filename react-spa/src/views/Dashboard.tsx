import React from 'react';
import {
  Folder,
  CheckCircle,
  Ban,
  Shield,
  AlertCircle,
  Loader2,
  ShieldCheck,
  ShieldOff,
  Server,
} from 'lucide-react';
import { GroupLabel } from '../components/groups/GroupLabel';
import { DashboardQuickAccessSection } from '../components/dashboard/DashboardQuickAccessSection';
import { useDashboardViewModel } from '../hooks/useDashboardViewModel';

interface StatCardColor {
  bg: string;
  text: string;
  badgeBg: string;
  badgeText: string;
}

interface StatCardProps {
  title: string;
  value: string;
  icon: React.ReactNode;
  color: StatCardColor;
  subtext: string;
}

interface DashboardProps {
  onNavigateToRules?: (group: { id: string; name: string }) => void;
  onNavigateToClassroom?: (classroom: { id: string; name: string }) => void;
}

const StatCard = ({ title, value, icon, color, subtext }: StatCardProps) => (
  <div className="bg-white border border-slate-200 rounded-lg p-5 shadow-sm hover:shadow-md transition-shadow">
    <div className="flex justify-between items-start mb-4">
      <div className={`p-2 rounded-lg ${color.bg} ${color.text}`}>{icon}</div>
      <span
        className={`text-xs font-medium px-2 py-1 rounded-full ${color.badgeBg} ${color.badgeText}`}
      >
        {subtext}
      </span>
    </div>
    <div>
      <h3 className="text-2xl font-bold text-slate-800">{value}</h3>
      <p className="text-slate-500 text-sm font-medium">{title}</p>
    </div>
  </div>
);

const Dashboard: React.FC<DashboardProps> = ({ onNavigateToRules, onNavigateToClassroom }) => {
  const {
    loading,
    error,
    stats,
    systemStatus,
    classrooms,
    classroomsLoading,
    classroomsError,
    groups,
    groupsLoading,
    groupsError,
    sortBy,
    setSortBy,
    showSortDropdown,
    setShowSortDropdown,
    sortedGroups,
    hasMoreGroups,
    activeGroupsByClassroom,
  } = useDashboardViewModel();

  return (
    <div className="space-y-6">
      {/* Welcome Banner */}
      <div className="bg-white border border-slate-200 rounded-lg p-6 shadow-sm flex flex-col sm:flex-row sm:items-start sm:justify-between gap-4">
        <div className="min-w-0">
          <h2
            className="text-xl font-semibold text-slate-800 flex items-center gap-2"
            data-testid="dashboard-system-status"
          >
            {loading ? (
              <>
                <Loader2 size={20} className="animate-spin text-slate-400" />
                Verificando estado...
              </>
            ) : !systemStatus ? (
              <>
                <AlertCircle size={20} className="text-slate-500" />
                System Status: Unavailable
              </>
            ) : systemStatus.activeGroups > 0 ? (
              <>
                <ShieldCheck size={20} className="text-green-600" />
                System Status: Secure
              </>
            ) : (
              <>
                <ShieldOff size={20} className="text-amber-600" />
                System Status: No groups enabled
              </>
            )}
          </h2>
          <p className="text-slate-500 text-sm mt-1">
            {loading
              ? 'Loading system information...'
              : !systemStatus
                ? 'Unable to get system status.'
                : systemStatus.activeGroups > 0
                  ? `${String(systemStatus.activeGroups)} enabled group(s) are applying rules.`
                  : 'No groups enabled; enable one to apply rules.'}
            {systemStatus?.lastChecked && !loading && (
              <span className="ml-1">
                Last check: {systemStatus.lastChecked.toLocaleTimeString()}
              </span>
            )}
          </p>
        </div>

        <div className="w-full sm:w-[340px] bg-slate-50 border border-slate-200 rounded-lg p-4">
          <div className="flex items-center justify-between">
            <p className="text-xs font-semibold text-slate-600 uppercase tracking-wider">
              Active group by classroom
            </p>
            <Shield className="text-slate-400 w-4 h-4" />
          </div>

          {classroomsLoading ? (
            <div className="flex items-center gap-2 mt-3 text-sm text-slate-500">
              <Loader2 size={14} className="animate-spin text-slate-400" />
              Loading classrooms...
            </div>
          ) : classroomsError ? (
            <p className="mt-3 text-sm text-red-600">{classroomsError}</p>
          ) : activeGroupsByClassroom.length === 0 ? (
            <p className="mt-3 text-sm text-slate-500">
              {classrooms.length === 0
                ? 'No classrooms configured.'
                : 'No classrooms have an assigned group.'}
            </p>
          ) : (
            <ul className="mt-3 space-y-2 max-h-36 overflow-y-auto pr-1 custom-scrollbar">
              {activeGroupsByClassroom.map((row) => {
                const rowContent = (
                  <>
                    <span className="text-sm text-slate-700 truncate">{row.classroomName}</span>
                    <GroupLabel
                      className="text-xs whitespace-nowrap"
                      groupId={row.groupId}
                      group={row.group}
                      source={row.source}
                      revealUnknownId
                      showSourceTag={row.source !== 'none'}
                      showInactiveTag
                    />
                  </>
                );

                return (
                  <li key={row.classroomId}>
                    {onNavigateToClassroom ? (
                      <button
                        type="button"
                        className="flex w-full items-center justify-between gap-3 rounded-md px-2 py-1.5 text-left transition-colors hover:bg-white"
                        data-testid={`dashboard-classroom-${row.classroomId}`}
                        onClick={() =>
                          onNavigateToClassroom({
                            id: row.classroomId,
                            name: row.classroomName,
                          })
                        }
                      >
                        {rowContent}
                      </button>
                    ) : (
                      <div className="flex items-center justify-between gap-3 px-2 py-1.5">
                        {rowContent}
                      </div>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      </div>

      {/* Stats Grid */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
        <StatCard
          title="Active Groups"
          value={loading ? '...' : String(stats?.groupCount ?? 0)}
          icon={<Folder size={20} />}
          color={{
            bg: 'bg-blue-50',
            text: 'text-blue-600',
            badgeBg: 'bg-blue-50',
            badgeText: 'text-blue-700',
          }}
          subtext="Total"
        />
        <StatCard
          title="Allowed Domains"
          value={loading ? '...' : String(stats?.whitelistCount ?? 0)}
          icon={<CheckCircle size={20} />}
          color={{
            bg: 'bg-emerald-50',
            text: 'text-emerald-600',
            badgeBg: 'bg-emerald-50',
            badgeText: 'text-emerald-700',
          }}
          subtext="Whitelist"
        />
        <StatCard
          title="Sitios Bloqueados"
          value={loading ? '...' : String(stats?.blockedCount ?? 0)}
          icon={<Ban size={20} />}
          color={{
            bg: 'bg-slate-100',
            text: 'text-slate-600',
            badgeBg: 'bg-slate-100',
            badgeText: 'text-slate-600',
          }}
          subtext="Seguridad"
        />
        <StatCard
          title="Pending Requests"
          value={loading ? '...' : String(stats?.pendingRequests ?? 0)}
          icon={<Server size={20} />}
          color={{
            bg: 'bg-amber-50',
            text: 'text-amber-600',
            badgeBg: 'bg-amber-50',
            badgeText: 'text-amber-700',
          }}
          subtext={stats?.pendingRequests ? 'Needs attention' : 'None pending'}
        />
      </div>

      {/* Error message if stats failed to load */}
      {error && (
        <div className="bg-red-50 border border-red-200 rounded-lg p-4 text-red-700 text-sm">
          {error}
        </div>
      )}

      {/* Loading indicator */}
      {loading && (
        <div className="flex items-center justify-center py-8">
          <Loader2 className="w-6 h-6 animate-spin text-slate-400" />
          <span className="ml-2 text-slate-500">Loading statistics...</span>
        </div>
      )}

      {/* Quick Access Section */}
      {onNavigateToRules && (
        <DashboardQuickAccessSection
          groups={groups}
          groupsLoading={groupsLoading}
          groupsError={groupsError}
          sortedGroups={sortedGroups}
          sortBy={sortBy}
          showSortDropdown={showSortDropdown}
          setSortBy={setSortBy}
          setShowSortDropdown={setShowSortDropdown}
          hasMoreGroups={hasMoreGroups}
          onNavigateToRules={onNavigateToRules}
        />
      )}
    </div>
  );
};

export default Dashboard;
