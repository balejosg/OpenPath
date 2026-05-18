import { render, screen, fireEvent } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { GroupSelect } from '../GroupSelect';

describe('GroupSelect', () => {
  it('includes a none option by default', () => {
    render(
      <GroupSelect
        id="g"
        value=""
        onChange={() => undefined}
        groups={[{ id: 'g1', name: 'n1', displayName: 'Grupo 1', enabled: true }]}
      />
    );

    expect(screen.getByRole('option', { name: 'No group' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'Grupo 1' })).toBeInTheDocument();
  });

  it('injects an unknown selected value when not present in groups', () => {
    render(
      <GroupSelect
        id="g"
        value="unknown"
        onChange={() => undefined}
        groups={[{ id: 'g1', name: 'n1', displayName: 'Grupo 1', enabled: true }]}
        unknownValueLabel="Aplicado por otro profesor"
      />
    );

    expect(screen.getByRole('option', { name: 'Aplicado por otro profesor' })).toBeInTheDocument();
  });

  it('hides inactive groups when inactiveBehavior=hide', () => {
    render(
      <GroupSelect
        id="g"
        value=""
        onChange={() => undefined}
        inactiveBehavior="hide"
        groups={[
          { id: 'g1', name: 'n1', displayName: 'Active', enabled: true },
          { id: 'g2', name: 'n2', displayName: 'Inactive', enabled: false },
        ]}
      />
    );

    expect(screen.getByRole('option', { name: 'Active' })).toBeInTheDocument();
    expect(screen.queryByRole('option', { name: /Inactive/ })).not.toBeInTheDocument();
  });

  it('disables inactive groups when inactiveBehavior=disable', () => {
    render(
      <GroupSelect
        id="g"
        value=""
        onChange={() => undefined}
        inactiveBehavior="disable"
        groups={[
          { id: 'g1', name: 'n1', displayName: 'Active', enabled: true },
          { id: 'g2', name: 'n2', displayName: 'Inactive', enabled: false },
        ]}
      />
    );

    const inactive = screen.getByRole('option', { name: 'Inactive (Inactive)' });
    expect(inactive).toBeDisabled();
  });

  it('calls onChange with the new value', () => {
    const onChange = vi.fn();
    render(
      <GroupSelect
        id="g"
        value=""
        onChange={onChange}
        groups={[{ id: 'g1', name: 'n1', displayName: 'Grupo 1', enabled: true }]}
      />
    );

    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'g1' } });
    expect(onChange).toHaveBeenCalledWith('g1');
  });
});
