/**
 * CSV Parser utility for bulk rule import.
 * Handles various CSV formats with automatic header detection.
 */
import type { ProductT } from '../i18n/product-i18n';

export interface CSVParseResult {
  /** Successfully parsed values */
  values: string[];
  /** Detected format */
  format: 'csv-with-headers' | 'csv-simple' | 'plain-text';
  /** Header row if detected */
  headers?: string[];
  /** Column used for values */
  valueColumn?: string;
  /** Total rows processed */
  totalRows: number;
  /** Rows skipped (empty, comments, invalid) */
  skippedRows: number;
  /** Parse warnings */
  warnings: string[];
}

export interface CSVParseOptions {
  /** Preferred column names to look for (case-insensitive) */
  preferredColumns?: string[];
  /** Delimiter to use (auto-detect if not specified) */
  delimiter?: ',' | ';' | '\t';
  /** Skip rows starting with this character */
  commentChar?: string;
  /** Optional translate fn for user-facing warning messages */
  t?: ProductT;
}

const DEFAULT_PREFERRED_COLUMNS = [
  'domain',
  'domains',
  'dominio',
  'dominios',
  'url',
  'urls',
  'host',
  'hostname',
  'site',
  'value',
  'name',
  'address',
];

/**
 * Detect the delimiter used in a CSV string.
 */
function detectDelimiter(content: string): ',' | ';' | '\t' {
  const firstLine = content.split('\n')[0] || '';

  // Count occurrences of each potential delimiter
  const counts = {
    ',': (firstLine.match(/,/g) ?? []).length,
    ';': (firstLine.match(/;/g) ?? []).length,
    '\t': (firstLine.match(/\t/g) ?? []).length,
  };

  // Return the most common delimiter, defaulting to comma
  if (counts[';'] > counts[','] && counts[';'] > counts['\t']) return ';';
  if (counts['\t'] > counts[','] && counts['\t'] > counts[';']) return '\t';
  return ',';
}

/**
 * Parse a CSV line respecting quoted fields.
 */
function parseCSVLine(line: string, delimiter: string): string[] {
  const result: string[] = [];
  let current = '';
  let inQuotes = false;

  for (let i = 0; i < line.length; i++) {
    const char = line[i];
    const nextChar = line[i + 1];

    if (char === '"') {
      if (inQuotes && nextChar === '"') {
        // Escaped quote
        current += '"';
        i++;
      } else {
        // Toggle quote mode
        inQuotes = !inQuotes;
      }
    } else if (char === delimiter && !inQuotes) {
      result.push(current.trim());
      current = '';
    } else {
      current += char;
    }
  }

  // Add last field
  result.push(current.trim());

  return result;
}

/**
 * Check if a row looks like a header row.
 */
