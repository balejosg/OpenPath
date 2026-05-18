import { useCallback, useMemo, useState } from 'react';
import type { Classroom, OneOffScheduleWithPermissions, ScheduleWithPermissions } from '../types';
import { getAuthTokenForHeader } from '../lib/auth-storage';
import { reportError } from '../lib/reportError';
import { useClipboard } from './useClipboard';
import { useClassroomExemptions } from './useClassroomExemptions';

export function findActiveSchedule(params: {
  schedules: ScheduleWithPermissions[];
  oneOffSchedules: OneOffScheduleWithPermissions[];
  now?: Date;
}) {
  const now = params.now ?? new Date();

  const activeOneOff =
    params.oneOffSchedules.find((schedule) => {
      const start = new Date(schedule.startAt);
      const end = new Date(schedule.endAt);
      if (!Number.isFinite(start.getTime()) || !Number.isFinite(end.getTime())) {
        return false;
      }

      return start.getTime() <= now.getTime() && end.getTime() > now.getTime();
    }) ?? null;

  if (activeOneOff) {
    return activeOneOff;
  }

  const day = now.getDay();
  if (day === 0 || day === 6) {
    return null;
  }

  const currentTime = now.toTimeString().slice(0, 5);
  return (
    params.schedules.find(
      (schedule) =>
        schedule.dayOfWeek === day &&
        schedule.startTime <= currentTime &&
        schedule.endTime > currentTime
    ) ?? null
  );
}

export function sortOneOffSchedules(oneOffSchedules: OneOffScheduleWithPermissions[]) {
  return [...oneOffSchedules].sort((a, b) => {
    const aTime = new Date(a.startAt).getTime();
    const bTime = new Date(b.startAt).getTime();
    const aOk = Number.isFinite(aTime);
    const bOk = Number.isFinite(bTime);
    if (aOk && bOk) return aTime - bTime;
    if (aOk) return -1;
    if (bOk) return 1;
    return 0;
  });
}

function quotePowerShellSingle(value: string) {
  return value.replaceAll("'", "''");
}

function encodePowerShellCommand(command: string) {
  const utf16le = new Uint8Array(command.length * 2);

  for (let index = 0; index < command.length; index += 1) {
    const codeUnit = command.charCodeAt(index);
    utf16le[index * 2] = codeUnit & 0xff;
    utf16le[index * 2 + 1] = codeUnit >> 8;
  }

  let binary = '';
  const chunkSize = 0x8000;
  for (let index = 0; index < utf16le.length; index += chunkSize) {
    binary += String.fromCharCode(...utf16le.subarray(index, index + chunkSize));
  }

  return btoa(binary);
}

export function buildEnrollCommands(params: {
  apiUrl: string;
  classroomId: string | null;
  enrollToken: string | null;
}) {
  if (!params.classroomId || !params.enrollToken) {
    return {
      linuxCommand: '',
      windowsCommand: '',
    };
  }

  const encodedClassroomId = encodeURIComponent(params.classroomId);
  const linuxCommand = `curl -fsSL -H 'Authorization: Bearer ${params.enrollToken}' '${params.apiUrl}/api/enroll/${encodedClassroomId}' | sudo bash`;
  const windowsScriptUrl = `${params.apiUrl}/api/enroll/${encodedClassroomId}/windows.ps1`;
  const windowsCommandScript = [
    `$t='${quotePowerShellSingle(params.enrollToken)}';`,
    '[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;',
    `irm -Headers @{Authorization=('Bearer '+$t)} '${quotePowerShellSingle(windowsScriptUrl)}' | iex`,
  ].join(' ');
  const windowsCommand = `powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand ${encodePowerShellCommand(windowsCommandScript)}`;

  return {
    linuxCommand,
    windowsCommand,
  };
}

