import React from 'react';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import {
  OpenPathI18nProvider,
  productI18nCatalogs,
  resolveProductLocale,
  translateProductText,
  useT,
} from '../product-i18n';

function Probe() {
  const t = useT();
  return <div>{t('sidebar.nav.settings')}</div>;
}

describe('product i18n', () => {
  it('defaults unsupported browser locales to English and accepts language regions', () => {
    expect(resolveProductLocale('fr-FR')).toBe('en');
    expect(resolveProductLocale('es-ES')).toBe('es');
    expect(resolveProductLocale(['de-DE', 'en-US'])).toBe('en');
  });

  it('keeps English and Spanish catalogs in key parity', () => {
    expect(Object.keys(productI18nCatalogs.es).sort()).toEqual(
      Object.keys(productI18nCatalogs.en).sort()
    );
  });

  it('fails loudly when a catalog key is missing', () => {
    expect(() => translateProductText('en', 'missing.key')).toThrow(/Missing OpenPath i18n key/);
  });

  it('provides translated labels from context', () => {
    render(
      <OpenPathI18nProvider locale="es">
        <Probe />
      </OpenPathI18nProvider>
    );

    expect(screen.getByText('Configuración')).toBeInTheDocument();
  });

  it('covers dashboard and classroom visible copy in the product catalog', () => {
    expect(translateProductText('es', 'dashboard.status.secure')).toBe(
      'Estado del sistema: seguro'
    );
    expect(translateProductText('en', 'classrooms.list.title')).toBe('Classrooms');
    expect(translateProductText('es', 'classrooms.dialog.deleteSchedule.title')).toBe(
      'Eliminar horario'
    );
  });

  it('keeps target dashboard and classroom files free of migrated visible literals', () => {
    const repoRoot = resolve(__dirname, '../..');
    const targetSources = [
      'views/Dashboard.tsx',
      'views/Classrooms.tsx',
      'components/classrooms/ClassroomListPane.tsx',
      'components/classrooms/ClassroomDetailPane.tsx',
      'components/classrooms/NewClassroomModal.tsx',
    ]
      .map((relativePath) => readFileSync(resolve(repoRoot, relativePath), 'utf8'))
      .join('\n');

    for (const migratedLiteral of [
      'System Status: Secure',
      'New Classroom',
      'Search classroom...',
      'No classrooms found',
      'Create a classroom to view its settings and status.',
      'Delete Schedule',
    ]) {
      expect(targetSources).not.toContain(migratedLiteral);
    }
  });

  it('keeps remaining audited OpenPath UI files catalog-backed and locale-aware', () => {
    const repoRoot = resolve(__dirname, '../..');
    const auditedSources = [
      'components/teacher/TeacherTodayFocusPanel.tsx',
      'components/teacher/TeacherDashboardCalendar.tsx',
      'components/teacher/TeacherScheduleDetailPanel.tsx',
      'components/domain-requests/DomainRequestsFilters.tsx',
      'components/domain-requests/DomainRequestsTable.tsx',
      'components/domain-requests/DomainRequestsDialogs.tsx',
      'components/classrooms/ClassroomScheduleCard.tsx',
      'components/classrooms/ClassroomMachinesCard.tsx',
      'components/RulesTable.tsx',
      'components/weekly-calendar/useWeeklyCalendarLayout.ts',
      'views/Settings.tsx',
    ]
      .map((relativePath) => readFileSync(resolve(repoRoot, relativePath), 'utf8'))
      .join('\n');

    expect(auditedSources).not.toContain("'es-ES'");
    expect(auditedSources).not.toContain('"es-ES"');

    for (const migratedLiteral of [
      'Loading your schedule...',
      "Today's schedule",
      'Schedule details',
      'Search by domain or machine...',
      'Limpiar busqueda',
      'Mas nuevas',
      'All clear',
      'Approve requests',
      'Classroom Schedule',
      'Registered Machines',
      'No active machines',
      'Administra tus preferencias esenciales',
      'Coming soon',
    ]) {
      expect(auditedSources).not.toContain(migratedLiteral);
    }
  });
});