function isLikelyHeaderRow(fields: string[], preferredColumns: string[]): boolean {
  const lowerFields = fields.map((f) => f.toLowerCase().replace(/['"]/g, ''));

  // Check if any field matches known column names
  for (const field of lowerFields) {
    if (preferredColumns.includes(field)) {
      return true;
    }
  }

  // Check if fields look like headers (no dots, no protocol)
  const looksLikeData = fields.some((f) => f.includes('.') || f.includes('://') || /^\d+$/.test(f));

  return !looksLikeData;
}

/**
 * Find the best column to use for domain values.
 */
function findValueColumn(headers: string[], preferredColumns: string[]): number {
  const lowerHeaders = headers.map((h) => h.toLowerCase().replace(/['"]/g, ''));

  // First, look for preferred column names
  for (const preferred of preferredColumns) {
    const index = lowerHeaders.indexOf(preferred);
    if (index !== -1) {
      return index;
    }
  }

  // Default to first column
  return 0;
}

/**
 * Clean and validate a domain/URL value.
 */
function cleanValue(value: string): string | null {
  let cleaned = value.trim();

  // Remove quotes
  cleaned = cleaned.replace(/^["']|["']$/g, '');

  // Skip empty values
  if (!cleaned) return null;

  // Skip obvious non-domain values
  if (/^(#|\/\/|true|false|null|undefined|\d+)$/i.exec(cleaned) !== null) {
    return null;
  }

  // Remove protocol if present
  cleaned = cleaned.replace(/^https?:\/\//i, '');

  // Remove trailing slashes and paths for simple domains
  // But keep paths for blocked_path type rules
  cleaned = cleaned.replace(/\/+$/, '');

  // Basic validation: should have at least one dot or be a path
  if (!cleaned.includes('.') && !cleaned.includes('/')) {
    return null;
  }

  return cleaned;
}

/**
 * Parse CSV or plain text content into domain values.
 */
export function parseCSV(content: string, options: CSVParseOptions = {}): CSVParseResult {
  const {
    preferredColumns = DEFAULT_PREFERRED_COLUMNS,
    delimiter: explicitDelimiter,
    commentChar = '#',
    t,
  } = options;

  const warnings: string[] = [];
  const lines = content.split(/\r?\n/).filter((line) => line.trim());

  if (lines.length === 0) {
    return {
      values: [],
      format: 'plain-text',
      totalRows: 0,
      skippedRows: 0,
      warnings: [t ? t('csvParser.fileEmpty') : 'The file is empty'],
    };
  }

  // Detect delimiter
  const delimiter = explicitDelimiter ?? detectDelimiter(content);

  // Parse first line to check for headers
  const firstLineFields = parseCSVLine(lines[0], delimiter);
  const hasMultipleColumns = firstLineFields.length > 1;

  // Determine if this looks like a CSV with headers
  let format: CSVParseResult['format'];
  let headers: string[] | undefined;
  let valueColumnIndex = 0;
  let dataStartIndex = 0;

  if (hasMultipleColumns) {
    const looksLikeHeader = isLikelyHeaderRow(firstLineFields, preferredColumns);

    if (looksLikeHeader) {
      format = 'csv-with-headers';
      headers = firstLineFields;
      valueColumnIndex = findValueColumn(headers, preferredColumns);
      dataStartIndex = 1;

      if (headers.length > 3) {
        warnings.push(
          `CSV tiene ${String(headers.length)} columnas. Usando columna "${headers[valueColumnIndex]}".`
        );
      }
    } else {
      format = 'csv-simple';
      valueColumnIndex = 0;
      dataStartIndex = 0;
    }
  } else {
    format = 'plain-text';
  }

  // Parse values
  const values: string[] = [];
  let skippedRows = 0;

  for (let i = dataStartIndex; i < lines.length; i++) {
    const line = lines[i].trim();

    // Skip comments
    if (line.startsWith(commentChar)) {
      skippedRows++;
      continue;
    }

    // Parse the line
    if (format === 'plain-text') {
      const cleaned = cleanValue(line);
      if (cleaned) {
        values.push(cleaned);
      } else {
        skippedRows++;
      }
    } else if (format === 'csv-simple') {
      // For simple CSV (no headers), treat ALL columns as values
      const fields = parseCSVLine(line, delimiter);
      let addedAny = false;
      for (const field of fields) {
        const cleaned = cleanValue(field);
        if (cleaned) {
          values.push(cleaned);
          addedAny = true;
        }
      }
      if (!addedAny) {
        skippedRows++;
      }
    } else {
      // For CSV with headers, use only the value column
      const fields = parseCSVLine(line, delimiter);
      const value = fields[valueColumnIndex] || '';
      const cleaned = cleanValue(value);
      if (cleaned) {
        values.push(cleaned);
      } else {
        skippedRows++;
      }
    }
  }

  // Remove duplicates
  const uniqueValues = [...new Set(values)];
  const duplicatesRemoved = values.length - uniqueValues.length;

  if (duplicatesRemoved > 0) {
    warnings.push(`${String(duplicatesRemoved)} duplicates removed.`);
  }

  return {
    values: uniqueValues,
    format,
    headers,
    valueColumn: headers?.[valueColumnIndex],
    totalRows: lines.length - (headers ? 1 : 0),
    skippedRows,
    warnings,
  };
}

/**
 * Check if content appears to be CSV format.
 */
export function isCSVContent(content: string): boolean {
  const firstLine = content.split('\n')[0] || '';
  const delimiter = detectDelimiter(content);
  const fields = parseCSVLine(firstLine, delimiter);

  return fields.length > 1;
}
