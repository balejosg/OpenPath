import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { screen, fireEvent, waitFor, within } from '@testing-library/react';
import UsersView from '../Users';
import { renderWithQueryClient } from '../../test-utils/query';

let queryClient: ReturnType<typeof renderWithQueryClient>['queryClient'] | null = null;

function renderUsersView() {
  const rendered = renderWithQueryClient(<UsersView />);
  queryClient = rendered.queryClient;
  return rendered;
}

afterEach(() => {
  queryClient?.clear();
  queryClient = null;
});

const { mockUsersList, mockCreateUser, mockDeleteUser, mockGenerateResetToken } = vi.hoisted(
  () => ({
    mockUsersList: vi.fn(),
    mockCreateUser: vi.fn(),
    mockDeleteUser: vi.fn(),
    mockGenerateResetToken: vi.fn(),
  })
);

const { mockDownloadFile } = vi.hoisted(() => ({
  mockDownloadFile: vi.fn<(content: string, filename: string, mimeType: string) => void>(),
}));

vi.mock('../../lib/trpc', () => ({
  trpc: {
    auth: {
      generateResetToken: {
        mutate: mockGenerateResetToken,
      },
    },
    users: {
      list: {
        query: mockUsersList,
      },
      create: {
        mutate: mockCreateUser,
      },
      update: {
        mutate: vi.fn(),
      },
      delete: {
        mutate: mockDeleteUser,
      },
    },
  },
}));

vi.mock('../../lib/download', () => ({
  downloadFile: mockDownloadFile,
}));

function createDeferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

