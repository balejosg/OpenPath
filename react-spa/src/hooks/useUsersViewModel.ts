import type { Dispatch, SetStateAction } from 'react';
import { useEffect, useMemo, useState } from 'react';
import type { User } from '../types';
import type { CreateUserRole } from '../lib/roles';
import { DEFAULT_CREATE_USER_ROLE } from '../lib/roles';
import { useUsersList } from './useUsersList';
import { useUsersActions } from './useUsersActions';
import { downloadFile } from '../lib/download';
import { buildUsersCsvExport } from '../lib/exportUsers';
import { useT } from '../i18n/product-i18n';

const PAGE_SIZE = 10;

type ResetFlowState =
  | { status: 'idle' }
  | { status: 'confirm'; user: User }
  | { status: 'success'; user: User; token: string };

export interface UseUsersViewModelReturn {
  hasData: boolean;
  loading: boolean;
  fetching: boolean;
  error: string | null;
  fetchUsers: () => Promise<void>;
  filteredUsers: User[];
  visibleUsers: User[];
  showInitialLoading: boolean;
  searchQuery: string;
  setSearchQuery: Dispatch<SetStateAction<string>>;
  exportMessage: string | null;
  handleExportUsers: () => void;
  setPageIndex: Dispatch<SetStateAction<number>>;
  rangeStart: number;
  rangeEnd: number;
  totalCount: number;
  hasPreviousPage: boolean;
  hasNextPage: boolean;
  showEditModal: boolean;
  selectedUser: User | null;
  editName: string;
  setEditName: Dispatch<SetStateAction<string>>;
  editEmail: string;
  setEditEmail: Dispatch<SetStateAction<string>>;
  openEditModal: (user: User) => void;
  closeEditModal: () => void;
  saveEdit: () => Promise<void>;
  showNewModal: boolean;
  newName: string;
  setNewName: Dispatch<SetStateAction<string>>;
  newEmail: string;
  setNewEmail: Dispatch<SetStateAction<string>>;
  newPassword: string;
  setNewPassword: Dispatch<SetStateAction<string>>;
  newRole: CreateUserRole;
  setNewRole: Dispatch<SetStateAction<CreateUserRole>>;
  openNewModal: () => void;
  closeNewModal: () => void;
  createUser: () => Promise<void>;
  resetNewUserForm: () => void;
  saving: boolean;
  deleting: boolean;
  createError: string;
  setCreateError: Dispatch<SetStateAction<string>>;
  deleteError: string;
  deleteTarget: { id: string; name: string } | null;
  requestDeleteUser: (target: { id: string; name: string }) => void;
  clearDeleteState: () => void;
  handleConfirmDeleteUser: () => Promise<boolean>;
  resetFlow: ResetFlowState;
  resetUser: User | null;
  generatedResetToken: string;
  resettingPassword: boolean;
  resetError: string;
  requestPasswordReset: (user: User) => void;
  closeResetFlow: () => void;
  confirmGenerateResetToken: () => Promise<void>;
}

