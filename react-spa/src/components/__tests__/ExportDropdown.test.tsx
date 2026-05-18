import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { ExportDropdown } from '../ExportDropdown';

describe('ExportDropdown Component', () => {
  const mockOnExport = vi.fn();

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('renders export button', () => {
    render(<ExportDropdown onExport={mockOnExport} rulesCount={10} />);

    expect(screen.getByRole('button', { name: /export/i })).toBeInTheDocument();
  });

  it('shows dropdown when clicked', () => {
    render(<ExportDropdown onExport={mockOnExport} rulesCount={10} />);

    const button = screen.getByRole('button', { name: /export/i });
    fireEvent.click(button);

    expect(screen.getByText('CSV (.csv)')).toBeInTheDocument();
    expect(screen.getByText('JSON (.json)')).toBeInTheDocument();
    expect(screen.getByText('Text (.txt)')).toBeInTheDocument();
  });

  it('shows rules count in dropdown', () => {
    render(<ExportDropdown onExport={mockOnExport} rulesCount={42} />);

    const button = screen.getByRole('button', { name: /export/i });
    fireEvent.click(button);

    expect(screen.getByText('Export 42 rules')).toBeInTheDocument();
  });

  it('shows singular text for single rule', () => {
    render(<ExportDropdown onExport={mockOnExport} rulesCount={1} />);

    const button = screen.getByRole('button', { name: /export/i });
    fireEvent.click(button);

    expect(screen.getByText('Export 1 rule')).toBeInTheDocument();
  });

  it('calls onExport with csv format when CSV option clicked', () => {
    render(<ExportDropdown onExport={mockOnExport} rulesCount={10} />);

    const button = screen.getByRole('button', { name: /export/i });
    fireEvent.click(button);

    const csvOption = screen.getByText('CSV (.csv)');
    fireEvent.click(csvOption);

    expect(mockOnExport).toHaveBeenCalledWith('csv');
  });

  it('calls onExport with json format when JSON option clicked', () => {
    render(<ExportDropdown onExport={mockOnExport} rulesCount={10} />);

    const button = screen.getByRole('button', { name: /export/i });
    fireEvent.click(button);

    const jsonOption = screen.getByText('JSON (.json)');
    fireEvent.click(jsonOption);

    expect(mockOnExport).toHaveBeenCalledWith('json');
  });

  it('calls onExport with txt format when Text option clicked', () => {
    render(<ExportDropdown onExport={mockOnExport} rulesCount={10} />);

    const button = screen.getByRole('button', { name: /export/i });
    fireEvent.click(button);

    const txtOption = screen.getByText('Text (.txt)');
    fireEvent.click(txtOption);

    expect(mockOnExport).toHaveBeenCalledWith('txt');
  });

  it('closes dropdown after selecting an option', () => {
    render(<ExportDropdown onExport={mockOnExport} rulesCount={10} />);

    const button = screen.getByRole('button', { name: /export/i });
    fireEvent.click(button);

    const csvOption = screen.getByText('CSV (.csv)');
    fireEvent.click(csvOption);

    // Dropdown should be closed
    expect(screen.queryByText('JSON (.json)')).not.toBeInTheDocument();
  });

  it('disables button when rulesCount is 0', () => {
    render(<ExportDropdown onExport={mockOnExport} rulesCount={0} />);

    const button = screen.getByRole('button', { name: /export/i });
    expect(button).toBeDisabled();
  });

  it('disables button when disabled prop is true', () => {
    render(<ExportDropdown onExport={mockOnExport} rulesCount={10} disabled={true} />);

    const button = screen.getByRole('button', { name: /export/i });
    expect(button).toBeDisabled();
  });

  it('toggles dropdown open/close on button click', () => {
    render(<ExportDropdown onExport={mockOnExport} rulesCount={10} />);

    const button = screen.getByRole('button', { name: /export/i });

    // Open
    fireEvent.click(button);
    expect(screen.getByText('CSV (.csv)')).toBeInTheDocument();

    // Close
    fireEvent.click(button);
    expect(screen.queryByText('CSV (.csv)')).not.toBeInTheDocument();
  });
});
