import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { screen, fireEvent, waitFor } from '@testing-library/react';
import Dashboard from '../Dashboard';
import { renderWithQueryClient } from '../../test-utils/query';

let queryClient: ReturnType<typeof renderWithQueryClient>['queryClient'] | null = null;

function renderDashboard(props?: React.ComponentProps<typeof Dashboard>) {
  const rendered = renderWithQueryClient(<Dashboard {...props} />);
  queryClient = rendered.queryClient;
  return rendered;
}

afterEach(() => {
  queryClient?.clear();
  queryClient = null;
});

// Mock trpc
const mockStatsQuery = vi.fn();
const mockRequestsStatsQuery = vi.fn();
const mockSystemStatusQuery = vi.fn();
const mockGroupsListQuery = vi.fn();
const mockClassroomsListQuery = vi.fn();

vi.mock('../../lib/trpc', () => ({
  trpc: {
    groups: {
      stats: { query: (): unknown => mockStatsQuery() },
      list: { query: (): unknown => mockGroupsListQuery() },
      systemStatus: { query: (): unknown => mockSystemStatusQuery() },
    },
    classrooms: {
      list: { query: (): unknown => mockClassroomsListQuery() },
    },
    requests: {
      stats: { query: (): unknown => mockRequestsStatsQuery() },
    },
  },
}));

