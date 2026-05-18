import { BookOpen, Folder } from 'lucide-react';
import type { GroupsActiveView } from '../../hooks/useGroupsViewModel';

interface GroupsHeaderProps {
  activeView: GroupsActiveView;
  admin: boolean;
  canCreateGroups: boolean;
  onActiveViewChange: (view: GroupsActiveView) => void;
  onOpenNewModal: () => void;
}

export function GroupsHeader({
  activeView,
  admin,
  canCreateGroups,
  onActiveViewChange,
  onOpenNewModal,
}: GroupsHeaderProps) {
  return (
    <div className="flex flex-col sm:flex-row sm:justify-between sm:items-center gap-3">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="text-xl font-bold text-slate-900">
            {activeView === 'library'
              ? 'Policy Library'
              : admin
                ? 'Security Groups'
                : 'My Policies'}
          </h2>
          <p className="text-slate-500 text-sm">
            {activeView === 'library'
              ? 'Explore public policies to clone.'
              : 'Manage access and restriction policies.'}
          </p>
        </div>

        <div className="flex items-center gap-1 bg-slate-100 rounded-lg p-1">
          <button
            onClick={() => onActiveViewChange('my')}
            className={`flex items-center gap-2 px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${activeView === 'my' ? 'bg-white text-slate-900 shadow-sm' : 'text-slate-600 hover:text-slate-900'}`}
          >
            <Folder size={16} />
            <span className="hidden sm:inline">My groups</span>
          </button>
          <button
            onClick={() => onActiveViewChange('library')}
            className={`flex items-center gap-2 px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${activeView === 'library' ? 'bg-white text-slate-900 shadow-sm' : 'text-slate-600 hover:text-slate-900'}`}
          >
            <BookOpen size={16} />
            <span className="hidden sm:inline">Biblioteca</span>
          </button>
        </div>
      </div>

      {canCreateGroups && activeView === 'my' && (
        <button
          onClick={onOpenNewModal}
          className="bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg text-sm font-medium transition-colors shadow-sm"
        >
          + New Group
        </button>
      )}
    </div>
  );
}
