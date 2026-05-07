import { runScheduleBoundaryTickOnce } from '../lib/rule-events.js';
import { createCollector } from './domain-events/collector.js';
import { createDispatcher } from './domain-events/dispatcher.js';
import {
  createTransactionalWriter,
  writeTransactionalCommand,
} from './domain-events/transactional-writer.js';
import type {
  DbDomainTransactionRunner,
  DomainEventCollector,
  DomainEventDispatcher,
} from './domain-events/types.js';

export type {
  DomainEvent,
  DomainEventCollector,
  DomainEventDispatcher,
  DomainEventPublishers,
} from './domain-events/types.js';
export type {
  TransactionalDomainEventWriter,
  TransactionalDomainEventCommandOptions,
  TransactionalDomainEventWriterOptions,
} from './domain-events/transactional-writer.js';

const defaultDispatcher = createDispatcher();

export { createDispatcher };
export { createTransactionalWriter };
export { writeTransactionalCommand };

export function publishWhitelistChanged(groupId: string): void {
  defaultDispatcher.publish({ type: 'whitelist.changed', groupId });
}

export function publishAllWhitelistsChanged(): void {
  defaultDispatcher.publish({ type: 'whitelists.allChanged' });
}

export function publishClassroomChanged(classroomId: string, now?: Date): void {
  defaultDispatcher.publish(
    now === undefined
      ? { type: 'classroom.changed', classroomId }
      : { type: 'classroom.changed', classroomId, now }
  );
}

export async function withQueuedEvents<T>(
  operation: (collector: DomainEventCollector) => Promise<T>,
  dispatcher: DomainEventDispatcher = defaultDispatcher
): Promise<T> {
  const { collector, flush } = createCollector(dispatcher);
  const result = await operation(collector);
  flush();
  return result;
}

export async function withTransactionEvents<TTx, TResult>(
  transactionRunner: (operation: (tx: TTx) => Promise<TResult>) => Promise<TResult>,
  operation: (tx: TTx, collector: DomainEventCollector) => Promise<TResult>,
  dispatcher: DomainEventDispatcher = defaultDispatcher
): Promise<TResult> {
  const { collector, flush } = createCollector(dispatcher);
  const result = await transactionRunner((tx) => operation(tx, collector));
  flush();
  return result;
}

export async function withDbTransactionEvents<TResult>(
  transactionRunner: DbDomainTransactionRunner<TResult>,
  operation: (
    tx: import('../db/index.js').DbExecutor,
    collector: DomainEventCollector
  ) => Promise<TResult>,
  dispatcher: DomainEventDispatcher = defaultDispatcher
): Promise<TResult> {
  return withTransactionEvents(transactionRunner, operation, dispatcher);
}

export async function tickScheduleBoundaryEvents(now: Date): Promise<void> {
  await runScheduleBoundaryTickOnce(now);
}

export default {
  createDispatcher,
  createTransactionalWriter,
  writeTransactionalCommand,
  publishWhitelistChanged,
  publishAllWhitelistsChanged,
  publishClassroomChanged,
  tickScheduleBoundaryEvents,
  withDbTransactionEvents,
  withQueuedEvents,
  withTransactionEvents,
};