describe('Users View', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockUsersList.mockResolvedValue([]);
    mockCreateUser.mockResolvedValue({
      id: 'user-created',
      name: 'User Creado',
      email: 'creado@example.com',
      isActive: true,
      roles: [],
    });
    mockDeleteUser.mockResolvedValue({});
    mockGenerateResetToken.mockResolvedValue({ token: 'RESET-123' });
  });

  it('shows role selector with default teacher', async () => {
    renderUsersView();

    fireEvent.click(screen.getByRole('button', { name: '+ New User' }));

    const roleSelect = await screen.findByRole('combobox');
    expect((roleSelect as HTMLSelectElement).value).toBe('teacher');
  });

  it('sends selected role in create mutation', async () => {
    renderUsersView();

    fireEvent.click(screen.getByRole('button', { name: '+ New User' }));

    fireEvent.change(await screen.findByPlaceholderText('Full name'), {
      target: { value: 'Teacher User' },
    });
    fireEvent.change(screen.getByPlaceholderText('user@example.com'), {
      target: { value: 'teacher@example.com' },
    });
    fireEvent.change(screen.getByPlaceholderText('Minimum 8 characters'), {
      target: { value: 'SecurePass123!' },
    });
    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'teacher' } });

    fireEvent.click(screen.getByRole('button', { name: 'Create User' }));

    await waitFor(() => {
      expect(mockCreateUser).toHaveBeenCalledWith({
        name: 'Teacher User',
        email: 'teacher@example.com',
        password: 'SecurePass123!',
        role: 'teacher',
      });
    });
  });

  it('uses default teacher role when unchanged', async () => {
    renderUsersView();

    fireEvent.click(screen.getByRole('button', { name: '+ New User' }));

    fireEvent.change(await screen.findByPlaceholderText('Full name'), {
      target: { value: 'Teacher User' },
    });
    fireEvent.change(screen.getByPlaceholderText('user@example.com'), {
      target: { value: 'teacher@example.com' },
    });
    fireEvent.change(screen.getByPlaceholderText('Minimum 8 characters'), {
      target: { value: 'SecurePass123!' },
    });

    fireEvent.click(screen.getByRole('button', { name: 'Create User' }));

    await waitFor(() => {
      expect(mockCreateUser).toHaveBeenCalledWith({
        name: 'Teacher User',
        email: 'teacher@example.com',
        password: 'SecurePass123!',
        role: 'teacher',
      });
    });
  });

  it('shows valid empty pagination range and disables navigation on empty state', async () => {
    renderUsersView();

    expect(await screen.findByText('Showing 0-0 of 0 users')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Filters' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Previous' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Next' })).toBeDisabled();
  });

  it('paginates users ten at a time and updates the visible range', async () => {
    mockUsersList.mockResolvedValue(
      Array.from({ length: 12 }, (_, index) => ({
        id: `user-${index + 1}`,
        name: `User ${index + 1}`,
        email: `user${index + 1}@example.com`,
        isActive: true,
        roles: [{ role: 'teacher' }],
      }))
    );

    renderUsersView();

    expect(await screen.findByText('Showing 1-10 of 12 users')).toBeInTheDocument();
    expect(screen.getByText('User 1')).toBeInTheDocument();
    expect(screen.getByText('User 10')).toBeInTheDocument();
    expect(screen.queryByText('User 11')).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Previous' })).toBeDisabled();

    fireEvent.click(screen.getByRole('button', { name: 'Next' }));

    await waitFor(() => {
      expect(screen.getByText('Showing 11-12 of 12 users')).toBeInTheDocument();
    });
    expect(screen.queryByText('User 1')).not.toBeInTheDocument();
    expect(screen.getByText('User 11')).toBeInTheDocument();
    expect(screen.getByText('User 12')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Next' })).toBeDisabled();

    fireEvent.click(screen.getByRole('button', { name: 'Previous' }));

    await waitFor(() => {
      expect(screen.getByText('Showing 1-10 of 12 users')).toBeInTheDocument();
    });
    expect(screen.getByText('User 1')).toBeInTheDocument();
    expect(screen.queryByText('User 11')).not.toBeInTheDocument();
  });

  it('shows assigned roles as read-only information in the edit modal', async () => {
    mockUsersList.mockResolvedValue([
      {
        id: 'user-edit',
        name: 'Admin QA',
        email: 'admin@example.com',
        isActive: true,
        roles: [{ role: 'admin' }, { role: 'teacher' }],
      },
    ]);

    renderUsersView();

    await screen.findByText('Admin QA');

    fireEvent.click(screen.getByTitle('Edit'));

    const dialog = await screen.findByRole('dialog', { name: 'Edit User' });

    expect(within(dialog).getByText('Roles actuales')).toBeInTheDocument();
    expect(within(dialog).queryByRole('checkbox')).not.toBeInTheDocument();
    expect(within(dialog).getByText('Admin')).toBeInTheDocument();
    expect(within(dialog).getByText('Teacher')).toBeInTheDocument();
    expect(
      within(dialog).getByText(/Role management is handled in the permissions flow/i)
    ).toBeInTheDocument();
  });

  it('shows feedback when exporting with no users', async () => {
    renderUsersView();

    await screen.findByText('Showing 0-0 of 0 users');
    fireEvent.click(screen.getByRole('button', { name: 'Export' }));

    expect(screen.getByRole('status')).toHaveTextContent('No users to export');
  });

  it('exports users with localized role and status values', async () => {
    mockUsersList.mockResolvedValue([
      {
        id: 'user-1',
        name: 'Admin QA',
        email: 'admin@example.com',
        isActive: true,
        roles: [{ role: 'admin' }],
      },
      {
        id: 'user-2',
        name: 'Teacher QA',
        email: 'teacher@example.com',
        isActive: false,
        roles: [{ role: 'teacher' }],
      },
    ]);

    renderUsersView();

    await screen.findByText('Admin QA');
    await screen.findByText('Teacher QA');

    fireEvent.click(screen.getByRole('button', { name: 'Export' }));

    await waitFor(() => {
      expect(mockDownloadFile).toHaveBeenCalledTimes(1);
    });

    const [csvContent, filename, mimeType] = mockDownloadFile.mock.calls[0];

    expect(filename).toBe('users.csv');
    expect(mimeType).toBe('text/csv;charset=utf-8');
    expect(csvContent).toContain('Nombre,Email,Roles,Estado');
    expect(csvContent).toContain('Admin QA,admin@example.com,Admin,Active');
    expect(csvContent).toContain('Teacher QA,teacher@example.com,Teacher,Inactive');
  });

  it('shows specific message when email format is invalid', async () => {
    mockCreateUser.mockRejectedValueOnce({ data: { code: 'BAD_REQUEST' } });

    renderUsersView();

    fireEvent.click(screen.getByRole('button', { name: '+ New User' }));
    fireEvent.change(await screen.findByPlaceholderText('Full name'), {
      target: { value: 'User Test' },
    });
    fireEvent.change(screen.getByPlaceholderText('user@example.com'), {
      target: { value: 'a' },
    });
    fireEvent.change(screen.getByPlaceholderText('Minimum 8 characters'), {
      target: { value: 'SecurePass123!' },
    });

    fireEvent.click(screen.getByRole('button', { name: 'Create User' }));

    expect(await screen.findByText('Email is invalid')).toBeInTheDocument();
  });

  it('shows duplicate-email message when backend reports conflict', async () => {
    mockCreateUser.mockRejectedValueOnce({ data: { code: 'CONFLICT' } });

    renderUsersView();

    fireEvent.click(screen.getByRole('button', { name: '+ New User' }));
    fireEvent.change(await screen.findByPlaceholderText('Full name'), {
      target: { value: 'User Repetido' },
    });
    fireEvent.change(screen.getByPlaceholderText('user@example.com'), {
      target: { value: 'dup@example.com' },
    });
    fireEvent.change(screen.getByPlaceholderText('Minimum 8 characters'), {
      target: { value: 'SecurePass123!' },
    });

    fireEvent.click(screen.getByRole('button', { name: 'Create User' }));

    expect(await screen.findByText('A user with that email already exists')).toBeInTheDocument();
  });

  it('keeps existing rows visible while refreshing and ignores stale list responses after create', async () => {
    const firstList = createDeferred<unknown[]>();
    const secondList = createDeferred<unknown[]>();

    mockUsersList.mockImplementationOnce(() => firstList.promise);
    mockUsersList.mockImplementationOnce(() => secondList.promise);

    renderUsersView();

    fireEvent.click(screen.getByRole('button', { name: '+ New User' }));
    fireEvent.change(await screen.findByPlaceholderText('Full name'), {
      target: { value: 'User Creado' },
    });
    fireEvent.change(screen.getByPlaceholderText('user@example.com'), {
      target: { value: 'creado@example.com' },
    });
    fireEvent.change(screen.getByPlaceholderText('Minimum 8 characters'), {
      target: { value: 'SecurePass123!' },
    });

    fireEvent.click(screen.getByRole('button', { name: 'Create User' }));

    // Optimistic insert should render immediately and should NOT replace the grid
    // with the initial loading state.
    expect(await screen.findByText('User Creado')).toBeInTheDocument();
    await waitFor(() => {
      expect(screen.queryByText('Loading users...')).not.toBeInTheDocument();
    });

    await waitFor(() => {
      expect(mockUsersList).toHaveBeenCalledTimes(2);
    });

    // While the post-create refresh is in-flight, the grid should remain visible.
    expect(screen.getByLabelText('Updating users')).toBeInTheDocument();

    // Newer fetch returns the created user.
    secondList.resolve([
      {
        id: 'user-created',
        name: 'User Creado',
        email: 'creado@example.com',
        isActive: true,
        roles: [],
      },
    ]);

    await waitFor(() => {
      expect(screen.queryByLabelText('Updating users')).not.toBeInTheDocument();
    });

    // Older in-flight fetch resolves after: it should be ignored.
    firstList.resolve([]);

    // Allow any stale promise handlers to run.
    await new Promise((r) => setTimeout(r, 0));
    expect(screen.getByText('User Creado')).toBeInTheDocument();
  });

  it('refetches users list after create even when create response is unmappable and initial list is in-flight', async () => {
    const firstList = createDeferred<unknown[]>();
    const secondList = createDeferred<unknown[]>();

    mockUsersList.mockImplementationOnce(() => firstList.promise);
    mockUsersList.mockImplementationOnce(() => secondList.promise);

    // Simulate a backend shape regression where create returns "active" instead of "isActive".
    // The UI mapper will treat this as unmappable and must still refresh the list.
    mockCreateUser.mockResolvedValueOnce({
      id: 'user-created',
      name: 'User Creado',
      email: 'creado@example.com',
      active: true,
      roles: [],
    });

    renderUsersView();

    fireEvent.click(screen.getByRole('button', { name: '+ New User' }));
    fireEvent.change(await screen.findByPlaceholderText('Full name'), {
      target: { value: 'User Creado' },
    });
    fireEvent.change(screen.getByPlaceholderText('user@example.com'), {
      target: { value: 'creado@example.com' },
    });
    fireEvent.change(screen.getByPlaceholderText('Minimum 8 characters'), {
      target: { value: 'SecurePass123!' },
    });

    fireEvent.click(screen.getByRole('button', { name: 'Create User' }));

    await waitFor(() => {
      expect(mockCreateUser).toHaveBeenCalledTimes(1);
    });

    // The initial list request started before the user was created.
    // Once we create, the view MUST trigger a refetch that is not blocked by the in-flight request.
    await waitFor(() => {
      expect(mockUsersList).toHaveBeenCalledTimes(2);
    });

    // Resolve the old request (stale snapshot) after the create.
    firstList.resolve([]);

    // Resolve the post-create refetch with the newly created user.
    secondList.resolve([
      {
        id: 'user-created',
        name: 'User Creado',
        email: 'creado@example.com',
        isActive: true,
        roles: [],
      },
    ]);

    expect(await screen.findByText('User Creado')).toBeInTheDocument();
  });

  it('keeps grid data visible when post-create background refetch fails', async () => {
    const initialList = createDeferred<unknown[]>();
    mockUsersList.mockImplementationOnce(() => initialList.promise);

    // The create response must be mappable so the optimistic insert works.
    mockCreateUser.mockResolvedValueOnce({
      id: 'user-new',
      name: 'New User',
      email: 'new@example.com',
      isActive: true,
      roles: [{ role: 'teacher' }],
    });

    renderUsersView();

    // Resolve initial list with one existing user
    initialList.resolve([
      {
        id: 'user-existing',
        name: 'Existing User',
        email: 'existing@example.com',
        isActive: true,
        roles: [{ role: 'teacher' }],
      },
    ]);

    await screen.findByText('Existing User');

    // Post-create refetch will fail
    mockUsersList.mockImplementationOnce(
      () => new Promise((_, reject) => setTimeout(() => reject(new Error('network error')), 10))
    );

    fireEvent.click(screen.getByRole('button', { name: '+ New User' }));
    fireEvent.change(await screen.findByPlaceholderText('Full name'), {
      target: { value: 'New User' },
    });
    fireEvent.change(screen.getByPlaceholderText('user@example.com'), {
      target: { value: 'new@example.com' },
    });
    fireEvent.change(screen.getByPlaceholderText('Minimum 8 characters'), {
      target: { value: 'SecurePass123!' },
    });

    fireEvent.click(screen.getByRole('button', { name: 'Create User' }));

    await waitFor(() => {
      expect(mockCreateUser).toHaveBeenCalled();
    });

    // The optimistic insert should show the new user immediately
    expect(await screen.findByText('New User')).toBeInTheDocument();

    // The existing user must still be visible (grid must NOT go blank)
    expect(screen.getByText('Existing User')).toBeInTheDocument();

    // Wait for the failed refetch to settle
    await waitFor(() => {
      expect(mockUsersList).toHaveBeenCalledTimes(2);
    });

    // The view should surface the failure as a non-blocking inline warning.
    expect(await screen.findByText(/Unable to update/i)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Retry' })).toBeInTheDocument();

    // After the failed refetch, BOTH users must still be visible
    expect(screen.getByText('New User')).toBeInTheDocument();
    expect(screen.getByText('Existing User')).toBeInTheDocument();

    // The grid must NOT show the full-page error or loading state
    expect(screen.queryByText('Loading users...')).not.toBeInTheDocument();
    expect(screen.queryByText('Unable to load users')).not.toBeInTheDocument();
  });

  it('opens delete confirmation modal and deletes user on confirm', async () => {
    mockUsersList.mockResolvedValue([
      {
        id: 'user-1',
        name: 'Delete Me',
        email: 'delete@example.com',
        isActive: true,
        roles: [{ role: 'student' }],
      },
    ]);

    renderUsersView();

    await screen.findByText('Delete Me');
    fireEvent.click(screen.getByRole('button', { name: 'Delete user Delete Me' }));

    expect(await screen.findByText('Delete User')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Delete user' }));

    await waitFor(() => {
      expect(mockDeleteUser).toHaveBeenCalledWith({ id: 'user-1' });
    });
  });

  it('generates a reset token from the user actions table and shows it in a modal', async () => {
    mockUsersList.mockResolvedValue([
      {
        id: 'user-reset',
        name: 'Admin QA',
        email: 'admin@example.com',
        isActive: true,
        roles: [{ role: 'admin' }],
      },
    ]);

    renderUsersView();

    await screen.findByText('Admin QA');

    fireEvent.click(screen.getByRole('button', { name: 'Reset password for Admin QA' }));

    expect(await screen.findByText('Generate recovery token')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'Generar token' }));

    await waitFor(() => {
      expect(mockGenerateResetToken).toHaveBeenCalledWith({ email: 'admin@example.com' });
    });

    expect(await screen.findByDisplayValue('RESET-123')).toBeInTheDocument();
    expect(screen.getByText(/Share this token securely with the user/i)).toBeInTheDocument();
  });

  it('shows inline error when delete fails', async () => {
    mockUsersList.mockResolvedValue([
      {
        id: 'user-2',
        name: 'Cannot Delete',
        email: 'cant-delete@example.com',
        isActive: true,
        roles: [{ role: 'student' }],
      },
    ]);
    mockDeleteUser.mockRejectedValueOnce(new Error('backend failure'));

    renderUsersView();

    await screen.findByText('Cannot Delete');
    fireEvent.click(screen.getByRole('button', { name: 'Delete user Cannot Delete' }));
    fireEvent.click(await screen.findByRole('button', { name: 'Delete user' }));

    expect(await screen.findByText('Unable to delete user. Try again.')).toBeInTheDocument();
  });
});
