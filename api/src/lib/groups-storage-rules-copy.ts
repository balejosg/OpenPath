import { v4 as uuidv4 } from 'uuid';
import { eq } from 'drizzle-orm';
import { db, whitelistRules } from '../db/index.js';
import type { DbExecutor } from '../db/index.js';

export async function copyRulesToGroup(
  params: {
    fromGroupId: string;
    toGroupId: string;
  },
  executor: DbExecutor = db
): Promise<number> {
  const source = await executor
    .select()
    .from(whitelistRules)
    .where(eq(whitelistRules.groupId, params.fromGroupId));

  if (source.length === 0) return 0;

  const batchSize = 500;
  let inserted = 0;
  for (let index = 0; index < source.length; index += batchSize) {
    const batch = source.slice(index, index + batchSize).map((rule) => ({
      id: uuidv4(),
      groupId: params.toGroupId,
      type: rule.type,
      value: rule.value,
      comment: rule.comment ?? null,
    }));

    await executor.insert(whitelistRules).values(batch);
    inserted += batch.length;
  }

  return inserted;
}
