import React, { useEffect } from 'react';
import { Trash2 } from 'lucide-react';

import { useClassroomGroupControls } from '../hooks/useClassroomGroupControls';
import { useClassroomMachines } from '../hooks/useClassroomMachines';
import { useClassroomSchedules } from '../hooks/useClassroomSchedules';
import { useClassroomsViewModel } from '../hooks/useClassroomsViewModel';
import ClassroomDetailPane from '../components/classrooms/ClassroomDetailPane';
import ClassroomListPane from '../components/classrooms/ClassroomListPane';
import EnrollClassroomModal from '../components/classrooms/EnrollClassroomModal';
import NewClassroomModal from '../components/classrooms/NewClassroomModal';
import ScheduleFormModal from '../components/ScheduleFormModal';
import OneOffScheduleFormModal from '../components/OneOffScheduleFormModal';
import { ConfirmDialog, DangerConfirmDialog } from '../components/ui/ConfirmDialog';
import { useT } from '../i18n/product-i18n';

interface ClassroomsProps {
  initialSelectedClassroomId?: string | null;
  onInitialSelectedClassroomIdConsumed?: () => void;
}

const Classrooms: React.FC<ClassroomsProps> = ({
  initialSelectedClassroomId = null,
  onInitialSelectedClassroomIdConsumed,
}) => {
  const t = useT();
  const {
    admin,
    allowedGroups,
    calendarGroupsForDisplay,
    deleteDialog,
    filteredClassrooms,
    groupById,
    groupOptions,
    isInitialLoading,
    loadError,
    newModal,
    refetchClassrooms,
    retryLoad,
    searchQuery,
    selectedClassroom,
    selectedClassroomId,
    setSearchQuery,
    setSelectedClassroomId,
  } = useClassroomsViewModel({
    initialSelectedClassroomId,
  });

  useEffect(() => {
    if (initialSelectedClassroomId !== null) {
      onInitialSelectedClassroomIdConsumed?.();
    }
  }, [initialSelectedClassroomId, onInitialSelectedClassroomIdConsumed]);

  const {
    activeGroupOverwriteConfirm,
    activeGroupOverwriteLoading,
    activeGroupSelectValue,
    classroomConfigError,
    closeActiveGroupOverwriteConfirm,
    confirmActiveGroupOverwrite,
    defaultGroupSelectValue,
    handleDefaultGroupChange,
    requestActiveGroupChange,
    resolveGroupName,
    selectedClassroomSource,
  } = useClassroomGroupControls({
    admin,
    selectedClassroom,
    groupById,
    refetchClassrooms,
    setSelectedClassroom: (classroom) => setSelectedClassroomId(classroom?.id ?? null),
  });

  const {
    schedules,
    oneOffSchedules,
    loadingSchedules,
    scheduleFormOpen,
    editingSchedule,
    scheduleFormDay,
    scheduleFormStartTime,
    oneOffFormOpen,
    editingOneOffSchedule,
    scheduleSaving,
    scheduleError,
    scheduleDeleteTarget,
    openScheduleCreate,
    openScheduleEdit,
    closeScheduleForm,
    openOneOffScheduleCreate,
    openOneOffScheduleEdit,
    closeOneOffScheduleForm,
    handleScheduleSave,
    handleOneOffScheduleSave,
    requestScheduleDelete,
    requestOneOffScheduleDelete,
    closeScheduleDelete,
    handleConfirmDeleteSchedule,
  } = useClassroomSchedules({
    selectedClassroomId: selectedClassroom?.id ?? null,
    onSchedulesUpdated: async () => {
      await refetchClassrooms();
    },
  });

  const {
    activeSchedule,
    exemptionByMachineId,
    exemptionMutating,
    exemptionsError,
    handleCreateExemption,
    handleCreateOperationalExemption,
    handleDeleteExemption,
    loadingExemptions,
    sortedOneOffSchedules,
    enrollModal,
  } = useClassroomMachines({
    selectedClassroom,
    schedules,
    oneOffSchedules,
    refetchClassrooms,
  });

  return (
    <div className="flex flex-col gap-6 lg:h-full lg:min-h-0 lg:flex-row lg:overflow-hidden">
      <ClassroomListPane
        admin={admin}
        searchQuery={searchQuery}
        onSearchChange={setSearchQuery}
        onOpenNewModal={newModal.open}
        isInitialLoading={isInitialLoading}
        loadError={loadError}
        filteredClassrooms={filteredClassrooms}
        selectedClassroomId={selectedClassroomId}
        onSelectClassroom={(id) => setSelectedClassroomId(id)}
        groupById={groupById}
        onRetry={retryLoad}
      />

      {/* Detail Column */}
      <div className="min-w-0 flex-1 flex flex-col lg:min-h-0 lg:overflow-hidden">
        <ClassroomDetailPane
          admin={admin}
          allowedGroups={allowedGroups}
          calendarGroupsForDisplay={calendarGroupsForDisplay}
          classroomConfigError={classroomConfigError}
          activeGroupSelectValue={activeGroupSelectValue}
          defaultGroupSelectValue={defaultGroupSelectValue}
          selectedClassroom={selectedClassroom}
          selectedClassroomSource={selectedClassroomSource}
          groupById={groupById}
          schedules={schedules}
          sortedOneOffSchedules={sortedOneOffSchedules}
          loadingSchedules={loadingSchedules}
          scheduleError={scheduleError}
          activeSchedule={activeSchedule}
          exemptionByMachineId={exemptionByMachineId}
          exemptionMutating={exemptionMutating}
          exemptionsError={exemptionsError}
          loadingExemptions={loadingExemptions}
          enrollModalLoadingToken={enrollModal.loadingToken}
          onOpenNewModal={newModal.open}
          onOpenDeleteDialog={deleteDialog.open}
          onRequestActiveGroupChange={requestActiveGroupChange}
          onDefaultGroupChange={handleDefaultGroupChange}
          onOpenEnrollModal={enrollModal.open}
          onCreateExemption={handleCreateExemption}
          onCreateOperationalExemption={handleCreateOperationalExemption}
          onDeleteExemption={handleDeleteExemption}
          onOpenScheduleCreate={openScheduleCreate}
          onOpenScheduleEdit={openScheduleEdit}
          onRequestScheduleDelete={requestScheduleDelete}
          onOpenOneOffScheduleCreate={openOneOffScheduleCreate}
          onOpenOneOffScheduleEdit={openOneOffScheduleEdit}
          onRequestOneOffScheduleDelete={requestOneOffScheduleDelete}
        />
      </div>

      <NewClassroomModal
        isOpen={newModal.isOpen}
        saving={newModal.saving}
        newName={newModal.newName}
        newGroup={newModal.newGroup}
        newError={newModal.newError}
        groupOptions={groupOptions}
        onClose={newModal.close}
        onNameChange={newModal.setName}
        onGroupChange={newModal.setGroup}
        onCreate={() => void newModal.create()}
      />

      <ConfirmDialog
        isOpen={activeGroupOverwriteConfirm !== null}
        title={t('classrooms.dialog.replaceActiveGroup.title')}
        confirmLabel={t('classrooms.dialog.replaceActiveGroup.confirm')}
        cancelLabel={t('common.cancel')}
        isLoading={activeGroupOverwriteLoading}
        onClose={closeActiveGroupOverwriteConfirm}
        onConfirm={() => void confirmActiveGroupOverwrite()}
      >
        <p className="text-sm text-slate-600">
          {t('classrooms.dialog.replaceActiveGroup.current', {
            groupName: resolveGroupName(activeGroupOverwriteConfirm?.currentGroupId ?? null),
          })}
        </p>
        <p className="text-sm text-slate-600">
          {t('classrooms.dialog.replaceActiveGroup.next', {
            groupName: resolveGroupName(activeGroupOverwriteConfirm?.nextGroupId ?? null),
          })}
        </p>
      </ConfirmDialog>

      {/* Modal: Configurar Horario */}
      {scheduleFormOpen && selectedClassroom && (
        <ScheduleFormModal
          key={editingSchedule?.id ?? 'create'}
          schedule={editingSchedule}
          defaultDay={scheduleFormDay}
          defaultStartTime={scheduleFormStartTime}
          groups={allowedGroups}
          saving={scheduleSaving}
          error={scheduleError}
          onSave={(data) => void handleScheduleSave(data)}
          onClose={closeScheduleForm}
        />
      )}

      {oneOffFormOpen && selectedClassroom && (
        <OneOffScheduleFormModal
          key={editingOneOffSchedule?.id ?? 'one-off-create'}
          schedule={editingOneOffSchedule}
          groups={allowedGroups}
          saving={scheduleSaving}
          error={scheduleError}
          onSave={(data) => void handleOneOffScheduleSave(data)}
          onClose={closeOneOffScheduleForm}
        />
      )}

      {/* Modal: Confirmar Eliminación */}
      {deleteDialog.isOpen && selectedClassroom && (
        <DangerConfirmDialog
          isOpen
          title={t('classrooms.dialog.deleteClassroom.title')}
          confirmLabel={t('common.delete')}
          cancelLabel={t('common.cancel')}
          isLoading={deleteDialog.deleting}
          onClose={deleteDialog.close}
          onConfirm={() => void deleteDialog.confirm()}
        >
          <div className="text-center">
            <div className="w-12 h-12 bg-red-100 rounded-full flex items-center justify-center mx-auto mb-4">
              <Trash2 className="text-red-600" size={24} />
            </div>
            <p className="text-sm text-slate-600">
              {t('classrooms.dialog.deleteClassroom.body', {
                classroomName: selectedClassroom.name,
              })}
            </p>
            <p className="text-xs text-slate-500 mt-1">
              {t('common.dialog.destructiveActionCannotBeUndone')}
            </p>
          </div>
        </DangerConfirmDialog>
      )}

      {/* Modal: Confirmar Eliminación de Horario */}
      {scheduleDeleteTarget && selectedClassroom && (
        <DangerConfirmDialog
          isOpen
          title={t('classrooms.dialog.deleteSchedule.title')}
          confirmLabel={t('common.delete')}
          cancelLabel={t('common.cancel')}
          isLoading={scheduleSaving}
          errorMessage={scheduleError}
          onClose={closeScheduleDelete}
          onConfirm={() => void handleConfirmDeleteSchedule()}
        >
          <div className="text-center">
            <div className="w-12 h-12 bg-red-100 rounded-full flex items-center justify-center mx-auto mb-4">
              <Trash2 className="text-red-600" size={24} />
            </div>
            <p className="text-sm text-slate-600">
              {t('classrooms.dialog.deleteSchedule.body', { label: scheduleDeleteTarget.label })}
            </p>
            <p className="text-xs text-slate-500 mt-1">
              {t('common.dialog.destructiveActionCannotBeUndone')}
            </p>
          </div>
        </DangerConfirmDialog>
      )}

      <EnrollClassroomModal
        isOpen={enrollModal.isOpen}
        enrollToken={enrollModal.enrollToken}
        selectedClassroom={selectedClassroom}
        enrollPlatform={enrollModal.enrollPlatform}
        enrollCommand={enrollModal.enrollCommand}
        onClose={enrollModal.close}
        onSelectPlatform={enrollModal.selectPlatform}
        onCopy={enrollModal.copy}
        isCopied={enrollModal.isCopied}
      />
    </div>
  );
};

export default Classrooms;
