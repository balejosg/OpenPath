import React from 'react';
import { Shield, ArrowLeft, Mail, AlertCircle } from 'lucide-react';

interface ForgotPasswordProps {
  onNavigateToLogin: () => void;
  onNavigateToReset: () => void;
}

const ForgotPassword: React.FC<ForgotPasswordProps> = ({
  onNavigateToLogin,
  onNavigateToReset,
}) => {
  return (
    <div className="min-h-screen bg-gradient-to-br from-slate-900 via-slate-800 to-slate-900 flex items-center justify-center p-4">
      <div className="w-full max-w-md">
        {/* Logo */}
        <div className="text-center mb-8">
          <div className="inline-flex items-center justify-center w-16 h-16 bg-blue-600 rounded-2xl mb-4 shadow-lg shadow-blue-900/30">
            <Shield className="text-white" size={32} />
          </div>
          <h1 className="text-2xl font-bold text-white">OpenPath</h1>
          <p className="text-slate-400 mt-1">Recover password</p>
        </div>

        {/* Card */}
        <div className="bg-white rounded-2xl shadow-xl p-8">
          <button
            onClick={onNavigateToLogin}
            className="flex items-center gap-2 text-slate-500 hover:text-slate-700 mb-6 text-sm font-medium transition-colors"
          >
            <ArrowLeft size={16} />
            Back to sign in
          </button>

          <div className="mb-6">
            <div className="flex items-start gap-3 p-4 bg-amber-50 border border-amber-200 rounded-lg">
              <AlertCircle className="text-amber-600 flex-shrink-0 mt-0.5" size={20} />
              <div>
                <h3 className="font-semibold text-amber-800 text-sm">Recovery process</h3>
                <p className="text-amber-700 text-sm mt-1">
                  To reset your password, contact your institution administrator. They will provide
                  a recovery token.
                </p>
              </div>
            </div>
          </div>

          <div className="space-y-4">
            <div className="text-center py-6 border-2 border-dashed border-slate-200 rounded-lg">
              <Mail className="mx-auto text-slate-400 mb-3" size={32} />
              <p className="text-slate-600 text-sm">
                Request a recovery token from your administrator
              </p>
            </div>

            <button
              onClick={onNavigateToReset}
              className="w-full bg-blue-600 hover:bg-blue-700 text-white font-semibold py-3 px-4 rounded-lg transition-colors shadow-sm"
            >
              I have a token
            </button>

            <div className="text-center">
              <button
                onClick={onNavigateToLogin}
                className="text-slate-500 hover:text-slate-700 text-sm font-medium transition-colors"
              >
                Cancel
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

export default ForgotPassword;
