import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { screen, waitFor, fireEvent } from '@testing-library/react';
import Classrooms from '../Classrooms';
import { renderWithQueryClient } from '../../test-utils/query';

const hookOverrides = vi.hoisted(() => ({
  useClassroomsViewModel: null as null | ((...args: unknown[]) => unknown),
  useClassroomGroupControls: null as null | ((...args: unknown[]) => unknown),
  useClassroomSchedules: null as null | ((...args: unknown[]) => unknown),
  useClassroomMachines: null as null | ((...args: unknown[]) => unknown),
}));

let queryClient: ReturnType<typeof renderWithQueryClient>['queryClient'] | null = null;

function renderClassrooms(props?: React.ComponentProps<typeof Classrooms>) {
  const rendered = renderWithQueryClient(<Classrooms {...props} />);
  queryClient = rendered.queryClient;
  return rendered;
}

afterEach(() => {
  queryClient?.clear();
  queryClient = null;
  hookOverrides.useClassroomsViewModel = null;
  hookOverrides.useClassroomGroupControls = null;
  hookOverrides.useClassroomSchedules = null;
  hookOverrides.useClassroomMachines = null;
});

const mockClassroomsListQuery = vi.fn();
const mockClassroomsUpdateMutate = vi.fn();
const mockGroupsListQuery = vi.fn();
const mockSchedulesByClassroomQuery = vi.fn();
const mockExemptionsListQuery = vi.fn();

vi.mock('../../lib/trpc', () => ({
  trpc: {
    classrooms: {
      list: { query: (): unknown => mockClassroomsListQuery() },
      create: { mutate: vi.fn() },
      update: { mutate: (input: unknown): unknown => mockClassroomsUpdateMutate(input) },
      delete: { mutate: vi.fn() },
      setActiveGroup: { mutate: vi.fn() },
      listExemptions: { query: (): unknown => mockExemptionsListQuery() },
      createExemption: { mutate: vi.fn() },
      deleteExemption: { mutate: vi.fn() },
    },
    groups: {
      list: { query: (): unknown => mockGroupsListQuery() },
    },
    schedules: {
      getByClassroom: { query: (): unknown => mockSchedulesByClassroomQuery() },
      create: { mutate: vi.fn() },
      update: { mutate: vi.fn() },
      createOneOff: { mutate: vi.fn() },
      updateOneOff: { mutate: vi.fn() },
      delete: { mutate: vi.fn() },
    },
  },
}));

vi.mock('../../components/WeeklyCalendar', () => ({
  default: () => <div data-testid="weekly-calendar" />,
}));

vi.mock('../../components/ScheduleFormModal', () => ({
  default: ({ onSave, onClose }: { onSave: (value: unknown) => void; onClose: () => void }) => (
    <div data-testid="schedule-form-modal">
      <button onClick={() => onSave({ groupId: 'group-default' })}>Save schedule</button>
      <button onClick={onClose}>Close weekly schedule</button>
    </div>
  ),
}));

vi.mock('../../components/OneOffScheduleFormModal', () => ({
  default: ({ onSave, onClose }: { onSave: (value: unknown) => void; onClose: () => void }) => (
    <div data-testid="one-off-schedule-form-modal">
      <button onClick={() => onSave({ groupId: 'group-next' })}>Save one-off schedule</button>
      <button onClick={onClose}>Close one-off schedule</button>
    </div>
  ),
}));

vi.mock('../../hooks/useClassroomsViewModel', async () => {
  const actual = await vi.importActual<typeof import('../../hooks/useClassroomsViewModel')>(
    '../../hooks/useClassroomsViewModel'
  );
  const actualHook = actual.useClassroomsViewModel as (...args: unknown[]) => unknown;

  return {
    ...actual,
    useClassroomsViewModel: (...args: unknown[]) =>
      hookOverrides.useClassroomsViewModel
        ? hookOverrides.useClassroomsViewModel(...args)
        : actualHook(...args),
  };
});

