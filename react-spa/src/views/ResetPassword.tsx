import React, { useState } from 'react';
import {
  Shield,
  ArrowLeft,
  Key,
  Lock,
  Eye,
  EyeOff,
  CheckCircle,
  AlertCircle,
  Mail,
} from 'lucide-react';
import { trpc } from '../lib/trpc';
import { useT } from '../i18n/product-i18n';

interface ResetPasswordProps {
  onNavigateToLogin: () => void;
  onNavigateToForgot: () => void;
}

const ResetPassword: React.FC<ResetPasswordProps> = ({ onNavigateToLogin, onNavigateToForgot }) => {
  const t = useT();
  const [email, setEmail] = useState('');
  const [token, setToken] = useState('');
  const [password, setPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [showConfirm, setShowConfirm] = useState(false);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState('');
  const [success, setSuccess] = useState(false);

  const passwordRequirements = [
    { label: t('resetPassword.req.minChars'), met: password.length >= 8 },
    { label: t('resetPassword.req.uppercase'), met: /[A-Z]/.test(password) },
    { label: t('resetPassword.req.lowercase'), met: /[a-z]/.test(password) },
    { label: t('resetPassword.req.number'), met: /\d/.test(password) },
  ];

  const allRequirementsMet = passwordRequirements.every((r) => r.met);
  const passwordsMatch = password === confirmPassword && confirmPassword.length > 0;
  const canSubmit =
    email.length > 0 && token.length > 0 && allRequirementsMet && passwordsMatch && !isLoading;

  const handleSubmit = async (e: React.SyntheticEvent<HTMLFormElement>) => {
    e.preventDefault();
    if (!canSubmit) return;

    setIsLoading(true);
    setError('');

    try {
      await trpc.auth.resetPassword.mutate({ email, token, newPassword: password });
      setSuccess(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : t('resetPassword.error.resetFailed'));
    } finally {
      setIsLoading(false);
    }
  };

  if (success) {
    return (
      <div className="min-h-screen bg-gradient-to-br from-slate-900 via-slate-800 to-slate-900 flex items-center justify-center p-4">
        <div className="w-full max-w-md">
          <div className="bg-white rounded-2xl shadow-xl p-8 text-center">
            <div className="inline-flex items-center justify-center w-16 h-16 bg-green-100 rounded-full mb-4">
              <CheckCircle className="text-green-600" size={32} />
            </div>
            <h2 className="text-xl font-bold text-slate-800 mb-2">
              {t('resetPassword.success.title')}
            </h2>
            <p className="text-slate-600 mb-6">{t('resetPassword.success.body')}</p>
            <button
              onClick={onNavigateToLogin}
              className="w-full bg-blue-600 hover:bg-blue-700 text-white font-semibold py-3 px-4 rounded-lg transition-colors"
            >
              {t('auth.common.signIn')}
            </button>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gradient-to-br from-slate-900 via-slate-800 to-slate-900 flex items-center justify-center p-4">
      <div className="w-full max-w-md">
        {/* Logo */}
        <div className="text-center mb-8">
          <div className="inline-flex items-center justify-center w-16 h-16 bg-blue-600 rounded-2xl mb-4 shadow-lg shadow-blue-900/30">
            <Shield className="text-white" size={32} />
          </div>
          <h1 className="text-2xl font-bold text-white">OpenPath</h1>
          <p className="text-slate-400 mt-1">{t('resetPassword.subtitle')}</p>
        </div>

        {/* Card */}
        <div className="bg-white rounded-2xl shadow-xl p-8">
          <button
            onClick={onNavigateToForgot}
            className="flex items-center gap-2 text-slate-500 hover:text-slate-700 mb-6 text-sm font-medium transition-colors"
          >
            <ArrowLeft size={16} />
            {t('common.back')}
          </button>

          <form
            onSubmit={(e) => {
              void handleSubmit(e);
            }}
            className="space-y-5"
          >
            {/* Email */}
            <div>
              <label className="block text-sm font-medium text-slate-700 mb-2">
                {t('auth.common.email')}
              </label>
              <div className="relative">
                <Mail
                  className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400"
                  size={18}
                />
                <input
                  type="email"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  placeholder="you@example.com"
                  className="w-full pl-10 pr-4 py-3 border border-slate-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none transition-all text-sm"
                />
              </div>
            </div>

            {/* Token */}
            <div>
              <label className="block text-sm font-medium text-slate-700 mb-2">
                {t('resetPassword.tokenLabel')}
              </label>
              <div className="relative">
                <Key
                  className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400"
                  size={18}
                />
                <input
                  type="text"
                  value={token}
                  onChange={(e) => setToken(e.target.value)}
                  placeholder={t('resetPassword.tokenPlaceholder')}
                  className="w-full pl-10 pr-4 py-3 border border-slate-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none transition-all text-sm"
                />
              </div>
            </div>

            {/* New Password */}
            <div>
              <label className="block text-sm font-medium text-slate-700 mb-2">
                {t('resetPassword.newPasswordLabel')}
              </label>
              <div className="relative">
                <Lock
                  className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400"
                  size={18}
                />
                <input
                  type={showPassword ? 'text' : 'password'}
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="••••••••"
                  className="w-full pl-10 pr-12 py-3 border border-slate-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none transition-all text-sm"
                />
                <button
                  type="button"
                  onClick={() => setShowPassword(!showPassword)}
                  className="absolute right-3 top-1/2 -translate-y-1/2 text-slate-400 hover:text-slate-600"
                >
                  {showPassword ? <EyeOff size={18} /> : <Eye size={18} />}
                </button>
              </div>

              {/* Password requirements */}
              <div className="mt-2 grid grid-cols-2 gap-1">
                {passwordRequirements.map((req, i) => (
                  <div
                    key={i}
                    className={`flex items-center gap-1 text-xs ${
                      req.met ? 'text-green-600' : 'text-slate-400'
                    }`}
                  >
                    <CheckCircle size={12} />
                    {req.label}
                  </div>
                ))}
              </div>
            </div>

            {/* Confirm Password */}
            <div>
              <label className="block text-sm font-medium text-slate-700 mb-2">
                {t('resetPassword.confirmPasswordLabel')}
              </label>
              <div className="relative">
                <Lock
                  className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400"
                  size={18}
                />
                <input
                  type={showConfirm ? 'text' : 'password'}
                  value={confirmPassword}
                  onChange={(e) => setConfirmPassword(e.target.value)}
                  placeholder="••••••••"
                  className={`w-full pl-10 pr-12 py-3 border rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none transition-all text-sm ${
                    confirmPassword && !passwordsMatch
                      ? 'border-red-300 bg-red-50'
                      : passwordsMatch
                        ? 'border-green-300 bg-green-50'
                        : 'border-slate-300'
                  }`}
                />
                <button
                  type="button"
                  onClick={() => setShowConfirm(!showConfirm)}
                  className="absolute right-3 top-1/2 -translate-y-1/2 text-slate-400 hover:text-slate-600"
                >
                  {showConfirm ? <EyeOff size={18} /> : <Eye size={18} />}
                </button>
              </div>
              {confirmPassword && !passwordsMatch && (
                <p className="text-red-500 text-xs mt-1">{t('auth.validation.passwordMismatch')}</p>
              )}
            </div>

            {/* Error */}
            {error && (
              <div className="flex items-start gap-2 p-3 bg-red-50 border border-red-200 rounded-lg">
                <AlertCircle className="text-red-500 flex-shrink-0 mt-0.5" size={16} />
                <p className="text-red-700 text-sm">{error}</p>
              </div>
            )}

            {/* Submit */}
            <button
              type="submit"
              disabled={!canSubmit}
              className={`w-full font-semibold py-3 px-4 rounded-lg transition-colors ${
                canSubmit
                  ? 'bg-blue-600 hover:bg-blue-700 text-white'
                  : 'bg-slate-200 text-slate-400 cursor-not-allowed'
              }`}
            >
              {isLoading ? t('common.processing') : t('resetPassword.submitLabel')}
            </button>
          </form>
        </div>
      </div>
    </div>
  );
};

export default ResetPassword;
