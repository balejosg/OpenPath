import { sanitizeSlug } from '@openpath/shared/slug';
import { sql } from 'drizzle-orm';

import { db } from '../src/db/index.js';
import { classrooms } from '../src/db/schema.js';

export const CANONICAL_GROUP_IDS = {
  default: 'default',
  groupA: 'group-a',
  groupB: 'group-b',
  groupC: 'group-c',
  groupDb: 'group-db',
  groupZ: 'group-z',
  group1: 'group1',
  testGroup: 'test-group',
  ciencias3Eso: 'ciencias-3eso',
  matematicas4Eso: 'matematicas-4eso',
  fisica4Eso: 'fisica-4eso',
  googleLinked: 'google-linked-group',
} as const;

export const BASELINE_GROUP_FIXTURES = [
  {
    id: CANONICAL_GROUP_IDS.default,
    name: CANONICAL_GROUP_IDS.default,
    displayName: 'Default Group',
  },
  { id: CANONICAL_GROUP_IDS.groupA, name: CANONICAL_GROUP_IDS.groupA, displayName: 'Group A' },
  { id: CANONICAL_GROUP_IDS.groupB, name: CANONICAL_GROUP_IDS.groupB, displayName: 'Group B' },
  { id: CANONICAL_GROUP_IDS.groupC, name: CANONICAL_GROUP_IDS.groupC, displayName: 'Group C' },
  {
    id: CANONICAL_GROUP_IDS.groupDb,
    name: CANONICAL_GROUP_IDS.groupDb,
    displayName: 'Group DB',
  },
  { id: CANONICAL_GROUP_IDS.groupZ, name: CANONICAL_GROUP_IDS.groupZ, displayName: 'Group Z' },
  { id: CANONICAL_GROUP_IDS.group1, name: CANONICAL_GROUP_IDS.group1, displayName: 'Group 1' },
  {
    id: CANONICAL_GROUP_IDS.testGroup,
    name: CANONICAL_GROUP_IDS.testGroup,
    displayName: 'Test Group',
  },
  {
    id: CANONICAL_GROUP_IDS.ciencias3Eso,
    name: CANONICAL_GROUP_IDS.ciencias3Eso,
    displayName: 'Ciencias 3 ESO',
  },
  {
    id: CANONICAL_GROUP_IDS.matematicas4Eso,
    name: CANONICAL_GROUP_IDS.matematicas4Eso,
    displayName: 'Matematicas 4 ESO',
  },
  {
    id: CANONICAL_GROUP_IDS.fisica4Eso,
    name: CANONICAL_GROUP_IDS.fisica4Eso,
    displayName: 'Fisica 4 ESO',
  },
  {
    id: CANONICAL_GROUP_IDS.googleLinked,
    name: CANONICAL_GROUP_IDS.googleLinked,
    displayName: 'Google Linked Group',
  },
] as const;

export function createFixtureId(prefix: string): string {
  return `${prefix}-${Date.now().toString()}-${Math.random().toString(36).slice(2, 8)}`;
}

export async function ensureWhitelistGroup(
  groupId: string,
  options: { name?: string; displayName?: string; enabled?: boolean } = {}
): Promise<void> {
  const name = options.name ?? groupId;
  const displayName = options.displayName ?? groupId;
  const enabled = options.enabled ?? true;

  await db.execute(sql`
    DELETE FROM whitelist_groups
    WHERE id = ${groupId} OR name = ${name}
  `);

  await db.execute(sql`
    INSERT INTO whitelist_groups (id, name, display_name, enabled)
    VALUES (${groupId}, ${name}, ${displayName}, ${enabled ? 1 : 0})
  `);
}

export async function seedBaselineWhitelistGroups(): Promise<void> {
  for (const fixture of BASELINE_GROUP_FIXTURES) {
    await ensureWhitelistGroup(fixture.id, fixture);
  }
}

export async function createFixtureClassroom(options: {
  name: string;
  groupId?: string | null;
  displayName?: string;
  id?: string;
  captivePortalDomains?: string[];
}): Promise<string> {
  const {
    name,
    groupId = null,
    displayName = name,
    id = createFixtureId('classroom'),
    captivePortalDomains = [],
  } = options;

  if (groupId !== null) {
    await ensureWhitelistGroup(groupId);
  }

  await db.insert(classrooms).values({
    id,
    name: sanitizeSlug(name, { maxLength: 100, allowUnderscore: true }),
    displayName,
    defaultGroupId: groupId,
    activeGroupId: groupId,
    captivePortalDomains,
  });

  return id;
}