vi.mock('../../hooks/useClassroomGroupControls', async () => {
  const actual = await vi.importActual<typeof import('../../hooks/useClassroomGroupControls')>(
    '../../hooks/useClassroomGroupControls'
  );
  const actualHook = actual.useClassroomGroupControls as (...args: unknown[]) => unknown;

  return {
    ...actual,
    useClassroomGroupControls: (...args: unknown[]) =>
      hookOverrides.useClassroomGroupControls
        ? hookOverrides.useClassroomGroupControls(...args)
        : actualHook(...args),
  };
});

vi.mock('../../hooks/useClassroomSchedules', async () => {
  const actual = await vi.importActual<typeof import('../../hooks/useClassroomSchedules')>(
    '../../hooks/useClassroomSchedules'
  );
  const actualHook = actual.useClassroomSchedules as (...args: unknown[]) => unknown;

  return {
    ...actual,
    useClassroomSchedules: (...args: unknown[]) =>
      hookOverrides.useClassroomSchedules
        ? hookOverrides.useClassroomSchedules(...args)
        : actualHook(...args),
  };
});

vi.mock('../../hooks/useClassroomMachines', async () => {
  const actual = await vi.importActual<typeof import('../../hooks/useClassroomMachines')>(
    '../../hooks/useClassroomMachines'
  );
  const actualHook = actual.useClassroomMachines as (...args: unknown[]) => unknown;

  return {
    ...actual,
    useClassroomMachines: (...args: unknown[]) =>
      hookOverrides.useClassroomMachines
        ? hookOverrides.useClassroomMachines(...args)
        : actualHook(...args),
  };
});

function buildClassroom(overrides: Record<string, unknown> = {}) {
  return {
    id: 'classroom-1',
    name: 'Laboratorio Norte',
    displayName: 'Laboratorio Norte',
    defaultGroupId: 'group-default',
    defaultGroupDisplayName: 'Grupo Default',
    activeGroupId: null,
    currentGroupId: 'group-default',
    currentGroupDisplayName: 'Grupo Default',
    currentGroupSource: 'default',
    status: 'operational',
    machineCount: 0,
    onlineMachineCount: 0,
    computerCount: 0,
    ...overrides,
  } as const;
}

