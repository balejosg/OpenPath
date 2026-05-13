import React, { useState } from 'react';
import { AlertCircle, Download, Loader2, Monitor, X } from 'lucide-react';
import type { Classroom, ClassroomExemption } from '../../types';

interface ClassroomMachinesCardProps {
  admin: boolean;
  classroom: Classroom;
  hasActiveSchedule: boolean;
  exemptionByMachineId: ReadonlyMap<string, ClassroomExemption>;
  exemptionMutating: Partial<Record<string, boolean>>;
  exemptionsError: string | null;
  loadingExemptions: boolean;
  enrollModalLoadingToken: boolean;
  onOpenEnrollModal: () => void | Promise<void>;
  onCreateExemption: (machineId: string) => void | Promise<void>;
  onCreateOperationalExemption: (
    machineId: string,
    durationHours: number,
    reason: string
  ) => void | Promise<void>;
  onDeleteExemption: (machineId: string) => void | Promise<void>;
}

export default function ClassroomMachinesCard({
  admin,
  classroom,
  hasActiveSchedule,
  exemptionByMachineId,
  exemptionMutating,
  exemptionsError,
  loadingExemptions,
  enrollModalLoadingToken,
  onOpenEnrollModal,
  onCreateExemption,
  onCreateOperationalExemption,
  onDeleteExemption,
}: ClassroomMachinesCardProps) {
  const [operationalMachineId, setOperationalMachineId] = useState<string | null>(null);
  const [durationHours, setDurationHours] = useState('1');
  const [reason, setReason] = useState('');
  const canCreateScheduleExemption = classroom.currentGroupSource === 'schedule';

  const submitOperationalExemption = () => {
    if (!operationalMachineId) return;
    void onCreateOperationalExemption(operationalMachineId, Number(durationHours), reason.trim());
    setOperationalMachineId(null);
    setDurationHours('1');
    setReason('');
  };

  return (
    <div className="bg-white border border-slate-200 rounded-lg p-6 flex-1 min-h-[300px] flex flex-col shadow-sm">
      <div className="flex justify-between items-center mb-6">
        <h3 className="font-semibold text-slate-900 flex items-center gap-2">
          <Monitor size={18} className="text-blue-500" />
          Máquinas Registradas
        </h3>
        <div className="flex items-center gap-2">
          {admin && (
            <button
              onClick={() => void onOpenEnrollModal()}
              disabled={enrollModalLoadingToken}
              className="bg-blue-600 hover:bg-blue-700 text-white px-3 py-1.5 rounded-lg text-sm flex items-center gap-2 transition-colors shadow-sm font-medium disabled:opacity-50"
            >
              {enrollModalLoadingToken ? (
                <Loader2 size={16} className="animate-spin" />
              ) : (
                <Download size={16} />
              )}
              Instalar equipos
            </button>
          )}
          <span className="text-xs bg-slate-100 px-2 py-1 rounded text-slate-600 border border-slate-200 font-medium">
            Total: {classroom.computerCount}
          </span>
        </div>
      </div>

      {exemptionsError && (
        <div className="mb-3 p-3 bg-red-50 text-red-600 text-sm rounded-lg border border-red-100 flex items-center gap-2">
          <AlertCircle size={16} />
          <span>{exemptionsError}</span>
        </div>
      )}

      {classroom.machines && classroom.machines.length > 0 ? (
        <div className="flex-1 space-y-2 overflow-auto">
          {classroom.machines.map((machine) => {
            const exemption = exemptionByMachineId.get(machine.id);
            const isExempt = exemption !== undefined;
            const mutating = exemptionMutating[machine.id] ?? false;

            const statusColor =
              machine.status === 'online'
                ? 'bg-green-500'
                : machine.status === 'stale'
                  ? 'bg-yellow-500'
                  : 'bg-red-500';

            const expiresTime = exemption
              ? new Date(exemption.expiresAt).toTimeString().slice(0, 5)
              : null;
            const exemptionSourceLabel =
              exemption?.source === 'operational' ? 'Admin' : 'Calendario';

            return (
              <div
                key={machine.id}
                className="flex items-center justify-between p-3 rounded-lg border border-slate-200 bg-white"
              >
                <div className="flex items-center gap-3 min-w-0">
                  <div className={`w-2.5 h-2.5 rounded-full ${statusColor}`} />
                  <div className="min-w-0">
                    <p className="text-sm font-medium text-slate-900 truncate">
                      {machine.hostname}
                    </p>
                    <p className="text-xs text-slate-500 truncate">
                      {machine.status === 'online'
                        ? 'En línea'
                        : machine.status === 'stale'
                          ? 'Conexión inestable'
                          : 'Sin conexión'}
                      {machine.lastSeen
                        ? ` · Último: ${new Date(machine.lastSeen).toLocaleString()}`
                        : ''}
                    </p>
                  </div>
                </div>

                <div className="flex items-center gap-2 flex-shrink-0">
                  {isExempt && (
                    <span className="text-xs bg-green-100 text-green-800 px-2 py-1 rounded-full border border-green-200 font-medium">
                      {exemptionSourceLabel}: sin restricción
                      {expiresTime ? ` · hasta ${expiresTime}` : ''}
                      {exemption.source === 'operational' && exemption.reason
                        ? ` · ${exemption.reason}`
                        : ''}
                    </span>
                  )}

                  {isExempt ? (
                    <button
                      onClick={() => void onDeleteExemption(machine.id)}
                      disabled={mutating}
                      className="bg-slate-900 hover:bg-slate-800 text-white px-3 py-1.5 rounded-lg text-sm transition-colors shadow-sm font-medium disabled:opacity-50"
                    >
                      {mutating ? '...' : 'Restringir'}
                    </button>
                  ) : admin ? (
                    <button
                      onClick={() => setOperationalMachineId(machine.id)}
                      disabled={mutating || loadingExemptions}
                      className="bg-green-600 hover:bg-green-700 text-white px-3 py-1.5 rounded-lg text-sm transition-colors shadow-sm font-medium disabled:opacity-50"
                    >
                      {mutating ? '...' : 'Eximir'}
                    </button>
                  ) : hasActiveSchedule && canCreateScheduleExemption ? (
                    <button
                      onClick={() => void onCreateExemption(machine.id)}
                      disabled={mutating || loadingExemptions}
                      className="bg-green-600 hover:bg-green-700 text-white px-3 py-1.5 rounded-lg text-sm transition-colors shadow-sm font-medium disabled:opacity-50"
                    >
                      {mutating ? '...' : 'Liberar'}
                    </button>
                  ) : null}
                </div>
              </div>
            );
          })}
        </div>
      ) : (
        <div className="flex-1 border-2 border-dashed border-slate-200 rounded-lg flex flex-col items-center justify-center p-8 text-center bg-slate-50/50">
          <Monitor size={48} className="text-slate-300 mb-3" />
          <p className="text-slate-900 font-medium text-sm">Sin máquinas activas</p>
          <p className="text-slate-500 text-xs mt-1 max-w-xs">
            Instala el agente de OpenPath en los equipos para verlos aquí.
          </p>
        </div>
      )}

      {(!hasActiveSchedule || !canCreateScheduleExemption) &&
        !admin &&
        classroom.machines &&
        classroom.machines.length > 0 && (
          <p className="mt-3 text-xs text-slate-500 italic">
            La liberación temporal solo está disponible cuando el aula está controlada por
            calendario.
          </p>
        )}

      {admin && operationalMachineId && (
        <div className="fixed inset-0 z-50 bg-slate-900/30 flex items-center justify-center p-4">
          <div className="bg-white border border-slate-200 rounded-lg shadow-xl w-full max-w-sm p-5">
            <div className="flex items-center justify-between mb-4">
              <h4 className="font-semibold text-slate-900">Eximir máquina</h4>
              <button
                type="button"
                onClick={() => setOperationalMachineId(null)}
                className="text-slate-500 hover:text-slate-700 p-1"
                aria-label="Cerrar"
              >
                <X size={18} />
              </button>
            </div>
            <label className="block text-sm font-medium text-slate-700 mb-1" htmlFor="hours">
              Horas
            </label>
            <input
              id="hours"
              aria-label="Horas"
              type="number"
              min={1}
              max={24}
              step={1}
              value={durationHours}
              onChange={(event) => setDurationHours(event.target.value)}
              className="w-full border border-slate-300 rounded-md px-3 py-2 text-sm mb-3"
            />
            <label className="block text-sm font-medium text-slate-700 mb-1" htmlFor="reason">
              Motivo
            </label>
            <textarea
              id="reason"
              aria-label="Motivo"
              value={reason}
              onChange={(event) => setReason(event.target.value)}
              className="w-full border border-slate-300 rounded-md px-3 py-2 text-sm min-h-20 mb-4"
            />
            <div className="flex justify-end gap-2">
              <button
                type="button"
                onClick={() => setOperationalMachineId(null)}
                className="px-3 py-1.5 text-sm rounded-md border border-slate-300 text-slate-700"
              >
                Cancelar
              </button>
              <button
                type="button"
                onClick={submitOperationalExemption}
                disabled={!reason.trim() || Number(durationHours) < 1 || Number(durationHours) > 24}
                className="px-3 py-1.5 text-sm rounded-md bg-green-600 text-white disabled:opacity-50"
              >
                Crear exención
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
