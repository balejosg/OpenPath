import {
  AlertCircle,
  ArrowRight,
  Copy,
  Folder,
  Loader2,
  MoreHorizontal,
  ShieldCheck,
} from 'lucide-react';
import { getEsActiveInactiveLabel } from '../../lib/status';
import type { GroupCardViewModel, GroupsActiveView } from '../../hooks/useGroupsViewModel';
import { useT } from '../../i18n/product-i18n';

interface GroupsGridProps {
  activeView: GroupsActiveView;
  groups: GroupCardViewModel[];
  loading: boolean;
  error: string | null;
  admin: boolean;
  teacherCanCreateGroups: boolean;
  onRetry: () => void;
  onOpenNewModal: () => void;
  onNavigateToRules: (group: { id: string; name: string; readOnly?: boolean }) => void;
  onOpenConfigModal: (groupId: string) => void;
  onOpenCloneModal: (groupId: string) => void;
}

export function GroupsGrid({
  activeView,
  groups,
  loading,
  error,
  admin,
  teacherCanCreateGroups,
  onRetry,
  onOpenNewModal,
  onNavigateToRules,
  onOpenConfigModal,
  onOpenCloneModal,
}: GroupsGridProps) {
  const t = useT();
  return (
    <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
      {loading ? (
        <div className="col-span-full flex items-center justify-center py-12">
          <Loader2 className="w-6 h-6 animate-spin text-slate-400" />
          <span className="ml-2 text-slate-500">
            {activeView === 'library'
              ? t('groups.grid.loadingLibrary')
              : t('groups.grid.loadingGroups')}
          </span>
        </div>
      ) : error ? (
        <div className="col-span-full text-center py-12">
          <AlertCircle className="w-6 h-6 text-red-400 mx-auto" />
          <span className="text-red-500 text-sm mt-2 block">{error}</span>
          <button onClick={onRetry} className="text-blue-600 hover:text-blue-800 text-sm mt-2">
            {t('common.retry')}
          </button>
        </div>
      ) : groups.length === 0 ? (
        <div className="col-span-full text-center py-12 text-slate-500">
          {activeView === 'library'
            ? t('groups.grid.emptyLibrary')
            : admin
              ? t('groups.grid.emptyAdmin')
              : teacherCanCreateGroups
                ? t('groups.grid.emptyTeacherCanCreate')
                : t('groups.grid.emptyTeacherNoCreate')}

          {activeView === 'my' && !admin && teacherCanCreateGroups && (
            <div className="mt-4">
              <button
                onClick={onOpenNewModal}
                className="bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg text-sm font-medium transition-colors shadow-sm"
              >
                {t('groups.grid.createFirstPolicy')}
              </button>
            </div>
          )}
        </div>
      ) : (
        groups.map((group) => (
          <div
            key={group.id}
            className="bg-white border border-slate-200 rounded-lg p-5 hover:border-blue-300 transition-all group relative shadow-sm hover:shadow-md"
          >
            <div className="absolute top-4 right-4 opacity-100">
              <button className="text-slate-400 hover:text-slate-600 p-1 hover:bg-slate-100 rounded">
                <MoreHorizontal size={18} />
              </button>
            </div>

            <div className="flex items-start gap-4 mb-4">
              <div
                className={`p-3 rounded-lg ${group.status === 'Active' ? 'bg-blue-50 text-blue-600' : 'bg-slate-100 text-slate-500'}`}
              >
                <Folder size={20} />
              </div>
              <div>
                <h3 className="font-semibold text-slate-900 text-sm">
                  {activeView === 'library' ? group.displayName : group.name}
                </h3>
                <p className="text-xs text-slate-500 mt-1 line-clamp-1">
                  {activeView === 'library' ? group.name : group.description}
                </p>
              </div>
            </div>

            <div className="space-y-3">
              <div className="flex justify-between items-center text-sm py-2 border-t border-slate-100 border-b">
                <span className="text-slate-500 flex items-center gap-2 text-xs">
                  <ShieldCheck size={14} /> {t('groups.grid.allowedDomains')}
                </span>
                <span className="font-medium text-slate-900">{group.domainCount}</span>
              </div>

              <div className="flex justify-between items-center pt-1">
                <div className="flex items-center gap-2">
                  <span
                    className={`text-xs px-2 py-0.5 rounded-full border font-medium ${group.status === 'Active' ? 'border-green-200 bg-green-50 text-green-700' : 'border-slate-200 bg-slate-100 text-slate-500'}`}
                  >
                    {getEsActiveInactiveLabel(group.status)}
                  </span>
                  <span
                    className={`text-xs px-2 py-0.5 rounded-full border font-medium ${group.visibility === 'instance_public' ? 'border-blue-200 bg-blue-50 text-blue-700' : 'border-slate-200 bg-slate-100 text-slate-600'}`}
                    title={
                      group.visibility === 'instance_public'
                        ? t('groups.grid.visibilityPublicTitle')
                        : t('groups.grid.visibilityPrivateTitle')
                    }
                  >
                    {group.visibility === 'instance_public'
                      ? t('groups.grid.visibilityPublic')
                      : t('groups.grid.visibilityPrivate')}
                  </span>
                </div>

                {activeView === 'library' ? (
                  <div className="flex items-center gap-2">
                    <button
                      onClick={() =>
                        onNavigateToRules({
                          id: group.id,
                          name: group.displayName,
                          readOnly: true,
                        })
                      }
                      className="text-xs text-slate-700 hover:text-slate-900 flex items-center gap-1 font-medium"
                      title={t('groups.grid.viewRulesTitle')}
                    >
                      <ArrowRight size={12} /> {t('common.view')}
                    </button>
                    <button
                      onClick={() => onOpenCloneModal(group.id)}
                      disabled={group.status !== 'Active'}
                      className={`text-xs flex items-center gap-1 font-medium ${
                        group.status === 'Active'
                          ? 'text-blue-600 hover:text-blue-800'
                          : 'text-slate-400 cursor-not-allowed'
                      }`}
                      title={
                        group.status === 'Active'
                          ? t('groups.grid.cloneTitle')
                          : t('groups.grid.cloneInactiveTitle')
                      }
                    >
                      <Copy size={12} /> {t('common.clone')}
                    </button>
                  </div>
                ) : (
                  <button
                    onClick={() => onOpenConfigModal(group.id)}
                    className="text-xs text-blue-600 hover:text-blue-800 flex items-center gap-1 font-medium transition-opacity"
                  >
                    {t('common.configure')} <ArrowRight size={12} />
                  </button>
                )}
              </div>
            </div>
          </div>
        ))
      )}
    </div>
  );
}
