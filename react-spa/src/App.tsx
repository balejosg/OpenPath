import React, { useState, useEffect, useRef } from 'react';
import Sidebar from './components/Sidebar';
import Header from './components/Header';
import { isAuthenticated, onAuthChange, isAdmin } from './lib/auth';
import AppAuthContent from './app-auth-content';
import AppMainContent, { getTitleForTab, type SelectedGroup } from './app-main-content';
import {
  type AuthView,
  getAuthViewFromPathname,
  getPathForAuthView,
  getPathForTab,
  getTabFromPathname,
  isAuthPath,
} from './app-navigation';
import { OpenPathI18nProvider, useT } from './i18n/product-i18n';

const AppContent: React.FC = () => {
  const initialPathname = typeof window !== 'undefined' ? window.location.pathname : '/';
  const initialIsAuth = isAuthenticated();
  const t = useT();

  const [isAuth, setIsAuth] = useState(initialIsAuth);
  const [authView, setAuthView] = useState<AuthView>(() =>
    getAuthViewFromPathname(initialPathname)
  );

  const [activeTab, setActiveTab] = useState(() => getTabFromPathname(initialPathname));
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [pendingSelectedClassroomId, setPendingSelectedClassroomId] = useState<string | null>(null);
  const isAuthRef = useRef(isAuth);

  useEffect(() => {
    isAuthRef.current = isAuth;
  }, [isAuth]);

  // State for rules manager navigation
  const [selectedGroup, setSelectedGroup] = useState<SelectedGroup | null>(null);

  useEffect(() => {
    return onAuthChange(() => {
      const authed = isAuthenticated();
      setIsAuth(authed);

      if (typeof window !== 'undefined') {
        const pathname = window.location.pathname;
        if (authed) {
          setActiveTab(getTabFromPathname(pathname));
        } else {
          setAuthView(getAuthViewFromPathname(pathname));
        }
      }
    });
  }, []);

  useEffect(() => {
    if (typeof window === 'undefined') return;

    const handlePopState = () => {
      const pathname = window.location.pathname;
      if (isAuthRef.current) {
        setActiveTab(getTabFromPathname(pathname));
      } else {
        setAuthView(getAuthViewFromPathname(pathname));
      }
    };

    window.addEventListener('popstate', handlePopState);
    return () => window.removeEventListener('popstate', handlePopState);
  }, []);

  useEffect(() => {
    if (typeof window === 'undefined') return;

    if (isAuth) {
      const nextPath = getPathForTab(activeTab);
      if (window.location.pathname !== nextPath) {
        window.history.pushState(null, '', nextPath);
      }
      return;
    }

    // If the user deep-linked to a non-auth URL while logged out, preserve the URL.
    // Only update the URL for explicit auth routes (or when user navigates within auth views).
    if (authView !== 'login' || isAuthPath(window.location.pathname)) {
      const nextPath = getPathForAuthView(authView);
      if (window.location.pathname !== nextPath) {
        window.history.pushState(null, '', nextPath);
      }
    }
  }, [isAuth, activeTab, authView]);

  const handleLogin = () => {
    setIsAuth(true);
    if (typeof window !== 'undefined') {
      setActiveTab(getTabFromPathname(window.location.pathname));
    }
  };
  const handleRegister = () => {
    setIsAuth(true);
    if (typeof window !== 'undefined') {
      setActiveTab(getTabFromPathname(window.location.pathname));
    }
  };

  // Handle navigation to rules manager
  const handleNavigateToRules = (group: SelectedGroup) => {
    setSelectedGroup(group);
    setActiveTab('rules');
  };

  // Handle back from rules manager
  const handleBackFromRules = () => {
    setSelectedGroup(null);
    setActiveTab('groups');
  };

  const handleNavigateToClassroom = (classroom: { id: string; name: string }) => {
    setPendingSelectedClassroomId(classroom.id);
    setActiveTab('classrooms');
  };

  const handlePendingSelectedClassroomIdConsumed = () => {
    setPendingSelectedClassroomId(null);
  };

  const handleSidebarTabChange = (tab: string) => {
    setPendingSelectedClassroomId(null);
    setActiveTab(tab);
    setSidebarOpen(false);
  };

  const admin = isAdmin();

  if (!isAuth) {
    return (
      <AppAuthContent
        authView={authView}
        onLogin={handleLogin}
        onRegister={handleRegister}
        onSelectAuthView={setAuthView}
      />
    );
  }

  return (
    <div className="flex min-h-screen bg-slate-50 font-sans text-slate-900">
      <Sidebar activeTab={activeTab} setActiveTab={handleSidebarTabChange} isOpen={sidebarOpen} />

      {/* Overlay */}
      {sidebarOpen && (
        <div
          className="fixed inset-0 bg-slate-900/50 z-30 md:hidden backdrop-blur-sm"
          onClick={() => setSidebarOpen(false)}
        />
      )}

      {/* Main Content */}
      <div className="flex-1 md:ml-64 flex flex-col min-h-screen">
        <Header
          onMenuClick={() => setSidebarOpen(!sidebarOpen)}
          title={getTitleForTab(activeTab, admin, selectedGroup, t)}
        />

        <main className="flex-1 p-6 md:p-8 overflow-y-auto">
          <div className="max-w-7xl mx-auto">
            <AppMainContent
              activeTab={activeTab}
              admin={admin}
              pendingSelectedClassroomId={pendingSelectedClassroomId}
              selectedGroup={selectedGroup}
              onBackFromRules={handleBackFromRules}
              onInitialSelectedClassroomIdConsumed={handlePendingSelectedClassroomIdConsumed}
              onNavigateToClassroom={handleNavigateToClassroom}
              onNavigateToRules={handleNavigateToRules}
            />
          </div>
        </main>
      </div>
    </div>
  );
};

const App: React.FC = () => (
  <OpenPathI18nProvider>
    <AppContent />
  </OpenPathI18nProvider>
);

export default App;