function installHookOverrides(options?: {
  isInitialLoading?: boolean;
  loadError?: string | null;
  admin?: boolean;
  selectedClassroom?: Record<string, unknown>;
  newModalOpen?: boolean;
  activeGroupOverwriteOpen?: boolean;
  scheduleFormOpen?: boolean;
  oneOffFormOpen?: boolean;
  deleteDialogOpen?: boolean;
  scheduleDeleteOpen?: boolean;
  enrollPlatform?: 'linux' | 'windows';
  enrollCopied?: boolean;
}) {
  const selectedClassroom = buildClassroom(options?.selectedClassroom);
  const retryLoad = vi.fn();
  const setSelectedClassroomId = vi.fn();
  const setSearchQuery = vi.fn();
  const refetchClassrooms = vi.fn().mockResolvedValue(undefined);
  const closeNewModal = vi.fn();
  const createNewModal = vi.fn();
  const setNewModalName = vi.fn();
  const setNewModalGroup = vi.fn();
  const closeDeleteDialog = vi.fn();
  const confirmDeleteDialog = vi.fn();
  const closeOverwriteConfirm = vi.fn();
  const confirmOverwrite = vi.fn();
  const closeScheduleForm = vi.fn();
  const closeOneOffForm = vi.fn();
  const closeScheduleDelete = vi.fn();
  const confirmScheduleDelete = vi.fn();
  const closeEnrollModal = vi.fn();
  const selectPlatform = vi.fn();
  const copyEnrollCommand = vi.fn();

  hookOverrides.useClassroomsViewModel = () => ({
    admin: options?.admin ?? true,
    allowedGroups: [
      { id: 'group-default', name: 'default', displayName: 'Grupo Default' },
      { id: 'group-next', name: 'next', displayName: 'Grupo Next' },
    ],
    calendarGroupsForDisplay: [],
    deleteDialog: {
      isOpen: options?.deleteDialogOpen ?? false,
      deleting: false,
      open: vi.fn(),
      close: closeDeleteDialog,
      confirm: confirmDeleteDialog,
    },
    filteredClassrooms:
      options?.isInitialLoading || options?.loadError
        ? []
        : [
            selectedClassroom,
            buildClassroom({
              id: 'classroom-2',
              name: 'South Classroom',
              displayName: 'South Classroom',
            }),
          ],
    groupById: new Map([
      ['group-default', { id: 'group-default', name: 'default', displayName: 'Grupo Default' }],
      ['group-next', { id: 'group-next', name: 'next', displayName: 'Grupo Next' }],
    ]),
    groupOptions: [
      { value: 'group-default', label: 'Grupo Default' },
      { value: 'group-next', label: 'Grupo Next' },
    ],
    isInitialLoading: options?.isInitialLoading ?? false,
    loadError: options?.loadError ?? null,
    newModal: {
      isOpen: options?.newModalOpen ?? false,
      saving: false,
      newName: 'Laboratorio C',
      newGroup: 'group-default',
      newError: 'Name is required',
      open: vi.fn(),
      close: closeNewModal,
      setName: setNewModalName,
      setGroup: setNewModalGroup,
      create: createNewModal,
    },
    refetchClassrooms,
    retryLoad,
    searchQuery: '',
    selectedClassroom,
    selectedClassroomId: selectedClassroom.id,
    setSearchQuery,
    setSelectedClassroomId,
  });

  hookOverrides.useClassroomGroupControls = () => ({
    activeGroupOverwriteConfirm:
      (options?.activeGroupOverwriteOpen ?? false)
        ? { currentGroupId: 'group-default', nextGroupId: 'group-next' }
        : null,
    activeGroupOverwriteLoading: false,
    activeGroupSelectValue: '',
    classroomConfigError: '',
    closeActiveGroupOverwriteConfirm: closeOverwriteConfirm,
    confirmActiveGroupOverwrite: confirmOverwrite,
    defaultGroupSelectValue: 'group-default',
    handleDefaultGroupChange: vi.fn(),
    requestActiveGroupChange: vi.fn(),
    resolveGroupName: (groupId: string | null) =>
      groupId === 'group-next' ? 'Grupo Next' : 'Grupo Default',
    selectedClassroomSource: 'default',
  });

  hookOverrides.useClassroomSchedules = (...args: unknown[]) => {
    const [params] = args as [{ onSchedulesUpdated?: () => Promise<void> }];
    void params.onSchedulesUpdated?.();

    return {
      schedules: [],
      oneOffSchedules: [],
      loadingSchedules: false,
      scheduleFormOpen: options?.scheduleFormOpen ?? false,
      editingSchedule: null,
      scheduleFormDay: 1,
      scheduleFormStartTime: '09:00',
      oneOffFormOpen: options?.oneOffFormOpen ?? false,
      editingOneOffSchedule: null,
      scheduleSaving: false,
      scheduleError: '',
      scheduleDeleteTarget:
        (options?.scheduleDeleteOpen ?? false) ? { label: 'Monday 09:00-10:00' } : null,
      openScheduleCreate: vi.fn(),
      openScheduleEdit: vi.fn(),
      closeScheduleForm,
      openOneOffScheduleCreate: vi.fn(),
      openOneOffScheduleEdit: vi.fn(),
      closeOneOffScheduleForm: closeOneOffForm,
      handleScheduleSave: vi.fn(),
      handleOneOffScheduleSave: vi.fn(),
      requestScheduleDelete: vi.fn(),
      requestOneOffScheduleDelete: vi.fn(),
      closeScheduleDelete,
      handleConfirmDeleteSchedule: confirmScheduleDelete,
    };
  };

  hookOverrides.useClassroomMachines = () => ({
    activeSchedule: null,
    exemptionByMachineId: new Map(),
    exemptionMutating: {},
    exemptionsError: null,
    handleCreateExemption: vi.fn(),
    handleDeleteExemption: vi.fn(),
    loadingExemptions: false,
    sortedOneOffSchedules: [],
    enrollModal: {
      isOpen: true,
      enrollToken: 'classroom-enroll-token',
      loadingToken: false,
      enrollPlatform: options?.enrollPlatform ?? 'linux',
      enrollCommand:
        options?.enrollPlatform === 'windows'
          ? 'powershell -File install-agent.ps1'
          : 'curl -fsSL https://example.com/install.sh | bash',
      close: closeEnrollModal,
      open: vi.fn(),
      selectPlatform,
      copy: copyEnrollCommand,
      isCopied: options?.enrollCopied ?? false,
    },
  });

  return {
    retryLoad,
    refetchClassrooms,
    setSelectedClassroomId,
    setNewModalName,
    setNewModalGroup,
    createNewModal,
    closeNewModal,
    closeDeleteDialog,
    confirmDeleteDialog,
    closeOverwriteConfirm,
    confirmOverwrite,
    closeScheduleForm,
    closeOneOffForm,
    closeScheduleDelete,
    confirmScheduleDelete,
    closeEnrollModal,
    selectPlatform,
    copyEnrollCommand,
  };
}

