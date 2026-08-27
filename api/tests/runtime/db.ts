import { sql } from 'drizzle-orm';

import { db } from '../../src/db/index.js';
import { seedBaselineWhitelistGroups } from '../fixtures.js';
import { ensureCanonicalGroupForeignKeys, ensureTestSchema } from './schema.js';

export async function resetDb(): Promise<void> {
  await ensureTestSchema();

  const tables = [
    'users',
    'roles',
    'tokens',
    'classrooms',
    'schedules',
    'machine_exemptions',
    'requests',
    'machines',
    'settings',
    'whitelist_groups',
    'whitelist_rules',
    'email_verification_tokens',
    'windows_offline_download_transfer_leases',
    'windows_offline_download_refs',
  ];

  for (const table of tables) {
    await db.execute(sql.raw(`TRUNCATE TABLE "${table}" CASCADE`));
  }

  await ensureCanonicalGroupForeignKeys();

  await db.execute(
    sql.raw(`
        INSERT INTO users (id, email, name, password_hash)
        VALUES ('legacy_admin', 'admin@openpath.dev', 'Legacy Admin', 'placeholder')
        ON CONFLICT (id) DO NOTHING
    `)
  );

  await seedBaselineWhitelistGroups();
}