export function useClassroomMachines(params: {
  selectedClassroom: Classroom | null;
  schedules: ScheduleWithPermissions[];
  oneOffSchedules: OneOffScheduleWithPermissions[];
  refetchClassrooms: () => Promise<Classroom[]>;
}) {
  const { selectedClassroom, schedules, oneOffSchedules, refetchClassrooms } = params;
  const [showEnrollModal, setShowEnrollModal] = useState(false);
  const [enrollToken, setEnrollToken] = useState<string | null>(null);
  const [enrollPlatform, setEnrollPlatform] = useState<'linux' | 'windows'>('linux');
  const [loadingToken, setLoadingToken] = useState(false);

  const {
    copy: copyEnrollCommand,
    isCopied: isEnrollCommandCopied,
    clearCopied: clearEnrollCommandCopied,
  } = useClipboard();

  const activeSchedule = useMemo(
    () => findActiveSchedule({ schedules, oneOffSchedules }),
    [oneOffSchedules, schedules]
  );

  const scheduleBoundarySources = useMemo(
    () => [...schedules, ...oneOffSchedules],
    [schedules, oneOffSchedules]
  );

  const sortedOneOffSchedules = useMemo(
    () => sortOneOffSchedules(oneOffSchedules),
    [oneOffSchedules]
  );

  const {
    exemptionByMachineId,
    exemptionMutating,
    exemptionsError,
    handleCreateExemption,
    handleCreateOperationalExemption,
    handleDeleteExemption,
    loadingExemptions,
    setExemptionsError,
  } = useClassroomExemptions({
    selectedClassroom,
    activeSchedule,
    scheduleBoundarySources,
    refetchClassrooms,
  });

  const openEnrollModal = useCallback(async () => {
    setLoadingToken(true);
    try {
      if (!selectedClassroom) {
        setExemptionsError('Select a classroom first');
        return;
      }

      const authToken = getAuthTokenForHeader();
      const response = await fetch(
        `/api/enroll/${encodeURIComponent(selectedClassroom.id)}/ticket`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            ...(authToken ? { Authorization: `Bearer ${authToken}` } : {}),
          },
        }
      );

      if (!response.ok) {
        throw new Error(`HTTP ${String(response.status)}`);
      }

      const data = (await response.json()) as {
        success: boolean;
        enrollmentToken?: string;
      };

      if (!data.success || !data.enrollmentToken) {
        throw new Error('No enrollment token received');
      }

      setEnrollToken(data.enrollmentToken);
      setEnrollPlatform('linux');
      setShowEnrollModal(true);
    } catch (err) {
      reportError('Failed to get enrollment ticket:', err);
      setExemptionsError('Unable to generate install command');
    } finally {
      setLoadingToken(false);
    }
  }, [selectedClassroom, setExemptionsError]);

  const closeEnrollModal = useCallback(() => {
    clearEnrollCommandCopied();
    setShowEnrollModal(false);
  }, [clearEnrollCommandCopied]);

  const apiUrl = window.location.origin;
  const { linuxCommand, windowsCommand } = buildEnrollCommands({
    apiUrl,
    classroomId: selectedClassroom?.id ?? null,
    enrollToken,
  });
  const enrollCommand = enrollPlatform === 'windows' ? windowsCommand : linuxCommand;

  const copyEnrollmentCommand = useCallback(() => {
    void copyEnrollCommand(enrollCommand, 'enroll-command');
  }, [copyEnrollCommand, enrollCommand]);

  return {
    activeSchedule,
    exemptionByMachineId,
    exemptionMutating,
    exemptionsError,
    handleCreateExemption,
    handleCreateOperationalExemption,
    handleDeleteExemption,
    loadingExemptions,
    sortedOneOffSchedules,
    enrollModal: {
      isOpen: showEnrollModal,
      enrollToken,
      enrollPlatform,
      enrollCommand,
      loadingToken,
      open: openEnrollModal,
      close: closeEnrollModal,
      selectPlatform: setEnrollPlatform,
      copy: copyEnrollmentCommand,
      isCopied: isEnrollCommandCopied('enroll-command'),
    },
  };
}
