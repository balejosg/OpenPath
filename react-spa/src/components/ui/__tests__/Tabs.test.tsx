import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { Tabs } from '../Tabs';

describe('Tabs Component', () => {
  const defaultTabs = [
    { id: 'all', label: 'Todos', count: 57 },
    { id: 'allowed', label: 'Permitidos', count: 12 },
    { id: 'blocked', label: 'Bloqueados', count: 45 },
  ];

  const noop = vi.fn();

  it('renders all tabs correctly', () => {
    render(<Tabs tabs={defaultTabs} activeTab="all" onChange={noop} />);

    expect(screen.getByRole('tab', { name: /todos/i })).toBeInTheDocument();
    expect(screen.getByRole('tab', { name: /permitidos/i })).toBeInTheDocument();
    expect(screen.getByRole('tab', { name: /bloqueados/i })).toBeInTheDocument();
  });

  it('displays counts for each tab', () => {
    render(<Tabs tabs={defaultTabs} activeTab="all" onChange={noop} />);

    expect(screen.getByText('57')).toBeInTheDocument();
    expect(screen.getByText('12')).toBeInTheDocument();
    expect(screen.getByText('45')).toBeInTheDocument();
  });

  it('marks active tab with aria-selected', () => {
    render(<Tabs tabs={defaultTabs} activeTab="allowed" onChange={noop} />);

    const activeTab = screen.getByRole('tab', { name: /permitidos/i });
    expect(activeTab).toHaveAttribute('aria-selected', 'true');

    const inactiveTab = screen.getByRole('tab', { name: /todos/i });
    expect(inactiveTab).toHaveAttribute('aria-selected', 'false');
  });

  it('calls onChange when tab is clicked', () => {
    const handleChange = vi.fn();
    render(<Tabs tabs={defaultTabs} activeTab="all" onChange={handleChange} />);

    fireEvent.click(screen.getByRole('tab', { name: /bloqueados/i }));
    expect(handleChange).toHaveBeenCalledWith('blocked');
  });

  it('renders tabs with icons when provided', () => {
    const tabsWithIcons = [
      { id: 'test', label: 'Test', count: 5, icon: <span data-testid="test-icon">Icon</span> },
    ];

    render(<Tabs tabs={tabsWithIcons} activeTab="test" onChange={noop} />);
    expect(screen.getByTestId('test-icon')).toBeInTheDocument();
  });

  it('renders without count when not provided', () => {
    const tabsWithoutCount = [{ id: 'nocount', label: 'No Counter' }];

    render(<Tabs tabs={tabsWithoutCount} activeTab="nocount" onChange={noop} />);
    expect(screen.getByRole('tab', { name: /no counter/i })).toBeInTheDocument();
  });
});
