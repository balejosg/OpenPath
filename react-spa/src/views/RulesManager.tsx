import React from 'react';
import { FileUp, Info } from 'lucide-react';
import { useT } from '../i18n/product-i18n';
import { BulkActionBar } from '../components/BulkActionBar';
import { BulkImportModal } from '../components/BulkImportModal';
import { RulesManagerHeader } from '../components/rules-manager/RulesManagerHeader';
import { RulesManagerPagination } from '../components/rules-manager/RulesManagerPagination';
import { RulesManagerTableSection } from '../components/rules-manager/RulesManagerTableSection';
import { RulesManagerToolbar } from '../components/rules-manager/RulesManagerToolbar';
import { useToast } from '../components/ui/Toast';
import { exportRules } from '../lib/exportRules';
import { useRulesManagerViewModel } from '../hooks/useRulesManagerViewModel';
import { useGroupSettings } from '../hooks/useGroupSettings';
import { GroupSettingsDrawer } from '../components/groups/GroupSettingsDrawer';

interface RulesManagerProps {
  groupId: string;
  groupName: string;
  readOnly?: boolean;
  onBack: () => void;
}

export const RulesManager: React.FC<RulesManagerProps> = ({
  groupId,
  groupName,
  readOnly = false,
  onBack,
}) => {
  const t = useT();
  const { success, error: toastError, ToastContainer } = useToast();
  const viewModel = useRulesManagerViewModel({
    groupId,
    onToast: (message, type, undoAction) => {
      if (type === 'success') {
        success(message, undoAction);
      } else {
        toastError(message);
      }
    },
    onError: toastError,
  });
  const { collection } = viewModel;
  const settings = useGroupSettings({ groupId, active: !readOnly });

  return (
    <div
      className="space-y-6 relative"
      onDragEnter={readOnly ? undefined : viewModel.handleDragEnter}
      onDragLeave={readOnly ? undefined : viewModel.handleDragLeave}
      onDragOver={readOnly ? undefined : viewModel.handleDragOver}
      onDrop={readOnly ? undefined : viewModel.handleDrop}
    >
      {!readOnly && viewModel.isDragOver && (
        <div
          className="absolute inset-0 z-50 flex items-center justify-center bg-blue-50/95 rounded-xl border-2 border-dashed border-blue-400 pointer-events-none"
          data-testid="page-drag-overlay"
        >
          <div className="text-center">
            <FileUp size={48} className="mx-auto text-blue-500 mb-3" />
            <p className="text-lg font-medium text-blue-700">{t('rulesManager.dragOverTitle')}</p>
            <p className="text-sm text-blue-500 mt-1">{t('rulesManager.dragOverBody')}</p>
            <p className="text-xs text-blue-400 mt-2">.txt, .csv, .list</p>
          </div>
        </div>
      )}

      <RulesManagerHeader
        groupName={groupName}
        viewMode={viewModel.viewMode}
        onBack={onBack}
        onViewModeChange={viewModel.handleViewModeChange}
        status={!readOnly ? settings.metadata?.status : undefined}
        visibility={!readOnly ? settings.metadata?.visibility : undefined}
        onOpenSettings={!readOnly && settings.metadata ? settings.open : undefined}
      />

      {readOnly && (
        <div className="bg-amber-50 border border-amber-200 rounded-lg p-3 text-amber-900 text-sm flex items-start gap-2">
          <Info size={16} className="mt-0.5 text-amber-700" />
          <div>
            <p className="font-medium">{t('rulesManager.readOnlyTitle')}</p>
            <p className="text-amber-800">{t('rulesManager.readOnlyBody')}</p>
          </div>
        </div>
      )}

      <RulesManagerToolbar
        readOnly={readOnly}
        search={collection.search}
        countsAll={collection.counts.all}
        newValue={viewModel.newValue}
        adding={viewModel.adding}
        loading={collection.loading}
        inputError={viewModel.inputError}
        validationError={viewModel.validationError}
        rulesCount={collection.rules.length}
        detectedType={viewModel.detectedType}
        onSearchChange={collection.setSearch}
        onInputChange={viewModel.handleInputChange}
        onAddRule={() => {
          void viewModel.handleAddRule(readOnly);
        }}
        onAddKeyDown={(event) => {
          if (event.key === 'Enter' && !viewModel.adding && viewModel.newValue.trim()) {
            event.preventDefault();
            void viewModel.handleAddRule(readOnly);
          }
        }}
        onOpenImport={viewModel.openImportModal}
        onExport={(format) => exportRules(collection.rules, format, `${groupName}-rules`)}
      />

      <RulesManagerTableSection
        tabs={viewModel.tabs}
        filter={collection.filter}
        error={collection.error}
        viewMode={viewModel.viewMode}
        rules={collection.rules}
        domainGroups={collection.domainGroups}
        loading={collection.loading}
        readOnly={readOnly}
        selectedIds={collection.selection.selectedIds}
        isAllSelected={collection.selection.isAllSelected}
        hasSelection={collection.selection.hasSelection}
        emptyMessage={viewModel.emptyMessage}
        onFilterChange={collection.setFilter}
        onRetry={() => {
          void collection.refetch();
        }}
        onDelete={(rule) => {
          void collection.actions.deleteRule(rule);
        }}
        onToggleEnabled={(rule) =>
          void collection.actions.setRuleEnabled(rule, rule.enabled === false)
        }
        onSave={collection.actions.updateRule}
        onToggleSelection={collection.selection.toggleSelection}
        onToggleSelectAll={collection.selection.toggleSelectAll}
      />

      <RulesManagerPagination
        viewMode={viewModel.viewMode}
        loading={collection.loading}
        error={collection.error}
        page={collection.page}
        totalPages={collection.totalPages}
        total={collection.totalRules}
        totalGroups={collection.totalGroups}
        visibleGroups={collection.domainGroups.length}
        onPageChange={collection.setPage}
      />

      <ToastContainer />

      {!readOnly && (
        <BulkActionBar
          selectedCount={collection.selection.selectedIds.size}
          onDelete={() => void viewModel.handleBulkDelete()}
          onClear={collection.selection.clearSelection}
          isDeleting={viewModel.bulkDeleting}
          onDisable={() => void collection.actions.bulkSetRulesEnabled(false)}
          onEnable={() => void collection.actions.bulkSetRulesEnabled(true)}
        />
      )}

      {!readOnly && (
        <BulkImportModal
          isOpen={viewModel.showImportModal}
          onClose={viewModel.closeImportModal}
          onImport={collection.actions.bulkCreateRules}
          initialText={viewModel.importInitialText}
        />
      )}

      {!readOnly && (
        <GroupSettingsDrawer
          isOpen={settings.isOpen}
          title={t('groups.settingsDrawer.title', { name: groupName })}
          saving={settings.saving}
          description={settings.description}
          status={settings.status}
          visibility={settings.visibility}
          error={settings.error}
          onClose={settings.close}
          onDescriptionChange={settings.setDescription}
          onStatusChange={settings.setStatus}
          onVisibilityChange={settings.setVisibility}
          onSave={() => {
            void settings.save();
          }}
        />
      )}
    </div>
  );
};

export default RulesManager;
