import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { BulkImportModal } from '../BulkImportModal';

describe('BulkImportModal Component', () => {
  const mockOnClose = vi.fn();
  const mockOnImport = vi.fn();

  beforeEach(() => {
    vi.clearAllMocks();
    mockOnImport.mockResolvedValue({ created: 0, total: 0 });
  });

  it('renders nothing when closed', () => {
    const { container } = render(
      <BulkImportModal isOpen={false} onClose={mockOnClose} onImport={mockOnImport} />
    );
    expect(container.querySelector('[role="dialog"]')).toBeNull();
  });

  it('renders modal when open', () => {
    render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

    expect(screen.getByText('Import rules')).toBeInTheDocument();
    expect(screen.getByText('Rule type')).toBeInTheDocument();
    expect(screen.getByPlaceholderText(/paste domains/i)).toBeInTheDocument();
  });

  it('shows rule type options', () => {
    render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

    expect(screen.getByText('Allowed domains')).toBeInTheDocument();
    expect(screen.getByText('Blocked subdomains')).toBeInTheDocument();
    expect(screen.getByText('Blocked paths')).toBeInTheDocument();
  });

  it('counts domains correctly from textarea input', async () => {
    render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

    const textarea = screen.getByPlaceholderText(/paste domains/i);
    await userEvent.type(textarea, 'google.com\nyoutube.com\nexample.org');

    expect(screen.getByText('3 valid')).toBeInTheDocument();
  });

  it('shows singular text for single domain', async () => {
    render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

    const textarea = screen.getByPlaceholderText(/paste domains/i);
    await userEvent.type(textarea, 'google.com');

    expect(screen.getByText('1 valid')).toBeInTheDocument();
  });

  it('handles comma-separated values', async () => {
    render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

    const textarea = screen.getByPlaceholderText(/paste domains/i);
    await userEvent.type(textarea, 'google.com, youtube.com, example.org');

    expect(screen.getByText('3 valid')).toBeInTheDocument();
  });

  it('filters out duplicate domains', async () => {
    render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

    const textarea = screen.getByPlaceholderText(/paste domains/i);
    await userEvent.type(textarea, 'google.com\ngoogle.com\nyoutube.com');

    expect(screen.getByText('2 valid')).toBeInTheDocument();
  });

  it('filters out comment lines starting with #', async () => {
    render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

    const textarea = screen.getByPlaceholderText(/paste domains/i);
    await userEvent.type(
      textarea,
      '# This is a comment\ngoogle.com\n# Another comment\nyoutube.com'
    );

    expect(screen.getByText('2 valid')).toBeInTheDocument();
  });

  it('disables import button when no domains entered', () => {
    render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

    const importButton = screen.getByRole('button', { name: /import/i });
    expect(importButton).toBeDisabled();
  });

  it('enables import button when domains are entered', async () => {
    render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

    const textarea = screen.getByPlaceholderText(/paste domains/i);
    await userEvent.type(textarea, 'google.com');

    const importButton = screen.getByRole('button', { name: /import/i });
    expect(importButton).not.toBeDisabled();
  });

  it('calls onImport with correct values when import clicked', async () => {
    mockOnImport.mockResolvedValue({ created: 2, total: 2 });
    render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

    const textarea = screen.getByPlaceholderText(/paste domains/i);
    await userEvent.type(textarea, 'google.com\nyoutube.com');

    const importButton = screen.getByRole('button', { name: /import/i });
    fireEvent.click(importButton);

    await waitFor(() => {
      expect(mockOnImport).toHaveBeenCalledWith(['google.com', 'youtube.com'], 'whitelist');
    });
  });

  it('allows selecting different rule types', async () => {
    mockOnImport.mockResolvedValue({ created: 1, total: 1 });
    render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

    // Select blocked_subdomain type
    const blockedOption = screen.getByText('Blocked subdomains');
    fireEvent.click(blockedOption);

    const textarea = screen.getByPlaceholderText(/paste subdomains/i);
    await userEvent.type(textarea, 'ads.example.com');

    const importButton = screen.getByRole('button', { name: /import/i });
    fireEvent.click(importButton);

    await waitFor(() => {
      expect(mockOnImport).toHaveBeenCalledWith(['ads.example.com'], 'blocked_subdomain');
    });
  });

  describe('Dynamic UI text per rule type', () => {
    it('shows domain-specific label and placeholder for whitelist type', () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      expect(screen.getByText('Domains to import')).toBeInTheDocument();
      expect(screen.getByPlaceholderText(/paste domains here/i)).toBeInTheDocument();
      expect(screen.getByText(/paste or type domains above/i)).toBeInTheDocument();
    });

    it('shows subdomain-specific label and placeholder for blocked_subdomain type', () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      fireEvent.click(screen.getByText('Blocked subdomains'));

      expect(screen.getByText('Subdomains to import')).toBeInTheDocument();
      expect(screen.getByPlaceholderText(/paste subdomains here/i)).toBeInTheDocument();
      expect(screen.getByText(/paste or type subdomains above/i)).toBeInTheDocument();
    });

    it('shows path-specific label and placeholder for blocked_path type', () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      fireEvent.click(screen.getByText('Blocked paths'));

      expect(screen.getByText('Paths to import')).toBeInTheDocument();
      expect(screen.getByPlaceholderText(/paste paths here/i)).toBeInTheDocument();
      expect(screen.getByText(/paste or type paths above/i)).toBeInTheDocument();
    });

    it('updates label and placeholder when switching rule types', () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      // Start with whitelist (default)
      expect(screen.getByText('Domains to import')).toBeInTheDocument();

      // Switch to blocked_subdomain
      fireEvent.click(screen.getByText('Blocked subdomains'));
      expect(screen.getByText('Subdomains to import')).toBeInTheDocument();
      expect(screen.queryByText('Domains to import')).not.toBeInTheDocument();

      // Switch to blocked_path
      fireEvent.click(screen.getByText('Blocked paths'));
      expect(screen.getByText('Paths to import')).toBeInTheDocument();
      expect(screen.queryByText('Subdomains to import')).not.toBeInTheDocument();

      // Switch back to whitelist
      fireEvent.click(screen.getByText('Allowed domains'));
      expect(screen.getByText('Domains to import')).toBeInTheDocument();
      expect(screen.queryByText('Paths to import')).not.toBeInTheDocument();
    });
  });

  it('closes modal on successful import', async () => {
    mockOnImport.mockResolvedValue({ created: 1, total: 1 });
    render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

    const textarea = screen.getByPlaceholderText(/paste domains/i);
    await userEvent.type(textarea, 'google.com');

    const importButton = screen.getByRole('button', { name: /import/i });
    fireEvent.click(importButton);

    await waitFor(() => {
      expect(mockOnClose).toHaveBeenCalled();
    });
  });

  it('shows error when all rules already exist', async () => {
    mockOnImport.mockResolvedValue({ created: 0, total: 2 });
    render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

    const textarea = screen.getByPlaceholderText(/paste domains/i);
    await userEvent.type(textarea, 'google.com\nyoutube.com');

    const importButton = screen.getByRole('button', { name: /import/i });
    fireEvent.click(importButton);

    await waitFor(() => {
      expect(screen.getByText('All rules already exist')).toBeInTheDocument();
    });

    // Modal should NOT close
    expect(mockOnClose).not.toHaveBeenCalled();
  });

  it('calls onClose when cancel button is clicked', () => {
    render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

    const cancelButton = screen.getByRole('button', { name: /cancel/i });
    fireEvent.click(cancelButton);

    expect(mockOnClose).toHaveBeenCalled();
  });

  it('shows count in import button', async () => {
    render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

    const textarea = screen.getByPlaceholderText(/paste domains/i);
    await userEvent.type(textarea, 'google.com\nyoutube.com\nexample.org');

    const importButton = screen.getByRole('button', { name: /import \(3\)/i });
    expect(importButton).toBeInTheDocument();
  });

  describe('Drag and Drop', () => {
    const createMockFile = (content: string, name: string, type = 'text/plain'): File => {
      return new File([content], name, { type });
    };

    const createDragEvent = (files: File[]) => {
      const dataTransfer = {
        files,
        items: files.map((file) => ({ kind: 'file', type: file.type, getAsFile: () => file })),
        types: ['Files'],
      };
      return { dataTransfer };
    };

    it('shows drag hint text', () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      expect(screen.getByText(/Drag .txt or .csv files here/i)).toBeInTheDocument();
    });

    it('shows drag overlay when file is dragged over', () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      const dropZone = screen.getByTestId('drop-zone');
      const mockFile = createMockFile('google.com', 'domains.txt');

      fireEvent.dragEnter(dropZone, createDragEvent([mockFile]));

      expect(screen.getByTestId('drag-overlay')).toBeInTheDocument();
      expect(screen.getByText('Drop the file here')).toBeInTheDocument();
    });

    it('hides drag overlay when drag leaves', () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      const dropZone = screen.getByTestId('drop-zone');
      const mockFile = createMockFile('google.com', 'domains.txt');

      fireEvent.dragEnter(dropZone, createDragEvent([mockFile]));
      expect(screen.getByTestId('drag-overlay')).toBeInTheDocument();

      fireEvent.dragLeave(dropZone, createDragEvent([mockFile]));
      expect(screen.queryByTestId('drag-overlay')).not.toBeInTheDocument();
    });

    it('reads and displays content from dropped .txt file', async () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      const dropZone = screen.getByTestId('drop-zone');
      const fileContent = 'google.com\nyoutube.com\nexample.org';
      const mockFile = createMockFile(fileContent, 'domains.txt');

      fireEvent.drop(dropZone, createDragEvent([mockFile]));

      await waitFor(() => {
        expect(screen.getByText('3 valid')).toBeInTheDocument();
      });
    });

    it('reads and displays content from dropped .csv file', async () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      const dropZone = screen.getByTestId('drop-zone');
      const fileContent = 'google.com,youtube.com,example.org';
      const mockFile = createMockFile(fileContent, 'domains.csv', 'text/csv');

      fireEvent.drop(dropZone, createDragEvent([mockFile]));

      await waitFor(() => {
        expect(screen.getByText('3 valid')).toBeInTheDocument();
      });
    });

    it('reads and displays content from dropped .list file', async () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      const dropZone = screen.getByTestId('drop-zone');
      const fileContent = 'google.com\nyoutube.com';
      const mockFile = createMockFile(fileContent, 'domains.list', 'application/octet-stream');

      fireEvent.drop(dropZone, createDragEvent([mockFile]));

      await waitFor(() => {
        expect(screen.getByText('2 valid')).toBeInTheDocument();
      });
    });

    it('appends dropped file content to existing text', async () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      // First type some domains
      const textarea = screen.getByPlaceholderText(/paste domains/i);
      await userEvent.type(textarea, 'existing.com');
      expect(screen.getByText('1 valid')).toBeInTheDocument();

      // Then drop a file
      const dropZone = screen.getByTestId('drop-zone');
      const fileContent = 'google.com\nyoutube.com';
      const mockFile = createMockFile(fileContent, 'domains.txt');

      fireEvent.drop(dropZone, createDragEvent([mockFile]));

      await waitFor(() => {
        expect(screen.getByText('3 valid')).toBeInTheDocument();
      });
    });

    it('handles multiple dropped files', async () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      const dropZone = screen.getByTestId('drop-zone');
      const file1 = createMockFile('google.com\nyoutube.com', 'file1.txt');
      const file2 = createMockFile('example.org\ntest.com', 'file2.txt');

      fireEvent.drop(dropZone, createDragEvent([file1, file2]));

      await waitFor(() => {
        expect(screen.getByText('4 valid')).toBeInTheDocument();
      });
    });

    it('shows error for invalid file types', async () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      const dropZone = screen.getByTestId('drop-zone');
      const mockFile = new File(['binary content'], 'image.png', { type: 'image/png' });

      fireEvent.drop(dropZone, createDragEvent([mockFile]));

      await waitFor(() => {
        expect(
          screen.getByText('Only text files are allowed (.txt, .csv, .list)')
        ).toBeInTheDocument();
      });
    });

    it('filters comments from dropped file content', async () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      const dropZone = screen.getByTestId('drop-zone');
      const fileContent = '# Comment line\ngoogle.com\n# Another comment\nyoutube.com';
      const mockFile = createMockFile(fileContent, 'domains.txt');

      fireEvent.drop(dropZone, createDragEvent([mockFile]));

      await waitFor(() => {
        expect(screen.getByText('2 valid')).toBeInTheDocument();
      });
    });

    it('removes duplicates from dropped file content', async () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      const dropZone = screen.getByTestId('drop-zone');
      const fileContent = 'google.com\ngoogle.com\nyoutube.com';
      const mockFile = createMockFile(fileContent, 'domains.txt');

      fireEvent.drop(dropZone, createDragEvent([mockFile]));

      await waitFor(() => {
        expect(screen.getByText('2 valid')).toBeInTheDocument();
      });
    });

    it('hides overlay after drop', () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      const dropZone = screen.getByTestId('drop-zone');
      const mockFile = createMockFile('google.com', 'domains.txt');

      // Show overlay
      fireEvent.dragEnter(dropZone, createDragEvent([mockFile]));
      expect(screen.getByTestId('drag-overlay')).toBeInTheDocument();

      // Drop file
      fireEvent.drop(dropZone, createDragEvent([mockFile]));

      // Overlay should be hidden
      expect(screen.queryByTestId('drag-overlay')).not.toBeInTheDocument();
    });
  });

  describe('Validation', () => {
    it('shows validation errors for invalid domain formats', async () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      const textarea = screen.getByPlaceholderText(/paste domains/i);
      // "not-a-domain" has no dot, CSV parser's cleanValue filters it out entirely
      // "x" also filtered out by cleanValue. Use values that pass CSV parsing but fail domain validation.
      await userEvent.type(textarea, 'google.com\n!!!.invalid\n-bad.com');

      // google.com is valid, !!!.invalid and -bad.com are invalid format
      expect(screen.getByText('1 valid')).toBeInTheDocument();
      expect(screen.getByText('2 invalid')).toBeInTheDocument();
      expect(screen.getByTestId('validation-errors')).toBeInTheDocument();
    });

    it('shows singular text for single invalid value', async () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      const textarea = screen.getByPlaceholderText(/paste domains/i);
      await userEvent.type(textarea, 'google.com\n!!!.bad');

      expect(screen.getByText('1 valid')).toBeInTheDocument();
      expect(screen.getByText('1 invalid')).toBeInTheDocument();
    });

    it('does not show validation errors when all values are valid', async () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      const textarea = screen.getByPlaceholderText(/paste domains/i);
      await userEvent.type(textarea, 'google.com\nyoutube.com');

      expect(screen.getByText('2 valid')).toBeInTheDocument();
      expect(screen.queryByTestId('validation-errors')).not.toBeInTheDocument();
    });

    it('disables import button when all values are invalid', async () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      const textarea = screen.getByPlaceholderText(/paste domains/i);
      await userEvent.type(textarea, '!!!.invalid\n-bad-.com');

      const importButton = screen.getByRole('button', { name: /import/i });
      expect(importButton).toBeDisabled();
    });

    it('only imports valid values, skipping invalid ones', async () => {
      mockOnImport.mockResolvedValue({ created: 1, total: 1 });
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      const textarea = screen.getByPlaceholderText(/paste domains/i);
      await userEvent.type(textarea, 'google.com\n!!!.invalid');

      const importButton = screen.getByRole('button', { name: /import/i });
      fireEvent.click(importButton);

      await waitFor(() => {
        // Only valid domain should be passed to onImport
        expect(mockOnImport).toHaveBeenCalledWith(['google.com'], 'whitelist');
      });
    });

    it('re-validates when rule type changes', async () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      const textarea = screen.getByPlaceholderText(/paste domains/i);
      // *.example.com is invalid as whitelist domain but valid as subdomain pattern
      await userEvent.type(textarea, '*.example.com');

      // Default type is whitelist - wildcard not valid for domain
      expect(screen.getByTestId('validation-errors')).toBeInTheDocument();

      // Switch to blocked_subdomain - wildcard is valid
      const blockedOption = screen.getByText('Blocked subdomains');
      fireEvent.click(blockedOption);

      expect(screen.queryByTestId('validation-errors')).not.toBeInTheDocument();
      expect(screen.getByText('1 valid')).toBeInTheDocument();
    });

    it('validates paths correctly with blocked_path type', async () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      // Select blocked_path type
      const pathOption = screen.getByText('Blocked paths');
      fireEvent.click(pathOption);

      const textarea = screen.getByPlaceholderText(/paste paths/i);
      await userEvent.type(textarea, 'example.com/ads\n*/tracking/*');

      expect(screen.getByText('2 valid')).toBeInTheDocument();
      expect(screen.queryByTestId('validation-errors')).not.toBeInTheDocument();
    });

    it('shows import button count with only valid values', async () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      const textarea = screen.getByPlaceholderText(/paste domains/i);
      await userEvent.type(textarea, 'google.com\n!!!.invalid\nyoutube.com');

      // Button should show count of valid values only (2, not 3)
      const importButton = screen.getByRole('button', { name: /import \(2\)/i });
      expect(importButton).toBeInTheDocument();
    });

    it('shows specific error message for each invalid value', async () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      const textarea = screen.getByPlaceholderText(/paste domains/i);
      await userEvent.type(textarea, 'google.com\n!!!.bad');

      // The invalid value should be shown in the error list
      const errorsPanel = screen.getByTestId('validation-errors');
      expect(errorsPanel).toHaveTextContent('!!!.bad');
    });

    it('shows "only valid will be imported" message when mixed', async () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      const textarea = screen.getByPlaceholderText(/paste domains/i);
      await userEvent.type(textarea, 'google.com\n!!!.bad');

      expect(screen.getByText(/Only the 1 valid value will be imported/i)).toBeInTheDocument();
    });

    it('disables import and shows errors when only invalid values present', async () => {
      render(<BulkImportModal isOpen={true} onClose={mockOnClose} onImport={mockOnImport} />);

      const textarea = screen.getByPlaceholderText(/paste domains/i);
      await userEvent.type(textarea, '!!!.invalid');

      // Validation errors panel is visible
      expect(screen.getByTestId('validation-errors')).toBeInTheDocument();
      // Import button is disabled
      const importButton = screen.getByRole('button', { name: /import/i });
      expect(importButton).toBeDisabled();
      // Shows 0 valid count
      expect(screen.getByText('0 valid')).toBeInTheDocument();
    });
  });
});
