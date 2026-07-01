import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { GroupSettingsForm } from '../GroupSettingsForm';

function renderForm(overrides = {}) {
  const props = {
    saving: false,
    slug: 'grupo-1',
    description: 'Grupo 1',
    status: 'Active' as const,
    visibility: 'private' as const,
    error: null,
    onDescriptionChange: vi.fn(),
    onStatusChange: vi.fn(),
    onVisibilityChange: vi.fn(),
    onSave: vi.fn(),
    onCancel: vi.fn(),
    ...overrides,
  };
  render(<GroupSettingsForm {...props} />);
  return props;
}

describe('GroupSettingsForm', () => {
  it('edits fields and triggers save/cancel', () => {
    const props = renderForm();

    fireEvent.change(screen.getByRole('textbox'), { target: { value: 'new desc' } });
    fireEvent.click(screen.getByRole('button', { name: 'Inactive' }));
    fireEvent.click(screen.getByRole('button', { name: 'Public' }));
    fireEvent.click(screen.getByRole('button', { name: 'Save Changes' }));
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));

    expect(props.onDescriptionChange).toHaveBeenCalledWith('new desc');
    expect(props.onStatusChange).toHaveBeenCalledWith('Inactive');
    expect(props.onVisibilityChange).toHaveBeenCalledWith('instance_public');
    expect(props.onSave).toHaveBeenCalled();
    expect(props.onCancel).toHaveBeenCalled();
  });

  it('shows the error and disables the buttons while saving', () => {
    renderForm({ saving: true, error: 'Boom' });
    expect(screen.getByText('Boom')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Save Changes/i })).toBeDisabled();
    expect(screen.getByRole('button', { name: /Cancel/i })).toBeDisabled();
  });

  it('omits the slug hint when slug is not provided', () => {
    renderForm({ slug: undefined });
    const slugParagraph = document.querySelector('p.text-xs.text-slate-500');
    expect(slugParagraph?.textContent ?? '').not.toContain('Slug:');
  });
});
