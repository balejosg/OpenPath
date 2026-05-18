import React, { useEffect, useRef } from 'react';
import { useGoogleAuth, GoogleCredentialResponse } from '../hooks/useGoogleAuth';
import '../types/google.d'; // Import for global Window type augmentation

interface GoogleLoginButtonProps {
  onSuccess: (idToken: string) => void;
  disabled?: boolean;
}

const GoogleLoginButton: React.FC<GoogleLoginButtonProps> = ({ onSuccess, disabled }) => {
  const { isLoaded, initGoogleAuth } = useGoogleAuth();
  const googleButtonRef = useRef<HTMLDivElement>(null);
  const initializedRef = useRef(false);

  useEffect(() => {
    // Only initialize once when loaded and not disabled
    if (isLoaded && !disabled && !initializedRef.current && googleButtonRef.current) {
      initializedRef.current = true;

      initGoogleAuth((response: GoogleCredentialResponse) => {
        onSuccess(response.credential);
      });

      // Render directly to the ref element
      window.google?.accounts.id.renderButton(googleButtonRef.current, {
        theme: 'outline',
        size: 'large',
        width: '300', // Fixed width in pixels (not %)
        text: 'signin_with',
        shape: 'rectangular',
        logo_alignment: 'left',
      });
    }
  }, [isLoaded, disabled, initGoogleAuth, onSuccess]);

  // Reset initialized state if disabled changes
  useEffect(() => {
    if (disabled) {
      initializedRef.current = false;
    }
  }, [disabled]);

  return (
    <div className="w-full flex justify-center my-4" data-testid="google-login-container">
      <div
        className={`${disabled === true ? 'opacity-50 pointer-events-none' : ''} flex justify-center`}
      >
        {!isLoaded && disabled !== true && (
          <div
            className="w-[300px] h-10 bg-slate-100 animate-pulse rounded-lg border border-slate-200"
            aria-label="Loading Google button..."
          />
        )}
        {/* 
          This div is ONLY managed by Google SDK, not by React.
          React will not try to update/remove its children.
        */}
        <div
          ref={googleButtonRef}
          id="google-signin-btn"
          data-testid="google-signin-btn"
          className={isLoaded && !disabled ? '' : 'hidden'}
        />
      </div>
    </div>
  );
};

export default GoogleLoginButton;
