import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { FilterChips } from '../FilterChips';

describe('FilterChips', () => {
  const defaultOptions = [
    { id: 'all', label: 'Todos', count: 10 },
    { id: 'allowed', label: 'Permitidos', count: 5 },
    { id: 'blocked', label: 'Bloqueados', count: 5 },
  ];

  const noop = vi.fn();

  describe('Rendering', () => {
    it('renders all options', () => {
      render(<FilterChips options={defaultOptions} activeId="all" onChange={noop} />);

      expect(screen.getByText('Todos')).toBeInTheDocument();
      expect(screen.getByText('Permitidos')).toBeInTheDocument();
      expect(screen.getByText('Bloqueados')).toBeInTheDocument();
    });

    it('renders counts for each option', () => {
      render(<FilterChips options={defaultOptions} activeId="all" onChange={noop} />);

      expect(screen.getByText('10')).toBeInTheDocument();
      expect(screen.getAllByText('5')).toHaveLength(2);
    });

    it('renders icons when provided', () => {
      const optionsWithIcons = [
        { id: 'test', label: 'Test', count: 1, icon: <span data-testid="test-icon">✓</span> },
      ];

      render(<FilterChips options={optionsWithIcons} activeId="test" onChange={noop} />);

      expect(screen.getByTestId('test-icon')).toBeInTheDocument();
    });

    it('applies custom className', () => {
      const { container } = render(
        <FilterChips
          options={defaultOptions}
          activeId="all"
          onChange={noop}
          className="custom-class"
        />
      );

      expect(container.firstChild).toHaveClass('custom-class');
    });
  });

  describe('Active State', () => {
    it('shows active styling for selected option', () => {
      render(<FilterChips options={defaultOptions} activeId="all" onChange={noop} />);

      const allButton = screen.getByText('Todos').closest('button');
      expect(allButton).toHaveClass('bg-blue-100');
      expect(allButton).toHaveAttribute('aria-pressed', 'true');
    });

    it('shows inactive styling for non-selected options', () => {
      render(<FilterChips options={defaultOptions} activeId="all" onChange={noop} />);

      const allowedButton = screen.getByText('Permitidos').closest('button');
      expect(allowedButton).toHaveClass('bg-slate-100');
      expect(allowedButton).toHaveAttribute('aria-pressed', 'false');
    });

    it('changes active state when different option is selected', () => {
      const { rerender } = render(
        <FilterChips options={defaultOptions} activeId="all" onChange={noop} />
      );

      let allButton = screen.getByText('Todos').closest('button');
      expect(allButton).toHaveAttribute('aria-pressed', 'true');

      rerender(<FilterChips options={defaultOptions} activeId="allowed" onChange={noop} />);

      allButton = screen.getByText('Todos').closest('button');
      const allowedButton = screen.getByText('Permitidos').closest('button');

      expect(allButton).toHaveAttribute('aria-pressed', 'false');
      expect(allowedButton).toHaveAttribute('aria-pressed', 'true');
    });
  });

  describe('Interaction', () => {
    it('calls onChange with option id when clicked', () => {
      const handleChange = vi.fn();
      render(<FilterChips options={defaultOptions} activeId="all" onChange={handleChange} />);

      fireEvent.click(screen.getByText('Permitidos'));

      expect(handleChange).toHaveBeenCalledWith('allowed');
    });

    it('calls onChange when clicking active option', () => {
      const handleChange = vi.fn();
      render(<FilterChips options={defaultOptions} activeId="all" onChange={handleChange} />);

      fireEvent.click(screen.getByText('Todos'));

      expect(handleChange).toHaveBeenCalledWith('all');
    });

    it('calls onChange only once per click', () => {
      const handleChange = vi.fn();
      render(<FilterChips options={defaultOptions} activeId="all" onChange={handleChange} />);

      fireEvent.click(screen.getByText('Bloqueados'));

      expect(handleChange).toHaveBeenCalledTimes(1);
    });
  });

  describe('Accessibility', () => {
    it('has role="group" with aria-label', () => {
      render(<FilterChips options={defaultOptions} activeId="all" onChange={noop} />);

      const group = screen.getByRole('group');
      expect(group).toHaveAttribute('aria-label', 'Filters');
    });

    it('buttons have type="button"', () => {
      render(<FilterChips options={defaultOptions} activeId="all" onChange={noop} />);

      const buttons = screen.getAllByRole('button');
      buttons.forEach((button) => {
        expect(button).toHaveAttribute('type', 'button');
      });
    });

    it('active button has aria-pressed="true"', () => {
      render(<FilterChips options={defaultOptions} activeId="allowed" onChange={noop} />);

      const allowedButton = screen.getByText('Permitidos').closest('button');
      expect(allowedButton).toHaveAttribute('aria-pressed', 'true');
    });
  });

  describe('Edge Cases', () => {
    it('renders with empty options array', () => {
      const { container } = render(<FilterChips options={[]} activeId="" onChange={noop} />);

      expect(container.querySelector('button')).not.toBeInTheDocument();
    });

    it('handles single option', () => {
      const singleOption = [{ id: 'single', label: 'Solo', count: 1 }];
      render(<FilterChips options={singleOption} activeId="single" onChange={noop} />);

      expect(screen.getByText('Solo')).toBeInTheDocument();
    });

    it('handles zero count', () => {
      const zeroCount = [{ id: 'empty', label: 'Vacío', count: 0 }];
      render(<FilterChips options={zeroCount} activeId="empty" onChange={noop} />);

      expect(screen.getByText('0')).toBeInTheDocument();
    });

    it('handles large counts', () => {
      const largeCount = [{ id: 'large', label: 'Grande', count: 9999 }];
      render(<FilterChips options={largeCount} activeId="large" onChange={noop} />);

      expect(screen.getByText('9999')).toBeInTheDocument();
    });
  });
});
