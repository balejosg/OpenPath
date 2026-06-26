import type { ExportFormat } from '../../lib/exportRules';
import type { RuleType } from '../../lib/rules';
import { getRuleTypeBadge } from '../../lib/rules';
import { ExportDropdown } from '../ExportDropdown';
import { Button } from '../ui/Button';
import { AlertCircle, Info, Plus, Search, Upload } from 'lucide-react';
import { cn } from '../../lib/utils';
import { useT } from '../../i18n/product-i18n';

interface RulesManagerToolbarProps {
  readOnly: boolean;
  search: string;
  countsAll: number;
  newValue: string;
  adding: boolean;
  loading: boolean;
  inputError: string;
  validationError: string;
  rulesCount: number;
  detectedType: { type: RuleType; confidence: 'high' | 'medium' } | null;
  onSearchChange: (value: string) => void;
  onInputChange: (value: string) => void;
  onAddRule: () => void;
  onAddKeyDown: (event: React.KeyboardEvent<HTMLInputElement>) => void;
  onOpenImport: () => void;
  onExport: (format: ExportFormat) => void;
}

export function RulesManagerToolbar({
  readOnly,
  search,
  countsAll,
  newValue,
  adding,
  loading,
  inputError,
  validationError,
  rulesCount,
  detectedType,
  onSearchChange,
  onInputChange,
  onAddRule,
  onAddKeyDown,
  onOpenImport,
  onExport,
}: RulesManagerToolbarProps) {
  const t = useT();
  return (
    <>
      <div className="flex flex-col sm:flex-row gap-4">
        <div className="relative flex-1">
          <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" />
          <input
            type="text"
            placeholder={t('rules.manager.searchPlaceholder', { count: String(countsAll) })}
            value={search}
            onChange={(event) => onSearchChange(event.target.value)}
            className="w-full pl-9 pr-4 py-2 border border-slate-200 rounded-lg text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none"
          />
        </div>

        <div className="flex gap-2 sm:w-auto w-full">
          {!readOnly && (
            <>
              <div className="flex-1 sm:w-80">
                <input
                  type="text"
                  placeholder={t('rules.manager.addPlaceholder')}
                  value={newValue}
                  onChange={(event) => onInputChange(event.target.value)}
                  onKeyDown={onAddKeyDown}
                  className={cn(
                    'w-full px-4 py-2 border rounded-lg text-sm focus:ring-2 focus:ring-blue-500 outline-none',
                    inputError || validationError
                      ? 'border-red-300 focus:ring-red-500'
                      : 'border-slate-200'
                  )}
                />
              </div>
              <Button
                onClick={onAddRule}
                disabled={adding || !newValue.trim() || !!validationError}
                isLoading={adding}
                size="md"
              >
                <Plus size={16} className="mr-1" />
                {t('common.add')}
              </Button>
              <Button
                variant="outline"
                onClick={onOpenImport}
                size="md"
                title={t('rules.manager.importTitle')}
              >
                <Upload size={16} className="mr-1" />
                {t('common.import')}
              </Button>
            </>
          )}
          <ExportDropdown onExport={onExport} rulesCount={rulesCount} disabled={loading} />
        </div>
      </div>

      {detectedType && !inputError && !validationError && (
        <p className="text-xs text-slate-500 flex items-center gap-1 -mt-2">
          <Info size={12} />
          {t('rules.manager.willBeAddedAs')}{' '}
          <span
            className={cn(
              'font-medium',
              detectedType.type === 'whitelist' ? 'text-green-600' : 'text-red-600'
            )}
          >
            {getRuleTypeBadge(detectedType.type)}
          </span>
          {detectedType.confidence === 'medium' && (
            <span className="text-amber-600"> {t('rules.manager.suggested')}</span>
          )}
        </p>
      )}

      {validationError && !inputError && (
        <p className="text-red-500 text-xs flex items-center gap-1 -mt-2">
          <AlertCircle size={12} />
          {validationError}
        </p>
      )}

      {inputError && (
        <p className="text-red-500 text-xs flex items-center gap-1 -mt-2">
          <AlertCircle size={12} />
          {inputError}
        </p>
      )}
    </>
  );
}
