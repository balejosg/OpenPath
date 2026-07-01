import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { GroupSettingsDrawer } from '../GroupSettingsDrawer';

function renderDrawer(overrides = {}) {
  const props = {
    isOpen: true,
    title: 'Settings: Grupo 1',
    saving: false,
    slug: 'grupo-1',
    description: 'Grupo 1',
    status: 'Active' as const,
    visibility: 'private' as const,
    error: null,
    onClose: vi.fn(),
    onDescriptionChange: vi.fn(),
    onStatusChange: vi.fn(),
    onVisibilityChange: vi.fn(),
    onSave: vi.fn(),
    ...overrides,
  };
  render(<GroupSettingsDrawer {...props} />);
  return props;
}

describe('GroupSettingsDrawer', () => {
  it('renders nothing when closed', () => {
    const { container } = render(
      <GroupSettingsDrawer
        isOpen={false}
        title="x"
        saving={false}
        description=""
        status="Active"
        visibility="private"
        error={null}
        onClose={vi.fn()}
        onDescriptionChange={vi.fn()}
        onStatusChange={vi.fn()}
        onVisibilityChange={vi.fn()}
        onSave={vi.fn()}
      />
    );
    expect(container.firstChild).toBeNull();
  });

  it('renders the title + form and wires close/save', () => {
    const props = renderDrawer();
    expect(screen.getByText('Settings: Grupo 1')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Save Changes' })).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'Save Changes' }));
    expect(props.onSave).toHaveBeenCalled();

    fireEvent.click(screen.getByRole('button', { name: /close/i }));
    expect(props.onClose).toHaveBeenCalled();
  });

  it('routes the form Cancel button to onClose', () => {
    const props = renderDrawer();
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(props.onClose).toHaveBeenCalled();
  });
});
