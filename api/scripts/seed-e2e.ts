#!/usr/bin/env npx tsx
/**
 * OpenPath - E2E Test Database Seed
 *
 * Creates test users for E2E testing.
 * Run with: npm run db:seed:e2e
 */

import { drizzle } from 'drizzle-orm/node-postgres';
import { eq } from 'drizzle-orm';
import pg from 'pg';
import bcrypt from 'bcrypt';
import { randomUUID } from 'crypto';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { users, roles, whitelistGroups, whitelistRules } from '../src/db/schema.js';

const { Pool } = pg;

// Test users matching react-spa/e2e/fixtures/test-utils.ts
export const TEST_USERS = [
  {
    email: 'admin@openpath.local',
    name: 'Admin User',
    password: 'AdminPassword123!',
    role: 'admin',
  },
  {
    email: 'teacher@openpath.local',
    name: 'Teacher User',
    password: 'TeacherPassword123!',
    role: 'teacher',
  },
  {
    email: 'student@openpath.local',
    name: 'Student User',
    password: 'StudentPassword123!',
    role: 'student',
  },
];

// Test group
export const TEST_GROUP = {
  id: 'test-e2e-group',
  name: 'test-e2e-group',
  displayName: 'E2E Test Group',
};

export async function seedE2E(): Promise<void> {
  console.log('🌱 Starting E2E database seed...\n');

  const pool = new Pool({
    host: process.env.DB_HOST ?? 'localhost',
    port: parseInt(process.env.DB_PORT ?? '5433', 10),
    database: process.env.DB_NAME ?? 'openpath_test',
    user: process.env.DB_USER ?? 'openpath',
    password: process.env.DB_PASSWORD ?? 'openpath_test',
  });

  const db = drizzle(pool);

  try {
    // Create test group
    console.log('Creating test group...');
    await db
      .insert(whitelistGroups)
      .values({
        id: TEST_GROUP.id,
        name: TEST_GROUP.name,
        displayName: TEST_GROUP.displayName,
      })
      .onConflictDoNothing();

    // Create at least one rule so Rules Manager renders a table on a clean DB
    console.log('Creating baseline whitelist rule...');
    await db
      .insert(whitelistRules)
      .values({
        id: 'test-e2e-rule-1',
        groupId: TEST_GROUP.id,
        type: 'whitelist',
        value: 'seeded-inline-edit.example.com',
        comment: 'E2E seed: baseline rule for UI table rendering',
      })
      .onConflictDoNothing();

    // Create test users
    for (const user of TEST_USERS) {
      console.log(`Creating user: ${user.email}`);

      const userId = randomUUID();
      const passwordHash = await bcrypt.hash(user.password, 10);

      // Check if user exists
      const existing = await db.select().from(users).where(eq(users.email, user.email)).limit(1);

      let finalUserId = userId;

      if (existing.length === 0) {
        // Insert new user
        await db.insert(users).values({
          id: userId,
          email: user.email.trim(),
          name: user.name,
          passwordHash,
          isActive: true,
          emailVerified: true,
        });
      } else {
        const existingUser = existing[0];
        if (!existingUser) {
          throw new Error(`Failed to find existing user ${user.email}`);
        }
        finalUserId = existingUser.id as `${string}-${string}-${string}-${string}-${string}`;
        // Update password hash to ensure it matches
        await db
          .update(users)
          .set({ passwordHash, isActive: true, emailVerified: true })
          .where(eq(users.id, finalUserId));
        console.log(`  Updated existing user ${user.email}`);
      }

      // Check if role exists
      const existingRole = await db
        .select()
        .from(roles)
        .where(eq(roles.userId, finalUserId))
        .limit(1);

      if (existingRole.length === 0) {
        // Insert role
        await db.insert(roles).values({
          id: randomUUID(),
          userId: finalUserId,
          role: user.role,
          groupIds: user.role === 'admin' ? null : [TEST_GROUP.id],
        });
      }
    }

    console.log('\n✅ E2E seed complete!');
    console.log('\nTest accounts:');
    for (const user of TEST_USERS) {
      console.log(`  ${user.role}: ${user.email} / ${user.password}`);
    }
  } catch (error) {
    console.error('❌ Seed failed:', error);
    process.exit(1);
  } finally {
    await pool.end();
  }
}

const isMainModule =
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;

if (isMainModule) {
  seedE2E().catch((error: unknown) => {
    console.error('Seed failed:', error);
    process.exit(1);
  });
}