describe('Dashboard', () => {
  const mockGroups = [
    {
      id: 'group-1',
      name: 'primaria',
      displayName: 'Grupo Primaria',
      enabled: true,
      whitelistCount: 45,
      blockedSubdomainCount: 5,
      blockedPathCount: 3,
      createdAt: '2024-01-15T10:00:00Z',
      updatedAt: '2024-01-20T10:00:00Z',
    },
    {
      id: 'group-2',
      name: 'secundaria',
      displayName: 'Grupo Secundaria',
      enabled: true,
      whitelistCount: 32,
      blockedSubdomainCount: 2,
      blockedPathCount: 1,
      createdAt: '2024-01-10T10:00:00Z',
      updatedAt: '2024-01-18T10:00:00Z',
    },
    {
      id: 'group-3',
      name: 'profesores',
      displayName: 'Teacheres',
      enabled: false,
      whitelistCount: 12,
      blockedSubdomainCount: 0,
      blockedPathCount: 0,
      createdAt: '2024-01-05T10:00:00Z',
      updatedAt: '2024-01-05T10:00:00Z',
    },
  ];

  const mockStats = {
    groupCount: 3,
    whitelistCount: 89,
    blockedCount: 11,
  };

  const mockRequestStats = {
    pending: 5,
  };

  const mockSystemStatus = {
    enabled: true,
    totalGroups: 3,
    activeGroups: 2,
    pausedGroups: 1,
  };

  const mockClassrooms = [
    {
      id: 'classroom-1',
      name: 'Laboratorio A',
      displayName: 'Laboratorio A',
      defaultGroupId: 'group-1',
      activeGroupId: null,
      currentGroupId: 'group-1',
      currentGroupSource: 'default',
    },
    {
      id: 'classroom-2',
      name: 'Aula 2',
      displayName: 'Aula 2',
      defaultGroupId: null,
      activeGroupId: null,
      currentGroupId: null,
      currentGroupSource: 'none',
    },
  ];

  beforeEach(() => {
    vi.clearAllMocks();
    mockStatsQuery.mockResolvedValue(mockStats);
    mockRequestsStatsQuery.mockResolvedValue(mockRequestStats);
    mockSystemStatusQuery.mockResolvedValue(mockSystemStatus);
    mockGroupsListQuery.mockResolvedValue(mockGroups);
    mockClassroomsListQuery.mockResolvedValue(mockClassrooms);
  });

  it('renders stats cards', async () => {
    renderDashboard();

    await waitFor(() => {
      expect(screen.getByText('Active Groups')).toBeInTheDocument();
      expect(screen.getByText('Allowed Domains')).toBeInTheDocument();
      expect(screen.getByText('Sitios Bloqueados')).toBeInTheDocument();
      expect(screen.getByText('Pending Requests')).toBeInTheDocument();
    });
  });

  it('renders system status banner', async () => {
    renderDashboard();

    await waitFor(() => {
      expect(screen.getByText('System Status: Secure')).toBeInTheDocument();
    });
  });

  it('shows disabled system status when not enabled', async () => {
    mockSystemStatusQuery.mockResolvedValue({
      enabled: false,
      totalGroups: 3,
      activeGroups: 0,
      pausedGroups: 3,
    });

    renderDashboard();

    await waitFor(() => {
      expect(screen.getByText('System Status: No groups enabled')).toBeInTheDocument();
    });
  });

  it('renders active groups by classroom in the banner', async () => {
    renderDashboard();

    await waitFor(() => {
      expect(screen.getByText('Active group by classroom')).toBeInTheDocument();
      expect(screen.getByText('Laboratorio A')).toBeInTheDocument();
      expect(screen.getByText(/Grupo Primaria/)).toBeInTheDocument();
    });
  });

  it('calls onNavigateToClassroom when a classroom entry in the banner is clicked', async () => {
    const onNavigateToClassroom = vi.fn();

    renderDashboard({ onNavigateToClassroom });

    await waitFor(() => {
      expect(screen.getByTestId('dashboard-classroom-classroom-1')).toBeInTheDocument();
    });

    fireEvent.click(screen.getByTestId('dashboard-classroom-classroom-1'));

    expect(onNavigateToClassroom).toHaveBeenCalledWith({
      id: 'classroom-1',
      name: 'Laboratorio A',
    });
  });

  it('renders quick access section when onNavigateToRules is provided', async () => {
    const onNavigateToRules = vi.fn();

    renderDashboard({ onNavigateToRules });

    await waitFor(() => {
      expect(screen.getByText('Quick Access')).toBeInTheDocument();
    });
  });

  it('does not render quick access section when onNavigateToRules is not provided', async () => {
    renderDashboard();

    await waitFor(() => {
      expect(screen.getByText('Active Groups')).toBeInTheDocument();
    });

    expect(screen.queryByText('Quick Access')).not.toBeInTheDocument();
  });

  it('renders group cards in quick access section', async () => {
    const onNavigateToRules = vi.fn();

    renderDashboard({ onNavigateToRules });

    await waitFor(() => {
      expect(screen.getByText('Grupo Primaria')).toBeInTheDocument();
      expect(screen.getByText('Grupo Secundaria')).toBeInTheDocument();
      expect(screen.getByText('Teacheres')).toBeInTheDocument();
    });
  });

  it('shows allowed and blocked counts for each group', async () => {
    const onNavigateToRules = vi.fn();

    renderDashboard({ onNavigateToRules });

    await waitFor(() => {
      // Group 1: 45 allowed, 8 blocked (5+3)
      expect(screen.getByText('45')).toBeInTheDocument();
      expect(screen.getByText('8')).toBeInTheDocument();
    });
  });

  it('calls onNavigateToRules when manage button is clicked', async () => {
    const onNavigateToRules = vi.fn();

    renderDashboard({ onNavigateToRules });

    await waitFor(() => {
      expect(screen.getByTestId('manage-rules-group-1')).toBeInTheDocument();
    });

    fireEvent.click(screen.getByTestId('manage-rules-group-1'));

    expect(onNavigateToRules).toHaveBeenCalledWith({
      id: 'group-1',
      name: 'Grupo Primaria',
    });
  });

  it('shows inactive groups with opacity styling', async () => {
    const onNavigateToRules = vi.fn();

    renderDashboard({ onNavigateToRules });

    await waitFor(() => {
      const inactiveCard = screen.getByTestId('group-card-group-3');
      expect(inactiveCard).toHaveClass('opacity-60');
    });
  });

  it('shows active groups without opacity styling', async () => {
    const onNavigateToRules = vi.fn();

    renderDashboard({ onNavigateToRules });

    await waitFor(() => {
      const activeCard = screen.getByTestId('group-card-group-1');
      expect(activeCard).not.toHaveClass('opacity-60');
    });
  });

  it('shows Active badge for enabled groups', async () => {
    const onNavigateToRules = vi.fn();

    renderDashboard({ onNavigateToRules });

    await waitFor(() => {
      const activeBadges = screen.getAllByText('Active');
      expect(activeBadges.length).toBe(2);
    });
  });

  it('shows Inactive badge for disabled groups', async () => {
    const onNavigateToRules = vi.fn();

    renderDashboard({ onNavigateToRules });

    await waitFor(() => {
      expect(screen.getByText('Inactive')).toBeInTheDocument();
    });
  });

  it('limits displayed groups to 6 maximum', async () => {
    const manyGroups = Array.from({ length: 10 }, (_, i) => ({
      id: `group-${String(i)}`,
      name: `group-${String(i)}`,
      displayName: `Group ${String(i)}`,
      enabled: true,
      whitelistCount: 10,
      blockedSubdomainCount: 2,
      blockedPathCount: 1,
      createdAt: '2024-01-15T10:00:00Z',
      updatedAt: '2024-01-15T10:00:00Z',
    }));

    mockGroupsListQuery.mockResolvedValue(manyGroups);

    const onNavigateToRules = vi.fn();

    renderDashboard({ onNavigateToRules });

    await waitFor(() => {
      const grid = screen.getByTestId('quick-access-grid');
      // Should only show 6 cards
      expect(grid.children.length).toBe(6);
    });
  });

  it('shows "view all" message when there are more than 6 groups', async () => {
    const manyGroups = Array.from({ length: 10 }, (_, i) => ({
      id: `group-${String(i)}`,
      name: `group-${String(i)}`,
      displayName: `Group ${String(i)}`,
      enabled: true,
      whitelistCount: 10,
      blockedSubdomainCount: 2,
      blockedPathCount: 1,
      createdAt: '2024-01-15T10:00:00Z',
      updatedAt: '2024-01-15T10:00:00Z',
    }));

    mockGroupsListQuery.mockResolvedValue(manyGroups);

    const onNavigateToRules = vi.fn();

    renderDashboard({ onNavigateToRules });

    await waitFor(() => {
      expect(screen.getByText(/Showing 6 of 10 groups/)).toBeInTheDocument();
    });
  });

  it('does not show "view all" message when there are 6 or fewer groups', async () => {
    const onNavigateToRules = vi.fn();

    renderDashboard({ onNavigateToRules });

    await waitFor(() => {
      expect(screen.getByText('Grupo Primaria')).toBeInTheDocument();
    });

    expect(screen.queryByText(/Mostrando/)).not.toBeInTheDocument();
  });

  it('shows empty state when no groups exist', async () => {
    mockGroupsListQuery.mockResolvedValue([]);

    const onNavigateToRules = vi.fn();

    renderDashboard({ onNavigateToRules });

    await waitFor(() => {
      expect(screen.getByText('No groups configured.')).toBeInTheDocument();
    });
  });

  it('shows loading state for groups', async () => {
    // Never resolve the promise
    mockGroupsListQuery.mockImplementation(
      () =>
        new Promise<never>(() => {
          /* intentionally empty */
        })
    );

    const onNavigateToRules = vi.fn();

    renderDashboard({ onNavigateToRules });

    expect(screen.getByText('Loading groups...')).toBeInTheDocument();

    // Flush other async effects (stats/classrooms) to avoid act warnings.
    await waitFor(() => {
      expect(screen.queryByText('Loading stats...')).not.toBeInTheDocument();
      expect(screen.queryByText('Loading classrooms...')).not.toBeInTheDocument();
    });
  });

  it('refreshes pending requests count when the window regains focus', async () => {
    mockRequestsStatsQuery
      .mockResolvedValueOnce({ pending: 5 })
      .mockResolvedValueOnce({ pending: 7 });

    renderDashboard();

    await waitFor(() => {
      expect(screen.getByText('5')).toBeInTheDocument();
    });

    fireEvent(window, new Event('focus'));

    await waitFor(() => {
      expect(screen.getByText('7')).toBeInTheDocument();
    });
  });

  it('shows error state when groups fail to load', async () => {
    mockGroupsListQuery.mockRejectedValue(new Error('Network error'));

    const onNavigateToRules = vi.fn();

    renderDashboard({ onNavigateToRules });

    await waitFor(() => {
      expect(screen.getByText('Unable to load groups')).toBeInTheDocument();
    });

    // Flush other async effects (stats/classrooms) to avoid act warnings.
    await waitFor(() => {
      expect(screen.queryByText('Loading stats...')).not.toBeInTheDocument();
      expect(screen.queryByText('Loading classrooms...')).not.toBeInTheDocument();
    });
  });

  describe('Sort functionality', () => {
    it('renders sort dropdown button', async () => {
      const onNavigateToRules = vi.fn();

      renderDashboard({ onNavigateToRules });

      await waitFor(() => {
        expect(screen.getByTestId('sort-dropdown-button')).toBeInTheDocument();
      });
    });

    it('shows sort options when dropdown is clicked', async () => {
      const onNavigateToRules = vi.fn();

      renderDashboard({ onNavigateToRules });

      await waitFor(() => {
        expect(screen.getByTestId('sort-dropdown-button')).toBeInTheDocument();
      });

      fireEvent.click(screen.getByTestId('sort-dropdown-button'));

      expect(screen.getByTestId('sort-dropdown-menu')).toBeInTheDocument();
      expect(screen.getByTestId('sort-option-name')).toBeInTheDocument();
      expect(screen.getByTestId('sort-option-rules')).toBeInTheDocument();
      expect(screen.getByTestId('sort-option-recent')).toBeInTheDocument();
    });

    it('sorts by name (A-Z) by default', async () => {
      const onNavigateToRules = vi.fn();

      renderDashboard({ onNavigateToRules });

      await waitFor(() => {
        expect(screen.getByText(/Nombre \(A-Z\)/)).toBeInTheDocument();
      });
    });

    it('changes sort order when option is selected', async () => {
      const onNavigateToRules = vi.fn();

      renderDashboard({ onNavigateToRules });

      await waitFor(() => {
        expect(screen.getByTestId('sort-dropdown-button')).toBeInTheDocument();
      });

      fireEvent.click(screen.getByTestId('sort-dropdown-button'));
      fireEvent.click(screen.getByTestId('sort-option-rules'));

      await waitFor(() => {
        expect(screen.getByText(/Most rules/)).toBeInTheDocument();
      });
    });

    it('sorts by rules count descending when "Most rules" is selected', async () => {
      const onNavigateToRules = vi.fn();

      renderDashboard({ onNavigateToRules });

      await waitFor(() => {
        expect(screen.getByTestId('sort-dropdown-button')).toBeInTheDocument();
      });

      fireEvent.click(screen.getByTestId('sort-dropdown-button'));
      fireEvent.click(screen.getByTestId('sort-option-rules'));

      await waitFor(() => {
        const grid = screen.getByTestId('quick-access-grid');
        const firstCard = grid.children[0];
        // Group Primaria has most rules (45+5+3=53)
        expect(firstCard).toHaveAttribute('data-testid', 'group-card-group-1');
      });
    });
  });
});
