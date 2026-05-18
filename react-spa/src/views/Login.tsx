import React, { useState } from 'react';
import { Mail, Lock, ArrowRight, Loader2, ShieldCheck } from 'lucide-react';
import { login, loginWithGoogle } from '../lib/auth';
import { reportError } from '../lib/reportError';
import GoogleLoginButton from '../components/GoogleLoginButton';
import { useT } from '../i18n/product-i18n';

interface LoginProps {
  onLogin: () => void;
  onNavigateToRegister: () => void;
  onNavigateToForgot: () => void;
}

const Login: React.FC<LoginProps> = ({ onLogin, onNavigateToRegister, onNavigateToForgot }) => {
  const t = useT();
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');

  const handleSubmit = async (e: React.SyntheticEvent<HTMLFormElement>) => {
    e.preventDefault();
    setIsLoading(true);
    setError('');

    try {
      await login(email, password);
      onLogin();
    } catch (err) {
      setError(t('auth.login.invalidCredentials'));
      reportError('Failed to login:', err);
    } finally {
      setIsLoading(false);
    }
  };

  const handleGoogleSuccess = async (idToken: string) => {
    setIsLoading(true);
    setError('');
    try {
      await loginWithGoogle(idToken);
      onLogin();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : t('auth.login.googleError');
      setError(message);
      reportError('Failed to login with Google:', err);
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <div className="min-h-screen flex bg-white">
      {/* Branding Side */}
      <div className="hidden lg:flex lg:w-1/2 bg-slate-900 flex-col justify-center px-12 xl:px-24 relative overflow-hidden">
        {/* Subtle geometric pattern for stability */}
        <div
          className="absolute inset-0 opacity-5"
          style={{
            backgroundImage: 'radial-gradient(#ffffff 1px, transparent 1px)',
            backgroundSize: '30px 30px',
          }}
        ></div>

        <div className="relative z-10">
          <div className="w-16 h-16 bg-blue-600 rounded-2xl flex items-center justify-center mb-8 shadow-lg shadow-blue-900/50">
            <ShieldCheck size={32} className="text-white" />
          </div>
          <h1 className="text-4xl font-bold text-white mb-6 leading-tight">
            {t('auth.login.heroTitle')}
          </h1>
          <p className="text-slate-400 text-lg leading-relaxed max-w-md">
            {t('auth.login.heroBody')}
          </p>

          <div className="mt-12 flex items-center gap-4 text-sm font-medium text-slate-500">
            <div className="flex items-center gap-2">
              <div className="w-2 h-2 bg-green-500 rounded-full"></div>{' '}
              {t('auth.login.secureConnection')}
            </div>
            <div className="flex items-center gap-2">
              <div className="w-2 h-2 bg-green-500 rounded-full"></div> {t('auth.login.openSource')}
            </div>
          </div>
        </div>
      </div>

      {/* Form Side */}
      <div className="w-full lg:w-1/2 flex items-center justify-center p-8 bg-slate-50">
        <div className="w-full max-w-md bg-white p-8 rounded-xl shadow-sm border border-slate-200">
          <div className="text-center mb-8">
            <h2 className="text-2xl font-bold text-slate-900">{t('auth.login.title')}</h2>
            <p className="text-slate-500 text-sm mt-2">{t('auth.login.subtitle')}</p>
          </div>

          {error && (
            <div className="mb-4 p-3 bg-red-50 text-red-600 text-sm rounded-lg border border-red-100 flex items-center gap-2">
              <span className="font-semibold">{t('auth.common.errorLabel')}</span> {error}
            </div>
          )}

          <form
            onSubmit={(e) => {
              void handleSubmit(e);
            }}
            className="space-y-5"
          >
            <div>
              <label className="block text-sm font-semibold text-slate-700 mb-2">
                {t('auth.common.email')}
              </label>
              <div className="relative">
                <Mail className="absolute left-3 top-2.5 text-slate-400" size={18} />
                <input
                  type="email"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  required
                  className="w-full pl-10 pr-4 py-2 border border-slate-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent text-slate-900 placeholder-slate-400 transition-all"
                  placeholder="admin@institucion.edu"
                />
              </div>
            </div>

            <div>
              <label className="block text-sm font-semibold text-slate-700 mb-2">
                {t('auth.common.password')}
              </label>
              <div className="relative">
                <Lock className="absolute left-3 top-2.5 text-slate-400" size={18} />
                <input
                  type="password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  required
                  className="w-full pl-10 pr-4 py-2 border border-slate-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent text-slate-900 placeholder-slate-400 transition-all"
                  placeholder="••••••••"
                />
              </div>
            </div>

            <div className="flex items-center justify-between text-sm">
              <label className="flex items-center cursor-pointer text-slate-600">
                <input
                  type="checkbox"
                  className="w-4 h-4 rounded border-slate-300 text-blue-600 focus:ring-blue-500 mr-2"
                />
                {t('auth.login.rememberSession')}
              </label>
              <button
                type="button"
                onClick={onNavigateToForgot}
                className="text-blue-600 hover:text-blue-800 font-medium"
              >
                {t('auth.login.recoverPassword')}
              </button>
            </div>

            <button
              type="submit"
              disabled={isLoading}
              className="w-full bg-blue-600 hover:bg-blue-700 text-white font-semibold py-2.5 rounded-lg flex items-center justify-center gap-2 transition-colors disabled:opacity-50 disabled:cursor-not-allowed shadow-lg shadow-blue-200"
            >
              {isLoading ? (
                <Loader2 className="animate-spin" size={18} />
              ) : (
                <>
                  {t('auth.common.signIn')} <ArrowRight size={18} />
                </>
              )}
            </button>

            <div className="relative py-2">
              <div className="absolute inset-0 flex items-center">
                <div className="w-full border-t border-slate-200"></div>
              </div>
              <div className="relative flex justify-center text-xs uppercase">
                <span className="bg-white px-2 text-slate-400">
                  {t('auth.login.alternativeDivider')}
                </span>
              </div>
            </div>

            <GoogleLoginButton
              onSuccess={(token) => {
                void handleGoogleSuccess(token);
              }}
              disabled={isLoading}
            />
          </form>

          <div className="mt-6 pt-6 border-t border-slate-100 text-center text-sm">
            <span className="text-slate-500">{t('auth.common.newToPlatform')}</span>
            <button
              onClick={onNavigateToRegister}
              className="text-blue-600 font-bold hover:underline"
            >
              {t('auth.common.requestAccess')}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
};

export default Login;
