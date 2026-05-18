import React, { useState, useMemo } from 'react';
import { Mail, Lock, User, ArrowRight, Loader2, Shield, Briefcase } from 'lucide-react';
import { trpc } from '../lib/trpc';
import { reportError } from '../lib/reportError';
import { useT } from '../i18n/product-i18n';

interface RegisterProps {
  onRegister: () => void;
  onNavigateToLogin: () => void;
}

const Register: React.FC<RegisterProps> = ({ onRegister, onNavigateToLogin }) => {
  const t = useT();
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState('');
  const [success, setSuccess] = useState(false);

  // Form state
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [role, setRole] = useState('it_director');
  const [password, setPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');

  // Validation
  const passwordsMatch = password === confirmPassword;
  const passwordLongEnough = password.length >= 8;
  const isFormValid = useMemo(() => {
    return (
      name.trim().length > 0 &&
      email.trim().length > 0 &&
      password.length >= 8 &&
      confirmPassword.length > 0 &&
      passwordsMatch
    );
  }, [name, email, password, confirmPassword, passwordsMatch]);

  // Show password mismatch error only after user has typed in confirm field
  const showPasswordMismatch = confirmPassword.length > 0 && !passwordsMatch;

  const handleSubmit = async (e: React.SyntheticEvent<HTMLFormElement>) => {
    e.preventDefault();

    if (!isFormValid) {
      if (!passwordsMatch) {
        setError(t('auth.validation.passwordMismatch'));
      } else if (!passwordLongEnough) {
        setError(t('auth.validation.passwordMin'));
      }
      return;
    }

    setIsLoading(true);
    setError('');

    try {
      await trpc.auth.register.mutate({
        name: name.trim(),
        email: email.trim().toLowerCase(),
        password,
      });

      setSuccess(true);
      // Navigate to dashboard after short delay
      setTimeout(() => {
        onRegister();
      }, 1000);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : t('auth.register.createError');
      setError(message);
      reportError('Failed to register user:', err);
      setIsLoading(false);
    }
  };

  return (
    <div className="min-h-screen flex bg-white">
      {/* Branding Side - Right for Register */}
      <div className="hidden lg:flex lg:w-1/2 bg-slate-900 flex-col justify-center px-12 xl:px-24 relative overflow-hidden order-2">
        {/* Subtle pattern */}
        <div
          className="absolute inset-0 opacity-5"
          style={{
            backgroundImage: 'linear-gradient(45deg, #ffffff 10%, transparent 10%)',
            backgroundSize: '20px 20px',
          }}
        ></div>

        <div className="relative z-10 text-right">
          <div className="inline-flex w-16 h-16 bg-emerald-600 rounded-2xl items-center justify-center mb-8 shadow-lg shadow-emerald-900/50">
            <Shield size={32} className="text-white" />
          </div>
          <h1 className="text-4xl font-bold text-white mb-6 leading-tight">
            {t('auth.register.heroTitle')}
          </h1>
          <div className="space-y-4 flex flex-col items-end">
            <div className="bg-slate-800/50 p-4 rounded-lg border-l-4 border-emerald-500 max-w-sm backdrop-blur-sm">
              <h3 className="text-emerald-400 font-bold text-sm mb-1">
                {t('auth.register.featureGranularTitle')}
              </h3>
              <p className="text-slate-300 text-sm">{t('auth.register.featureGranularBody')}</p>
            </div>
            <div className="bg-slate-800/50 p-4 rounded-lg border-l-4 border-blue-500 max-w-sm backdrop-blur-sm">
              <h3 className="text-blue-400 font-bold text-sm mb-1">
                {t('auth.register.featureAuditTitle')}
              </h3>
              <p className="text-slate-300 text-sm">{t('auth.register.featureAuditBody')}</p>
            </div>
          </div>
        </div>
      </div>

      {/* Form Side */}
      <div className="w-full lg:w-1/2 flex items-center justify-center p-8 bg-slate-50 order-1">
        <div className="w-full max-w-md bg-white p-8 rounded-xl shadow-sm border border-slate-200">
          <div className="mb-8">
            <h2 className="text-2xl font-bold text-slate-900">{t('auth.register.title')}</h2>
            <p className="text-slate-500 text-sm mt-2">{t('auth.register.subtitle')}</p>
          </div>

          {error && (
            <div className="mb-4 p-3 bg-red-50 text-red-600 text-sm rounded-lg border border-red-100 flex items-center gap-2">
              <span className="font-semibold">{t('auth.common.errorLabel')}</span> {error}
            </div>
          )}

          {success && (
            <div className="mb-4 p-3 bg-green-50 text-green-600 text-sm rounded-lg border border-green-100 flex items-center gap-2">
              <span className="font-semibold">{t('auth.register.successLabel')}</span>{' '}
              {t('auth.register.successBody')}
            </div>
          )}

          <form
            onSubmit={(e) => {
              void handleSubmit(e);
            }}
            className="space-y-4"
          >
            <div>
              <label className="block text-sm font-semibold text-slate-700 mb-1">
                {t('auth.register.fullName')}
              </label>
              <div className="relative">
                <User className="absolute left-3 top-2.5 text-slate-400" size={18} />
                <input
                  type="text"
                  required
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  className="w-full pl-10 pr-4 py-2 border border-slate-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent text-slate-900 transition-all"
                  placeholder={t('auth.register.fullNamePlaceholder')}
                />
              </div>
            </div>

            <div>
              <label className="block text-sm font-semibold text-slate-700 mb-1">
                {t('auth.register.corporateEmail')}
              </label>
              <div className="relative">
                <Mail className="absolute left-3 top-2.5 text-slate-400" size={18} />
                <input
                  type="email"
                  required
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  className="w-full pl-10 pr-4 py-2 border border-slate-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent text-slate-900 transition-all"
                  placeholder="admin@escuela.edu"
                />
              </div>
            </div>

            <div>
              <label className="block text-sm font-semibold text-slate-700 mb-1">
                {t('auth.register.role')}
              </label>
              <div className="relative">
                <Briefcase className="absolute left-3 top-2.5 text-slate-400" size={18} />
                <select
                  value={role}
                  onChange={(e) => setRole(e.target.value)}
                  className="w-full pl-10 pr-4 py-2 border border-slate-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent text-slate-900 bg-white transition-all appearance-none"
                >
                  <option value="it_director">{t('auth.register.role.itDirector')}</option>
                  <option value="systems_admin">{t('auth.register.role.systemsAdmin')}</option>
                  <option value="academic_coordinator">
                    {t('auth.register.role.academicCoordinator')}
                  </option>
                </select>
              </div>
            </div>

            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="block text-sm font-semibold text-slate-700 mb-1">
                  {t('auth.common.password')}
                </label>
                <div className="relative">
                  <Lock className="absolute left-3 top-2.5 text-slate-400" size={18} />
                  <input
                    type="password"
                    required
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    className={`w-full pl-10 pr-4 py-2 border rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent text-slate-900 transition-all ${
                      password.length > 0 && !passwordLongEnough
                        ? 'border-red-300'
                        : 'border-slate-300'
                    }`}
                    placeholder={t('auth.register.passwordMinShort')}
                  />
                </div>
                {password.length > 0 && !passwordLongEnough && (
                  <p className="text-red-500 text-xs mt-1">{t('auth.register.passwordMinShort')}</p>
                )}
              </div>
              <div>
                <label className="block text-sm font-semibold text-slate-700 mb-1">
                  {t('auth.register.confirmPassword')}
                </label>
                <div className="relative">
                  <input
                    type="password"
                    required
                    value={confirmPassword}
                    onChange={(e) => setConfirmPassword(e.target.value)}
                    className={`w-full pl-4 pr-4 py-2 border rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent text-slate-900 transition-all ${
                      showPasswordMismatch ? 'border-red-300' : 'border-slate-300'
                    }`}
                    placeholder="••••••••"
                  />
                </div>
                {showPasswordMismatch && (
                  <p className="text-red-500 text-xs mt-1">
                    {t('auth.validation.passwordMismatch')}
                  </p>
                )}
              </div>
            </div>

            <div className="pt-2">
              <p className="text-xs text-slate-500 leading-normal">
                {t('auth.register.termsPrefix')}
                <a href="#" className="text-blue-600 font-semibold">
                  {t('auth.register.termsLink')}
                </a>{' '}
                {t('auth.register.termsSuffix')}
              </p>
            </div>

            <button
              type="submit"
              disabled={isLoading || !isFormValid}
              className="w-full py-2.5 bg-slate-900 hover:bg-slate-800 text-white font-semibold rounded-lg shadow-sm transition-all flex items-center justify-center gap-2 disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {isLoading ? (
                <Loader2 className="animate-spin" size={18} />
              ) : (
                <>
                  {t('auth.register.createAccount')} <ArrowRight size={18} />
                </>
              )}
            </button>
          </form>

          <div className="mt-6 text-center text-sm">
            <span className="text-slate-500">{t('auth.common.alreadyHaveAccount')}</span>
            <button onClick={onNavigateToLogin} className="text-blue-600 font-bold hover:underline">
              {t('auth.common.signIn')}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
};

export default Register;
