import React, { useRef, useState } from 'react';
import { Settings as SettingsIcon, Bell, Shield, Info, AlertCircle, Loader2 } from 'lucide-react';
import { trpc } from '../lib/trpc';
import { reportError } from '../lib/reportError';
import { usePersistentNotificationPrefs } from '../hooks/usePersistentNotificationPrefs';
import { Modal } from '../components/ui/Modal';

const Settings: React.FC = () => {
  const [showPasswordModal, setShowPasswordModal] = useState(false);
  const [currentPassword, setCurrentPassword] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [passwordError, setPasswordError] = useState('');
  const [passwordSuccess, setPasswordSuccess] = useState(false);
  const [isChangingPassword, setIsChangingPassword] = useState(false);
  const passwordResetTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const { prefs, setPrefs } = usePersistentNotificationPrefs();

  const clearPasswordResetTimer = () => {
    if (!passwordResetTimerRef.current) return;
    clearTimeout(passwordResetTimerRef.current);
    passwordResetTimerRef.current = null;
  };

  const closePasswordModal = () => {
    clearPasswordResetTimer();
    setShowPasswordModal(false);
  };

  const openPasswordModal = () => {
    clearPasswordResetTimer();
    setCurrentPassword('');
    setNewPassword('');
    setConfirmPassword('');
    setPasswordError('');
    setPasswordSuccess(false);
    setShowPasswordModal(true);
  };

  const handleChangePassword = async () => {
    clearPasswordResetTimer();
    setPasswordError('');

    if (!currentPassword || !newPassword || !confirmPassword) {
      setPasswordError('All fields are required');
      return;
    }

    if (newPassword.length < 8) {
      setPasswordError('New password must be at least 8 characters');
      return;
    }

    if (newPassword !== confirmPassword) {
      setPasswordError('Passwords do not match');
      return;
    }

    try {
      setIsChangingPassword(true);
      await (
        trpc as unknown as {
          auth: {
            changePassword: {
              mutate: (input: { currentPassword: string; newPassword: string }) => Promise<unknown>;
            };
          };
        }
      ).auth.changePassword.mutate({
        currentPassword,
        newPassword,
      });

      setPasswordSuccess(true);
      passwordResetTimerRef.current = setTimeout(() => {
        setShowPasswordModal(false);
        setCurrentPassword('');
        setNewPassword('');
        setConfirmPassword('');
        setPasswordSuccess(false);
        passwordResetTimerRef.current = null;
      }, 1500);
    } catch (err) {
      reportError('Failed to change password:', err);
      setPasswordError('Unable to change password. Check your current password.');
    } finally {
      setIsChangingPassword(false);
    }
  };

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-3">
        <div className="p-2 bg-slate-100 rounded-lg">
          <SettingsIcon className="text-slate-600" size={24} />
        </div>
        <div>
          <h1 className="text-xl font-bold text-slate-800">Settings</h1>
          <p className="text-sm text-slate-500">Administra tus preferencias esenciales</p>
        </div>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        <div className="bg-white rounded-xl border border-slate-200 p-6 shadow-sm">
          <div className="flex items-center gap-3 mb-4">
            <div className="p-2 bg-blue-50 rounded-lg">
              <Bell className="text-blue-600" size={20} />
            </div>
            <h2 className="font-semibold text-slate-800">Notificaciones</h2>
          </div>
          <div className="space-y-4">
            <label className="flex items-center justify-between cursor-pointer">
              <span className="text-sm text-slate-600">Security alerts</span>
              <input
                type="checkbox"
                checked={prefs.securityAlerts}
                onChange={(e) =>
                  setPrefs((previous) => ({ ...previous, securityAlerts: e.target.checked }))
                }
                className="w-4 h-4 text-blue-600 rounded"
              />
            </label>
            <label className="flex items-center justify-between cursor-pointer">
              <span className="text-sm text-slate-600">New domain requests</span>
              <input
                type="checkbox"
                checked={prefs.domainRequests}
                onChange={(e) =>
                  setPrefs((previous) => ({ ...previous, domainRequests: e.target.checked }))
                }
                className="w-4 h-4 text-blue-600 rounded"
              />
            </label>
            <label className="flex items-center justify-between cursor-pointer">
              <span className="text-sm text-slate-600">Weekly reports</span>
              <input
                type="checkbox"
                checked={prefs.weeklyReports}
                onChange={(e) =>
                  setPrefs((previous) => ({ ...previous, weeklyReports: e.target.checked }))
                }
                className="w-4 h-4 text-blue-600 rounded"
              />
            </label>
          </div>
        </div>

        <div className="bg-white rounded-xl border border-slate-200 p-6 shadow-sm">
          <div className="flex items-center gap-3 mb-4">
            <div className="p-2 bg-green-50 rounded-lg">
              <Shield className="text-green-600" size={20} />
            </div>
            <h2 className="font-semibold text-slate-800">Seguridad</h2>
          </div>
          <div className="space-y-4">
            <div className="flex items-center justify-between">
              <span className="text-sm text-slate-600">Two-factor authentication</span>
              <span className="text-xs bg-amber-100 text-amber-700 px-2 py-1 rounded font-medium">
                Coming soon
              </span>
            </div>
            <div className="flex items-start justify-between gap-4">
              <span className="text-sm text-slate-600">Session protection</span>
              <span className="text-sm text-slate-800 font-medium text-right">
                Administrada por el servidor
              </span>
            </div>
            <button
              onClick={openPasswordModal}
              className="w-full mt-2 text-sm text-blue-600 hover:text-blue-800 font-medium py-2 border border-blue-200 rounded-lg hover:bg-blue-50 transition-colors"
            >
              Change password
            </button>
          </div>
        </div>
      </div>

      <div className="flex items-center gap-2 text-sm text-slate-400 pt-4">
        <Info size={16} />
        <span>Changes on this page are saved automatically in your browser.</span>
      </div>

      {showPasswordModal && (
        <Modal isOpen onClose={closePasswordModal} title="Change Password" className="max-w-md">
          {passwordSuccess ? (
            <div className="text-center py-8">
              <div className="w-16 h-16 bg-green-100 rounded-full flex items-center justify-center mx-auto mb-4">
                <Shield className="text-green-600" size={32} />
              </div>
              <p className="text-green-700 font-medium">Password updated successfully!</p>
            </div>
          ) : (
            <div className="space-y-4">
              <div>
                <label className="block text-sm font-medium text-slate-700 mb-1">
                  Current password
                </label>
                <input
                  type="password"
                  value={currentPassword}
                  onChange={(e) => setCurrentPassword(e.target.value)}
                  placeholder="Enter your current password"
                  className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 outline-none"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-slate-700 mb-1">
                  New password
                </label>
                <input
                  type="password"
                  value={newPassword}
                  onChange={(e) => setNewPassword(e.target.value)}
                  placeholder="Minimum 8 characters"
                  className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 outline-none"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-slate-700 mb-1">
                  Confirm new password
                </label>
                <input
                  type="password"
                  value={confirmPassword}
                  onChange={(e) => setConfirmPassword(e.target.value)}
                  placeholder="Repeat the new password"
                  className={`w-full border rounded-lg px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 outline-none ${passwordError ? 'border-red-300' : 'border-slate-300'}`}
                />
              </div>

              {passwordError && (
                <p className="text-red-500 text-xs flex items-center gap-1">
                  <AlertCircle size={12} /> {passwordError}
                </p>
              )}

              <div className="flex gap-3 pt-2">
                <button
                  onClick={closePasswordModal}
                  className="flex-1 px-4 py-2 border border-slate-300 rounded-lg text-slate-700 hover:bg-slate-50"
                >
                  Cancel
                </button>
                <button
                  onClick={() => void handleChangePassword()}
                  disabled={isChangingPassword}
                  className="flex-1 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 font-medium disabled:opacity-60 disabled:cursor-not-allowed"
                >
                  {isChangingPassword ? (
                    <span className="inline-flex items-center gap-2">
                      <Loader2 size={16} className="animate-spin" /> Guardando...
                    </span>
                  ) : (
                    'Change Password'
                  )}
                </button>
              </div>
            </div>
          )}
        </Modal>
      )}
    </div>
  );
};

export default Settings;
