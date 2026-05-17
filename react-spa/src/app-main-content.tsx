import type { FC } from 'react';
import Dashboard from './views/Dashboard';
import TeacherDashboard from './views/TeacherDashboard';
import Classrooms from './views/Classrooms';
import Groups from './views/Groups';
import UsersView from './views/Users';
import Settings from './views/Settings';
import DomainRequests from './views/DomainRequests';
import RulesManager from './views/RulesManager';
import { translateProductText, type ProductLocale, type ProductT } from './i18n/product-i18n';

export interface SelectedGroup {
  id: string;
  name: string;
  readOnly?: boolean;
}

interface AppMainContentProps {
  activeTab: string;
  admin: boolean;
  pendingSelectedClassroomId: string | null;
  selectedGroup: SelectedGroup | null;
  onBackFromRules: () => void;
  onInitialSelectedClassroomIdConsumed: () => void;
  onNavigateToClassroom: (classroom: { id: string; name: string }) => void;
  onNavigateToRules: (group: SelectedGroup) => void;
}

export function getTitleForTab(
  activeTab: string,
  admin: boolean,
  selectedGroup: SelectedGroup | null,
  t: ProductT = (key, params) => translateProductText('en', key, params)
): string {
  switch (activeTab) {
    case 'dashboard':
      return admin ? t('app.title.dashboard.admin') : t('app.title.dashboard.user');
    case 'classrooms':
      return admin ? t('app.title.classrooms.admin') : t('app.title.classrooms.user');
    case 'groups':
      return admin ? t('app.title.groups.admin') : t('app.title.groups.user');
    case 'rules':
      return selectedGroup
        ? t('app.title.rules.group', { groupName: selectedGroup.name })
        : t('app.title.rules.default');
    case 'users':
      return admin ? t('app.title.users.admin') : t('app.title.dashboard.user');
    case 'domains':
      return admin ? t('app.title.domainRequests.admin') : t('app.title.dashboard.user');
    case 'settings':
      return t('app.title.settings');
    default:
      return 'OpenPath';
  }
}

export function getTitleForTabLocale(
  activeTab: string,
  admin: boolean,
  selectedGroup: SelectedGroup | null,
  locale: ProductLocale
): string {
  return getTitleForTab(activeTab, admin, selectedGroup, (key, params) =>
    translateProductText(locale, key, params)
  );
}

const AppMainContent: FC<AppMainContentProps> = ({
  activeTab,
  admin,
  pendingSelectedClassroomId,
  selectedGroup,
  onBackFromRules,
  onInitialSelectedClassroomIdConsumed,
  onNavigateToClassroom,
  onNavigateToRules,
}) => {
  switch (activeTab) {
    case 'dashboard':
      return admin ? (
        <Dashboard
          onNavigateToRules={onNavigateToRules}
          onNavigateToClassroom={onNavigateToClassroom}
        />
      ) : (
        <TeacherDashboard onNavigateToRules={onNavigateToRules} />
      );
    case 'classrooms':
      return (
        <Classrooms
          initialSelectedClassroomId={pendingSelectedClassroomId}
          onInitialSelectedClassroomIdConsumed={onInitialSelectedClassroomIdConsumed}
        />
      );
    case 'groups':
      return <Groups onNavigateToRules={onNavigateToRules} />;
    case 'rules':
      return selectedGroup ? (
        <RulesManager
          groupId={selectedGroup.id}
          groupName={selectedGroup.name}
          readOnly={selectedGroup.readOnly}
          onBack={onBackFromRules}
        />
      ) : (
        <Groups onNavigateToRules={onNavigateToRules} />
      );
    case 'users':
      return admin ? <UsersView /> : <TeacherDashboard onNavigateToRules={onNavigateToRules} />;
    case 'settings':
      return <Settings />;
    case 'domains':
      return admin ? (
        <DomainRequests />
      ) : (
        <TeacherDashboard onNavigateToRules={onNavigateToRules} />
      );
    default:
      return admin ? (
        <Dashboard
          onNavigateToRules={onNavigateToRules}
          onNavigateToClassroom={onNavigateToClassroom}
        />
      ) : (
        <TeacherDashboard onNavigateToRules={onNavigateToRules} />
      );
  }
};

export default AppMainContent;
