import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { RulesManagerHeader } from '../RulesManagerHeader';

describe('RulesManagerHeader', () => {
  it('navigates back and changes view mode', () => {
    const onBack = vi.fn();
    const onViewModeChange = vi.fn();

    render(
      <RulesManagerHeader
        groupName="Grupo 1"
        viewMode="flat"
        onBack={onBack}
        onViewModeChange={onViewModeChange}
      />
    );

    fireEvent.click(screen.getByTitle('Back to groups'));
    fireEvent.click(screen.getByTitle('Hierarchical view'));

    expect(onBack).toHaveBeenCalled();
    expect(onViewModeChange).toHaveBeenCalledWith('hierarchical');
  });

  it('calls onViewModeChange with "flat" when clicking the flat view button from hierarchical mode', () => {
    const onViewModeChange = vi.fn();

    render(
      <RulesManagerHeader
        groupName="My Group"
        viewMode="hierarchical"
        onBack={vi.fn()}
        onViewModeChange={onViewModeChange}
      />
    );

    fireEvent.click(screen.getByTitle('Flat view'));
    expect(onViewModeChange).toHaveBeenCalledWith('flat');
  });

  it('flat view button has active styling when viewMode is flat', () => {
    render(
      <RulesManagerHeader
        groupName="My Group"
        viewMode="flat"
        onBack={vi.fn()}
        onViewModeChange={vi.fn()}
      />
    );

    const flatBtn = screen.getByTitle('Flat view');
    expect(flatBtn).toHaveClass('bg-white');
    expect(flatBtn).toHaveClass('text-slate-900');
  });

  it('hierarchical view button has active styling when viewMode is hierarchical', () => {
    render(
      <RulesManagerHeader
        groupName="My Group"
        viewMode="hierarchical"
        onBack={vi.fn()}
        onViewModeChange={vi.fn()}
      />
    );

    const hierarchicalBtn = screen.getByTitle('Hierarchical view');
    expect(hierarchicalBtn).toHaveClass('bg-white');
    expect(hierarchicalBtn).toHaveClass('text-slate-900');
  });

  it('renders badges + settings button when onOpenSettings is provided and opens settings', () => {
    const onOpenSettings = vi.fn();
    render(
      <RulesManagerHeader
        groupName="Grupo 1"
        viewMode="flat"
        onBack={vi.fn()}
        onViewModeChange={vi.fn()}
        status="Inactive"
        visibility="instance_public"
        onOpenSettings={onOpenSettings}
      />
    );

    expect(screen.getByText('Inactive')).toBeInTheDocument();
    expect(screen.getByText('Public')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: /settings/i }));
    expect(onOpenSettings).toHaveBeenCalled();
  });

  it('hides the settings button when onOpenSettings is not provided', () => {
    render(
      <RulesManagerHeader
        groupName="Grupo 1"
        viewMode="flat"
        onBack={vi.fn()}
        onViewModeChange={vi.fn()}
      />
    );

    expect(screen.queryByRole('button', { name: /settings/i })).not.toBeInTheDocument();
  });
});
