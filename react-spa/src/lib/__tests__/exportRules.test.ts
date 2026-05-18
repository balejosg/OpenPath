import { describe, it, expect } from 'vitest';
import { rulesToCSV, rulesToJSON, rulesToText, buildExportFilename } from '../exportRules';
import type { Rule } from '../../components/RulesTable';

const mockRules: Rule[] = [
  {
    id: '1',
    groupId: 'group-1',
    value: 'google.com',
    type: 'whitelist',
    comment: null,
    createdAt: '2026-01-15T10:00:00Z',
  },
  {
    id: '2',
    groupId: 'group-1',
    value: 'ads.example.com',
    type: 'blocked_subdomain',
    comment: null,
    createdAt: '2026-01-16T10:00:00Z',
  },
  {
    id: '3',
    groupId: 'group-1',
    value: '/tracking/*',
    type: 'blocked_path',
    comment: null,
    createdAt: '2026-01-17T10:00:00Z',
  },
];

describe('exportRules utilities', () => {
  describe('rulesToCSV', () => {
    it('generates correct CSV header', () => {
      const csv = rulesToCSV([]);
      expect(csv).toBe('value,type,type_label,created_at');
    });

    it('generates CSV with rules', () => {
      const csv = rulesToCSV(mockRules);
      const lines = csv.split('\n');

      expect(lines).toHaveLength(4); // header + 3 rules
      expect(lines[0]).toBe('value,type,type_label,created_at');
      expect(lines[1]).toBe('google.com,whitelist,Allowed,2026-01-15T10:00:00Z');
      expect(lines[2]).toBe(
        'ads.example.com,blocked_subdomain,Blocked subdomain,2026-01-16T10:00:00Z'
      );
      expect(lines[3]).toBe('/tracking/*,blocked_path,Blocked path,2026-01-17T10:00:00Z');
    });

    it('escapes fields with commas', () => {
      const rulesWithComma: Rule[] = [
        {
          id: '1',
          groupId: 'group-1',
          value: 'example,with,commas.com',
          type: 'whitelist',
          comment: null,
          createdAt: '2026-01-15T10:00:00Z',
        },
      ];

      const csv = rulesToCSV(rulesWithComma);
      const lines = csv.split('\n');

      expect(lines[1]).toContain('"example,with,commas.com"');
    });

    it('escapes fields with quotes', () => {
      const rulesWithQuotes: Rule[] = [
        {
          id: '1',
          groupId: 'group-1',
          value: 'example"quoted".com',
          type: 'whitelist',
          comment: null,
          createdAt: '2026-01-15T10:00:00Z',
        },
      ];

      const csv = rulesToCSV(rulesWithQuotes);
      const lines = csv.split('\n');

      expect(lines[1]).toContain('"example""quoted"".com"');
    });
  });

  describe('rulesToJSON', () => {
    it('generates valid JSON', () => {
      const json = rulesToJSON(mockRules);
      const parsed = JSON.parse(json) as unknown[];

      expect(parsed).toBeInstanceOf(Array);
      expect(parsed).toHaveLength(3);
    });

    it('includes all required fields', () => {
      const json = rulesToJSON(mockRules);
      const parsed = JSON.parse(json) as {
        value: string;
        type: string;
        typeLabel: string;
        createdAt: string;
      }[];

      expect(parsed[0]).toEqual({
        value: 'google.com',
        type: 'whitelist',
        typeLabel: 'Allowed',
        createdAt: '2026-01-15T10:00:00Z',
      });
    });

    it('handles empty array', () => {
      const json = rulesToJSON([]);
      const parsed = JSON.parse(json) as unknown[];

      expect(parsed).toEqual([]);
    });

    it('uses human-readable type labels', () => {
      const json = rulesToJSON(mockRules);
      const parsed = JSON.parse(json) as { typeLabel: string }[];

      expect(parsed[0].typeLabel).toBe('Allowed');
      expect(parsed[1].typeLabel).toBe('Blocked subdomain');
      expect(parsed[2].typeLabel).toBe('Blocked path');
    });
  });

  describe('rulesToText', () => {
    it('generates plain list without grouping', () => {
      const text = rulesToText(mockRules, false);
      const lines = text.split('\n');

      expect(lines).toHaveLength(3);
      expect(lines[0]).toBe('google.com');
      expect(lines[1]).toBe('ads.example.com');
      expect(lines[2]).toBe('/tracking/*');
    });

    it('generates grouped format with sections', () => {
      const text = rulesToText(mockRules, true);

      expect(text).toContain('## WHITELIST');
      expect(text).toContain('google.com');
      expect(text).toContain('## BLOCKED-SUBDOMAINS');
      expect(text).toContain('ads.example.com');
      expect(text).toContain('## BLOCKED-PATHS');
      expect(text).toContain('/tracking/*');
    });

    it('omits empty sections in grouped format', () => {
      const whitelistOnly: Rule[] = [
        {
          id: '1',
          groupId: 'group-1',
          value: 'google.com',
          type: 'whitelist',
          comment: null,
          createdAt: '2026-01-15T10:00:00Z',
        },
      ];

      const text = rulesToText(whitelistOnly, true);

      expect(text).toContain('## WHITELIST');
      expect(text).not.toContain('## BLOCKED-SUBDOMAINS');
      expect(text).not.toContain('## BLOCKED-PATHS');
    });

    it('handles empty array', () => {
      const text = rulesToText([], false);
      expect(text).toBe('');
    });
  });

  describe('buildExportFilename', () => {
    it('appends the correct extension and sanitizes the basename', () => {
      const filename = buildExportFilename({
        format: 'csv',
        filename: 'Grupo de prueba admin para validar flujo Aulas/Políticas.-rules',
        dateStamp: '2026-02-27',
      });

      expect(filename).toBe('grupo-de-prueba-admin-para-validar-flujo-aulas-politicas-rules.csv');
    });

    it('does not duplicate the extension if it is already present', () => {
      const filename = buildExportFilename({
        format: 'json',
        filename: 'mis-reglas.json',
        dateStamp: '2026-02-27',
      });

      expect(filename).toBe('mis-reglas.json');
    });

    it('falls back to default filename when basename is empty after sanitization', () => {
      const filename = buildExportFilename({
        format: 'txt',
        filename: '!!!',
        dateStamp: '2026-02-27',
      });

      expect(filename).toBe('rules-2026-02-27.txt');
    });
  });
});
