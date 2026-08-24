import { render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import type { Classroom } from '../../../types';
import { OpenPathI18nProvider } from '../../../i18n/product-i18n';
import EnrollClassroomModal from '../EnrollClassroomModal';

const classroom = {
  id: 'classroom-1',
  displayName: 'Lab North',
  currentGroupId: 'group-1',
} as Classroom;

function renderModal(windowsInstallAction?: React.ReactNode) {
  return render(
    <OpenPathI18nProvider locale="en">
      <EnrollClassroomModal
        isOpen
        enrollToken="ticket-1"
        selectedClassroom={classroom}
        enrollPlatform="windows"
        enrollCommand="powershell -File install-agent.ps1"
        windowsInstallAction={windowsInstallAction}
        onClose={vi.fn()}
        onSelectPlatform={vi.fn()}
        onCopy={vi.fn()}
        isCopied={false}
      />
    </OpenPathI18nProvider>
  );
}

describe('EnrollClassroomModal', () => {
  it('renders Windows first with the supplied installer action before PowerShell', () => {
    renderModal(<a href="/installer.exe">Download action</a>);

    const tabs = screen.getAllByRole('tab');
    expect(tabs[0]).toHaveTextContent('Windows');
    expect(tabs[1]).toHaveTextContent('Linux');
    expect(tabs[0]).toHaveAttribute('aria-selected', 'true');

    const action = screen.getByRole('link', { name: 'Download action' });
    expect(action).toBeInTheDocument();
    expect(action.compareDocumentPosition(screen.getByText('PowerShell alternative'))).toBe(
      Node.DOCUMENT_POSITION_FOLLOWING
    );
    expect(screen.getByText('powershell -File install-agent.ps1')).toBeInTheDocument();
  });

  it('keeps the PowerShell fallback when no installer action is supplied', () => {
    renderModal();

    expect(screen.getByText('PowerShell alternative')).toBeInTheDocument();
    expect(screen.getByText('powershell -File install-agent.ps1')).toBeInTheDocument();
  });
});
