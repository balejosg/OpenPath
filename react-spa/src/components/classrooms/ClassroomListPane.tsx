import React from 'react';
import { Plus, Search, Laptop, AlertCircle, Loader2 } from 'lucide-react';

import type { Classroom } from '../../types';
import {
  GroupLabel,
  inferGroupSource,
  resolveGroupLike,
  type GroupLike,
} from '../groups/GroupLabel';

interface ClassroomListPaneProps {
  admin: boolean;
  searchQuery: string;
  onSearchChange: (value: string) => void;
  onOpenNewModal: () => void;
  isInitialLoading: boolean;
  loadError: string | null;
  filteredClassrooms: Classroom[];
  selectedClassroomId: string | null;
  onSelectClassroom: (id: string) => void;
  groupById: ReadonlyMap<string, GroupLike>;
  onRetry: () => void;
}

const ClassroomListPane: React.FC<ClassroomListPaneProps> = ({
  admin,
  searchQuery,
  onSearchChange,
  onOpenNewModal,
  isInitialLoading,
  loadError,
  filteredClassrooms,
  selectedClassroomId,
  onSelectClassroom,
  groupById,
  onRetry,
}) => {
  return (
    <div className="w-full shrink-0 md:max-w-md flex flex-col gap-4">
      <div className="flex justify-between items-center px-1">
        <h2 className="text-lg font-bold text-slate-800">Classrooms</h2>
        {admin && (
          <button
            onClick={onOpenNewModal}
            className="bg-blue-600 hover:bg-blue-700 text-white px-3 py-1.5 rounded-lg text-sm flex items-center gap-2 transition-colors shadow-sm font-medium"
            data-testid="classrooms-new-button"
          >
            <Plus size={16} /> New Classroom
          </button>
        )}
      </div>

      <div className="relative">
        <Search size={16} className="absolute left-3 top-3 text-slate-400" />
        <input
          type="text"
          placeholder="Search classroom..."
          value={searchQuery}
          onChange={(e) => onSearchChange(e.target.value)}
          className="w-full bg-white border border-slate-200 rounded-lg py-2.5 pl-9 pr-4 text-sm text-slate-900 focus:border-blue-500 focus:ring-1 focus:ring-blue-500 outline-none shadow-sm transition-all"
        />
      </div>

      <div className="flex-1 space-y-3 md:overflow-y-auto md:pr-2 custom-scrollbar">
        {isInitialLoading ? (
          <div className="flex items-center justify-center py-12">
            <Loader2 className="w-6 h-6 animate-spin text-slate-400" />
            <span className="ml-2 text-slate-500 text-sm">Loading classrooms...</span>
          </div>
        ) : loadError ? (
          <div className="text-center py-8">
            <AlertCircle className="w-6 h-6 text-red-400 mx-auto" />
            <span className="text-red-500 text-sm mt-2 block">{loadError}</span>
            <button onClick={onRetry} className="text-blue-600 hover:text-blue-800 text-sm mt-2">
              Retry
            </button>
          </div>
        ) : filteredClassrooms.length === 0 ? (
          <div className="text-center py-8 text-slate-500 text-sm">No classrooms found</div>
        ) : (
          filteredClassrooms.map((room) => {
            const inferredSource = inferGroupSource({
              currentGroupSource: room.currentGroupSource ?? null,
              activeGroupId: room.activeGroup,
              currentGroupId: room.currentGroupId,
              defaultGroupId: room.defaultGroupId,
            });
            const currentGroup = resolveGroupLike({
              groupId: room.currentGroupId,
              groupById,
              displayName: room.currentGroupDisplayName,
            });

            return (
              <div
                key={room.id}
                onClick={() => onSelectClassroom(room.id)}
                className={`p-4 rounded-lg border cursor-pointer transition-all ${
                  selectedClassroomId === room.id
                    ? 'bg-blue-50 border-blue-200 ring-1 ring-blue-200 shadow-sm'
                    : 'bg-white border-slate-200 hover:border-blue-200 hover:shadow-sm'
                }`}
              >
                <div className="flex justify-between items-start mb-2">
                  <h3
                    className={`font-semibold text-sm ${
                      selectedClassroomId === room.id ? 'text-blue-800' : 'text-slate-800'
                    }`}
                  >
                    {room.name}
                  </h3>
                  {selectedClassroomId === room.id && (
                    <div className="w-2 h-2 rounded-full bg-blue-500"></div>
                  )}
                </div>
                <div className="flex items-center gap-4 text-xs text-slate-500">
                  <span className="flex items-center gap-1">
                    <Laptop size={12} /> {room.computerCount} Computers
                  </span>
                  <GroupLabel
                    groupId={room.currentGroupId}
                    group={room.currentGroupId ? currentGroup : null}
                    source={inferredSource}
                    revealUnknownId={admin}
                    showSourceTag={inferredSource !== 'none'}
                  />
                </div>
              </div>
            );
          })
        )}
      </div>
    </div>
  );
};

export default ClassroomListPane;
