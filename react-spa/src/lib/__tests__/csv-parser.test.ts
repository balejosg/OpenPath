import { describe, it, expect } from 'vitest';
import { parseCSV, isCSVContent } from '../csv-parser';

describe('CSV Parser', () => {
  describe('parseCSV', () => {
    describe('plain text format', () => {
      it('parses simple domain list', () => {
        const input = `google.com
youtube.com
github.com`;

        const result = parseCSV(input);

        expect(result.format).toBe('plain-text');
        expect(result.values).toEqual(['google.com', 'youtube.com', 'github.com']);
        expect(result.totalRows).toBe(3);
        expect(result.skippedRows).toBe(0);
      });

      it('skips empty lines and comments', () => {
        const input = `google.com

# This is a comment
youtube.com
   
github.com`;

        const result = parseCSV(input);

        expect(result.values).toEqual(['google.com', 'youtube.com', 'github.com']);
        expect(result.skippedRows).toBe(1); // comment line
      });

      it('removes duplicates', () => {
        const input = `google.com
youtube.com
google.com
github.com
youtube.com`;

        const result = parseCSV(input);

        expect(result.values).toEqual(['google.com', 'youtube.com', 'github.com']);
        expect(result.warnings).toContainEqual(expect.stringContaining('duplicates removed'));
      });

      it('handles empty input', () => {
        const result = parseCSV('');

        expect(result.values).toEqual([]);
        expect(result.totalRows).toBe(0);
        expect(result.warnings).toContainEqual(expect.stringContaining('empty'));
      });
    });

    describe('CSV with headers', () => {
      it('detects domain column header', () => {
        const input = `domain,type,comment
google.com,whitelist,Search engine
youtube.com,whitelist,Video platform
github.com,whitelist,Code hosting`;

        const result = parseCSV(input);

        expect(result.format).toBe('csv-with-headers');
        expect(result.headers).toEqual(['domain', 'type', 'comment']);
        expect(result.valueColumn).toBe('domain');
        expect(result.values).toEqual(['google.com', 'youtube.com', 'github.com']);
      });

      it('detects url column header', () => {
        const input = `id,url,description
1,google.com,Search
2,youtube.com,Video
3,github.com,Code`;

        const result = parseCSV(input);

        expect(result.format).toBe('csv-with-headers');
        expect(result.valueColumn).toBe('url');
        expect(result.values).toEqual(['google.com', 'youtube.com', 'github.com']);
      });

      it('detects Spanish column headers', () => {
        const input = `dominio,tipo,comentario
google.com,permitido,Buscador
youtube.com,permitido,Videos`;

        const result = parseCSV(input);

        expect(result.format).toBe('csv-with-headers');
        expect(result.valueColumn).toBe('dominio');
        expect(result.values).toEqual(['google.com', 'youtube.com']);
      });

      it('handles quoted fields', () => {
        const input = `domain,description
"google.com","Google Search, Inc."
"youtube.com","Video platform"`;

        const result = parseCSV(input);

        expect(result.values).toEqual(['google.com', 'youtube.com']);
      });

      it('handles semicolon delimiter', () => {
        const input = `domain;type;comment
google.com;whitelist;Search
youtube.com;whitelist;Video`;

        const result = parseCSV(input);

        expect(result.format).toBe('csv-with-headers');
        expect(result.values).toEqual(['google.com', 'youtube.com']);
      });

      it('handles tab delimiter', () => {
        const input = `domain\ttype\tcomment
google.com\twhitelist\tSearch
youtube.com\twhitelist\tVideo`;

        const result = parseCSV(input);

        expect(result.format).toBe('csv-with-headers');
        expect(result.values).toEqual(['google.com', 'youtube.com']);
      });

      it('falls back to first column when no known header found', () => {
        const input = `site,category,notes
google.com,search,main
youtube.com,video,streaming`;

        const result = parseCSV(input);

        // 'site' is in preferred columnas list
        expect(result.valueColumn).toBe('site');
        expect(result.values).toEqual(['google.com', 'youtube.com']);
      });
    });

    describe('CSV without headers', () => {
      it('parses simple CSV without headers', () => {
        const input = `google.com,whitelist,comment
youtube.com,whitelist,comment`;

        const result = parseCSV(input);

        expect(result.format).toBe('csv-simple');
        expect(result.headers).toBeUndefined();
        expect(result.values).toEqual(['google.com', 'youtube.com']);
      });
    });

    describe('value cleaning', () => {
      it('removes protocol from URLs', () => {
        const input = `https://google.com
http://youtube.com
github.com`;

        const result = parseCSV(input);

        expect(result.values).toEqual(['google.com', 'youtube.com', 'github.com']);
      });

      it('removes trailing slashes', () => {
        const input = `google.com/
youtube.com//
github.com`;

        const result = parseCSV(input);

        expect(result.values).toEqual(['google.com', 'youtube.com', 'github.com']);
      });

      it('skips invalid values', () => {
        const input = `google.com
invalid
123
true
youtube.com`;

        const result = parseCSV(input);

        expect(result.values).toEqual(['google.com', 'youtube.com']);
        expect(result.skippedRows).toBe(3);
      });

      it('keeps paths for blocked_path rules', () => {
        const input = `facebook.com/gaming
youtube.com/shorts
twitter.com/explore`;

        const result = parseCSV(input);

        expect(result.values).toEqual([
          'facebook.com/gaming',
          'youtube.com/shorts',
          'twitter.com/explore',
        ]);
      });
    });

    describe('edge cases', () => {
      it('handles Windows line endings', () => {
        const input = 'google.com\r\nyoutube.com\r\ngithub.com';

        const result = parseCSV(input);

        expect(result.values).toEqual(['google.com', 'youtube.com', 'github.com']);
      });

      it('handles mixed line endings', () => {
        const input = 'google.com\nyoutube.com\r\ngithub.com';

        const result = parseCSV(input);

        expect(result.values).toContain('google.com');
        expect(result.values).toContain('youtube.com');
        expect(result.values).toContain('github.com');
      });

      it('handles CSV with many columnas and shows warning', () => {
        const input = `id,domain,type,created,modified,user,status,priority
1,google.com,whitelist,2024-01-01,2024-01-02,admin,active,high
2,youtube.com,whitelist,2024-01-01,2024-01-02,admin,active,high`;

        const result = parseCSV(input);

        expect(result.values).toEqual(['google.com', 'youtube.com']);
        expect(result.warnings).toContainEqual(expect.stringContaining('columnas'));
      });

      it('handles escaped quotes in CSV', () => {
        const input = `domain,description
"google.com","Search ""engine"""
"youtube.com","Video site"`;

        const result = parseCSV(input);

        expect(result.values).toEqual(['google.com', 'youtube.com']);
      });
    });
  });

  describe('isCSVContent', () => {
    it('returns true for CSV content', () => {
      expect(isCSVContent('domain,type,comment')).toBe(true);
      expect(isCSVContent('domain;type;comment')).toBe(true);
      expect(isCSVContent('domain\ttype\tcomment')).toBe(true);
    });

    it('returns false for plain text', () => {
      expect(isCSVContent('google.com')).toBe(false);
      expect(isCSVContent('google.com\nyoutube.com')).toBe(false);
    });
  });
});