export function useUsersViewModel(): UseUsersViewModelReturn {
  const t = useT();
  const { users, hasData, loading, fetching, error, fetchUsers } = useUsersList();
  const [showEditModal, setShowEditModal] = useState(false);
  const [showNewModal, setShowNewModal] = useState(false);
  const [selectedUser, setSelectedUser] = useState<User | null>(null);
  const [searchQuery, setSearchQuery] = useState('');
  const [pageIndex, setPageIndex] = useState(0);
  const [resetFlow, setResetFlow] = useState<ResetFlowState>({ status: 'idle' });
  const [editName, setEditName] = useState('');
  const [editEmail, setEditEmail] = useState('');
  const [newName, setNewName] = useState('');
  const [newEmail, setNewEmail] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [newRole, setNewRole] = useState<CreateUserRole>(DEFAULT_CREATE_USER_ROLE);
  const [exportMessage, setExportMessage] = useState<string | null>(null);

  const {
    saving,
    deleting,
    resettingPassword,
    createError,
    setCreateError,
    deleteError,
    deleteTarget,
    resetError,
    handleSaveEdit,
    handleCreateUser,
    requestDeleteUser,
    clearDeleteState,
    handleConfirmDeleteUser,
    clearResetError,
    handleGenerateResetToken,
  } = useUsersActions();

  const filteredUsers = useMemo(() => {
    if (!searchQuery.trim()) {
      return users;
    }

    const query = searchQuery.toLowerCase();
    return users.filter(
      (user) => user.name.toLowerCase().includes(query) || user.email.toLowerCase().includes(query)
    );
  }, [users, searchQuery]);

  useEffect(() => {
    setPageIndex(0);
  }, [searchQuery]);

  useEffect(() => {
    const maxPageIndex = Math.max(0, Math.ceil(filteredUsers.length / PAGE_SIZE) - 1);
    setPageIndex((current) => Math.min(current, maxPageIndex));
  }, [filteredUsers.length]);

  const visibleUsers = useMemo(() => {
    const start = pageIndex * PAGE_SIZE;
    return filteredUsers.slice(start, start + PAGE_SIZE);
  }, [filteredUsers, pageIndex]);

  const visibleCount = visibleUsers.length;
  const totalCount = filteredUsers.length;
  const rangeStart = visibleCount === 0 ? 0 : pageIndex * PAGE_SIZE + 1;
  const rangeEnd = visibleCount === 0 ? 0 : pageIndex * PAGE_SIZE + visibleCount;
  const hasPreviousPage = pageIndex > 0;
  const hasNextPage = rangeEnd < totalCount;
  const showInitialLoading = loading && !hasData;
  const resetUser = resetFlow.status === 'idle' ? null : resetFlow.user;
  const generatedResetToken = resetFlow.status === 'success' ? resetFlow.token : '';

  const openEditModal = (user: User) => {
    setSelectedUser(user);
    setEditName(user.name);
    setEditEmail(user.email);
    setShowEditModal(true);
  };

  const saveEdit = async () => {
    if (!selectedUser) {
      return;
    }

    const ok = await handleSaveEdit({
      id: selectedUser.id,
      name: editName,
      email: editEmail,
    });

    if (ok) {
      setShowEditModal(false);
    }
  };

  const closeEditModal = () => {
    if (saving) {
      return;
    }

    setShowEditModal(false);
  };

  const resetNewUserForm = () => {
    setNewName('');
    setNewEmail('');
    setNewPassword('');
    setNewRole(DEFAULT_CREATE_USER_ROLE);
    setCreateError('');
  };

  const openNewModal = () => {
    resetNewUserForm();
    setShowNewModal(true);
  };

  const closeNewModal = () => {
    if (saving) {
      return;
    }

    setShowNewModal(false);
  };

  const createUser = async () => {
    const result = await handleCreateUser({
      name: newName,
      email: newEmail,
      password: newPassword,
      role: newRole,
    });

    if (!result.ok) {
      return;
    }

    resetNewUserForm();
    setShowNewModal(false);
  };

  const handleExportUsers = () => {
    if (filteredUsers.length === 0) {
      setExportMessage('No users to export');
      return;
    }

    const exportData = buildUsersCsvExport(filteredUsers, {}, t);
    downloadFile(exportData.content, exportData.filename, exportData.mimeType);
    setExportMessage('Export started');
  };

  const requestPasswordReset = (user: User) => {
    clearResetError();
    setResetFlow({ status: 'confirm', user });
  };

  const closeResetFlow = () => {
    if (resettingPassword) {
      return;
    }

    clearResetError();
    setResetFlow({ status: 'idle' });
  };

  const confirmGenerateResetToken = async () => {
    if (resetFlow.status !== 'confirm') {
      return;
    }

    const result = await handleGenerateResetToken({ email: resetFlow.user.email });
    if (!result.ok) {
      return;
    }

    setResetFlow({
      status: 'success',
      user: resetFlow.user,
      token: result.token,
    });
  };

  return {
    hasData,
    loading,
    fetching,
    error,
    fetchUsers,
    filteredUsers,
    visibleUsers,
    showInitialLoading,
    searchQuery,
    setSearchQuery,
    exportMessage,
    handleExportUsers,
    setPageIndex,
    rangeStart,
    rangeEnd,
    totalCount,
    hasPreviousPage,
    hasNextPage,
    showEditModal,
    selectedUser,
    editName,
    setEditName,
    editEmail,
    setEditEmail,
    openEditModal,
    closeEditModal,
    saveEdit,
    showNewModal,
    newName,
    setNewName,
    newEmail,
    setNewEmail,
    newPassword,
    setNewPassword,
    newRole,
    setNewRole,
    openNewModal,
    closeNewModal,
    createUser,
    resetNewUserForm,
    saving,
    deleting,
    createError,
    setCreateError,
    deleteError,
    deleteTarget,
    requestDeleteUser,
    clearDeleteState,
    handleConfirmDeleteUser,
    resetFlow,
    resetUser,
    generatedResetToken,
    resettingPassword,
    resetError,
    requestPasswordReset,
    closeResetFlow,
    confirmGenerateResetToken,
  };
}