describe('Classrooms', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockClassroomsUpdateMutate.mockResolvedValue(undefined);

    mockGroupsListQuery.mockResolvedValue([
      { id: 'group-default', name: 'default', displayName: 'Grupo Default' },
      { id: 'group-calendar', name: 'calendar', displayName: 'Grupo Horario' },
    ]);

    mockSchedulesByClassroomQuery.mockResolvedValue({ schedules: [], oneOffSchedules: [] });
    mockExemptionsListQuery.mockResolvedValue({ exemptions: [] });
  });

  it('shows current group as default when it matches default group', async () => {
    mockClassroomsListQuery.mockResolvedValue([
      {
        id: 'classroom-1',
        name: 'Aula 1',
        displayName: 'Aula 1',
        defaultGroupId: 'group-default',
        activeGroupId: null,
        currentGroupId: 'group-default',
        status: 'operational',
        machineCount: 0,
        onlineMachineCount: 0,
      },
    ]);

    renderClassrooms();

    await waitFor(() => {
      expect(screen.getByText(/default/i, { selector: 'p' })).toBeInTheDocument();
    });
  });

  it('shows current group as calendar-assigned when it differs from default group', async () => {
    mockClassroomsListQuery.mockResolvedValue([
      {
        id: 'classroom-1',
        name: 'Aula 1',
        displayName: 'Aula 1',
        defaultGroupId: 'group-default',
        activeGroupId: null,
        currentGroupId: 'group-calendar',
        status: 'operational',
        machineCount: 0,
        onlineMachineCount: 0,
      },
    ]);

    renderClassrooms();

    await waitFor(() => {
      expect(screen.getByText(/by schedule/i)).toBeInTheDocument();
    });
  });

  it('shows readable current group name from API metadata when the teacher cannot load that group locally', async () => {
    mockGroupsListQuery.mockResolvedValue([]);
    mockClassroomsListQuery.mockResolvedValue([
      {
        id: 'classroom-1',
        name: 'Aula 1',
        displayName: 'Aula 1',
        defaultGroupId: null,
        defaultGroupDisplayName: null,
        activeGroupId: null,
        currentGroupId: 'group-hidden-schedule',
        currentGroupDisplayName: 'Plan Teacher B',
        currentGroupSource: 'schedule',
        status: 'operational',
        machineCount: 0,
        onlineMachineCount: 0,
      },
    ]);

    renderClassrooms();

    await waitFor(() => {
      expect(screen.getByText(/Plan Teacher B/i)).toBeInTheDocument();
    });
  });

  it('updates default group when user changes "Default group" selector', async () => {
    mockClassroomsListQuery.mockResolvedValue([
      {
        id: 'classroom-1',
        name: 'Aula 1',
        displayName: 'Aula 1',
        defaultGroupId: 'group-default',
        activeGroupId: null,
        currentGroupId: 'group-default',
        status: 'operational',
        machineCount: 0,
        onlineMachineCount: 0,
      },
    ]);

    renderClassrooms();

    const defaultGroupSelect = await screen.findByLabelText(/default group/i);
    fireEvent.change(defaultGroupSelect, { target: { value: 'group-calendar' } });

    await waitFor(() => {
      expect(mockClassroomsUpdateMutate).toHaveBeenCalledWith({
        id: 'classroom-1',
        defaultGroupId: 'group-calendar',
      });
    });
  });

  it('shows actionable feedback when clearing default group fails with 4xx', async () => {
    mockClassroomsListQuery.mockResolvedValue([
      {
        id: 'classroom-1',
        name: 'Aula 1',
        displayName: 'Aula 1',
        defaultGroupId: 'group-default',
        activeGroupId: null,
        currentGroupId: 'group-default',
        status: 'operational',
        machineCount: 0,
        onlineMachineCount: 0,
      },
    ]);
    mockClassroomsUpdateMutate.mockRejectedValueOnce(
      new Error('BAD_REQUEST: default group required')
    );

    renderClassrooms();

    const defaultGroupSelect = await screen.findByLabelText(/default group/i);
    fireEvent.change(defaultGroupSelect, { target: { value: '' } });

    expect(
      await screen.findByText(
        'You cannot leave the classroom without a default group while no valid active group exists.'
      )
    ).toBeInTheDocument();
  });

  it('keeps classroom search usable with extra spaces and uppercase input', async () => {
    mockClassroomsListQuery.mockResolvedValue([
      {
        id: 'classroom-1',
        name: 'Laboratorio Norte',
        displayName: 'Laboratorio Norte',
        defaultGroupId: null,
        activeGroupId: null,
        currentGroupId: null,
        status: 'operational',
        machineCount: 0,
        onlineMachineCount: 0,
      },
    ]);

    renderClassrooms();

    expect((await screen.findAllByText('Laboratorio Norte')).length).toBeGreaterThan(0);

    fireEvent.change(screen.getByPlaceholderText('Search classroom...'), {
      target: { value: '   LABORATORIO   NORTE  ' },
    });

    await waitFor(() => {
      expect(screen.getAllByText('Laboratorio Norte').length).toBeGreaterThan(0);
      expect(screen.queryByText('No classrooms found')).not.toBeInTheDocument();
    });
  });

  it('clears detail panel when filters leave the list empty', async () => {
    mockClassroomsListQuery.mockResolvedValue([
      {
        id: 'classroom-1',
        name: 'Laboratorio Norte',
        displayName: 'Laboratorio Norte',
        defaultGroupId: null,
        activeGroupId: null,
        currentGroupId: null,
        status: 'operational',
        machineCount: 0,
        onlineMachineCount: 0,
      },
    ]);

    renderClassrooms();

    await screen.findByText('Classroom settings and status');

    fireEvent.change(screen.getByPlaceholderText('Search classroom...'), {
      target: { value: 'no-match-value' },
    });

    expect(screen.getByText('No classrooms found')).toBeInTheDocument();
    expect(screen.queryByText('Classroom settings and status')).not.toBeInTheDocument();
    expect(screen.getByText('No classrooms')).toBeInTheDocument();
  });

  it('forwards the requested initial classroom selection and clears it after mount', async () => {
    const controls = installHookOverrides();
    const defaultViewModel = hookOverrides.useClassroomsViewModel as (
      ...args: unknown[]
    ) => unknown;
    const viewModelSpy = vi.fn((...args: unknown[]) => defaultViewModel(...args));
    hookOverrides.useClassroomsViewModel = viewModelSpy;
    const onInitialSelectedClassroomIdConsumed = vi.fn();

    renderClassrooms({
      initialSelectedClassroomId: 'classroom-2',
      onInitialSelectedClassroomIdConsumed,
    });

    await screen.findByText('Classroom settings and status');

    expect(viewModelSpy).toHaveBeenCalledWith({
      initialSelectedClassroomId: 'classroom-2',
    });
    expect(onInitialSelectedClassroomIdConsumed).toHaveBeenCalledTimes(1);
    expect(controls.setSelectedClassroomId).not.toHaveBeenCalled();
  });

  it('keeps the classrooms split view constrained so the detail pane can stay visible', async () => {
    mockClassroomsListQuery.mockResolvedValue([
      {
        id: 'classroom-1',
        name: 'Laboratorio Norte',
        displayName: 'Laboratorio Norte',
        defaultGroupId: null,
        activeGroupId: null,
        currentGroupId: null,
        status: 'operational',
        machineCount: 0,
        onlineMachineCount: 0,
      },
    ]);

    const { container } = renderClassrooms();

    await screen.findByText('Classroom settings and status');

    const splitView = container.querySelector('[class*="flex-col"][class*="lg:flex-row"]');
    expect(splitView).not.toBeNull();

    const listPane = splitView?.children.item(0);
    const detailPane = splitView?.children.item(1);
    const splitViewTokens = (splitView?.className ?? '').split(/\s+/);

    expect(splitViewTokens).toContain('lg:h-full');
    expect(splitViewTokens).toContain('lg:min-h-0');
    expect(splitViewTokens).toContain('lg:overflow-hidden');
    expect(listPane?.className).toContain('shrink-0');
    expect(listPane?.className).toContain('lg:w-80');
    expect(detailPane?.className).toContain('min-w-0');
  });

  it('only constrains the classrooms split view height from lg upwards', async () => {
    mockClassroomsListQuery.mockResolvedValue([
      {
        id: 'classroom-1',
        name: 'Laboratorio Norte',
        displayName: 'Laboratorio Norte',
        defaultGroupId: null,
        activeGroupId: null,
        currentGroupId: null,
        status: 'operational',
        machineCount: 0,
        onlineMachineCount: 0,
      },
    ]);

    const { container } = renderClassrooms();

    await screen.findByText('Classroom settings and status');

    const splitView = container.querySelector('[class*="flex-col"][class*="lg:flex-row"]');
    expect(splitView).not.toBeNull();

    const splitViewTokens = (splitView?.className ?? '').split(/\s+/);
    const detailPane = splitView?.children.item(1);
    const detailPaneTokens = (detailPane?.className ?? '').split(/\s+/);

    expect(splitViewTokens).toContain('lg:h-full');
    expect(splitViewTokens).toContain('lg:min-h-0');
    expect(splitViewTokens).toContain('lg:overflow-hidden');
    expect(splitViewTokens).not.toContain('h-[calc(100vh-8rem)]');
    expect(detailPaneTokens).toContain('lg:min-h-0');
    expect(detailPaneTokens).toContain('lg:overflow-hidden');
    expect(detailPaneTokens).not.toContain('overflow-y-auto');
  });

  it('shows list loading and retry states when classrooms cannot be loaded yet', () => {
    const loadingControls = installHookOverrides({ isInitialLoading: true });

    renderClassrooms();
    expect(screen.getByText('Loading classrooms...')).toBeInTheDocument();

    const errorControls = installHookOverrides({ loadError: 'Unable to load classrooms' });

    renderClassrooms();
    fireEvent.click(screen.getByText('Retry'));

    expect(screen.getByText('Unable to load classrooms')).toBeInTheDocument();
    expect(errorControls.retryLoad).toHaveBeenCalledTimes(1);
    expect(loadingControls.retryLoad).not.toHaveBeenCalled();
  });

  it('renders the classrooms dialogs and modal flows wired by the parent view', async () => {
    const controls = installHookOverrides({
      newModalOpen: true,
      activeGroupOverwriteOpen: true,
      scheduleFormOpen: true,
      oneOffFormOpen: true,
      deleteDialogOpen: true,
      scheduleDeleteOpen: true,
      enrollPlatform: 'linux',
    });

    renderClassrooms();

    expect((await screen.findAllByText('Laboratorio Norte')).length).toBeGreaterThan(0);
    expect(screen.getByText('Name is required')).toBeInTheDocument();
    expect(screen.getByTestId('schedule-form-modal')).toBeInTheDocument();
    expect(screen.getByTestId('one-off-schedule-form-modal')).toBeInTheDocument();
    expect(screen.getByText('Replace active group')).toBeInTheDocument();
    expect(screen.getByText('Delete Classroom')).toBeInTheDocument();
    expect(screen.getByText('Delete Schedule')).toBeInTheDocument();
    expect(
      screen.getByText(/curl -fsSL https:\/\/example\.com\/install\.sh \| bash/i)
    ).toBeInTheDocument();
    expect(screen.getByText(/auto-update via APT/i)).toBeInTheDocument();

    fireEvent.change(screen.getByPlaceholderText('E.g. Lab C'), {
      target: { value: 'Laboratorio Creativo' },
    });
    const groupSelect = screen
      .getAllByRole('combobox')
      .find((element) => (element as HTMLSelectElement).options[0].textContent === 'No group');
    if (!groupSelect) {
      throw new Error('Expected the new classroom modal to render a group selector');
    }
    fireEvent.change(groupSelect, {
      target: { value: 'group-next' },
    });
    fireEvent.click(screen.getByText('Create Classroom'));
    fireEvent.click(screen.getByText('South Classroom'));
    fireEvent.click(screen.getByText('Replace'));
    fireEvent.click(screen.getByText('Save schedule'));
    fireEvent.click(screen.getByText('Close weekly schedule'));
    fireEvent.click(screen.getByText('Save one-off schedule'));
    fireEvent.click(screen.getByText('Close one-off schedule'));
    fireEvent.click(screen.getByText('Windows'));
    fireEvent.click(screen.getByLabelText('Copy to clipboard'));
    fireEvent.click(screen.getAllByText('Delete')[0]);
    fireEvent.click(screen.getAllByText('Delete')[1]);
    fireEvent.click(screen.getByText('Close'));
    fireEvent.click(screen.getAllByText('Cancel')[0]);

    expect(controls.setSelectedClassroomId).toHaveBeenCalledWith('classroom-2');
    expect(controls.setNewModalName).toHaveBeenCalledWith('Laboratorio Creativo');
    expect(controls.setNewModalGroup).toHaveBeenCalledWith('group-next');
    expect(controls.createNewModal).toHaveBeenCalledTimes(1);
    expect(controls.confirmOverwrite).toHaveBeenCalledTimes(1);
    expect(controls.closeScheduleForm).toHaveBeenCalledTimes(1);
    expect(controls.closeOneOffForm).toHaveBeenCalledTimes(1);
    expect(controls.selectPlatform).toHaveBeenCalledWith('windows');
    expect(controls.copyEnrollCommand).toHaveBeenCalledTimes(1);
    expect(controls.confirmDeleteDialog).toHaveBeenCalledTimes(1);
    expect(controls.confirmScheduleDelete).toHaveBeenCalledTimes(1);
    expect(controls.closeEnrollModal).toHaveBeenCalledTimes(1);
    expect(controls.closeNewModal).toHaveBeenCalledTimes(1);

    await waitFor(() => {
      expect(controls.refetchClassrooms).toHaveBeenCalled();
    });
  });

  it('renders the windows enrollment copy state when the install modal is open', async () => {
    installHookOverrides({
      enrollPlatform: 'windows',
      enrollCopied: true,
    });

    renderClassrooms();

    expect(await screen.findByText(/powershell -File install-agent\.ps1/i)).toBeInTheDocument();
    expect(screen.getByText(/Run PowerShell as Admin/i)).toBeInTheDocument();
    expect(screen.getByText('Copied')).toBeInTheDocument();
  });

  it('warns when a groupless classroom will register machines with unrestricted browsing', async () => {
    installHookOverrides({
      selectedClassroom: {
        defaultGroupId: null,
        defaultGroupDisplayName: null,
        currentGroupId: null,
        currentGroupDisplayName: null,
        currentGroupSource: 'none',
      },
    });

    renderClassrooms();

    expect(
      await screen.findByText(/unrestricted browsing until a group is assigned/i)
    ).toBeInTheDocument();
  });
});
