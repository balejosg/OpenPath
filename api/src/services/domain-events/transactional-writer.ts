import { createCollector } from './collector.js';
import { createDispatcher } from './dispatcher.js';
import type {
  DomainEventCollector,
  DomainEventDispatcher,
  DomainEventPublishers,
} from './types.js';

export interface TransactionalDomainEventWriterOptions<TTx> {
  dispatcher?: DomainEventDispatcher;
  publishers?: DomainEventPublishers;
  transactionRunner: <TResult>(operation: (tx: TTx) => Promise<TResult>) => Promise<TResult>;
}

export type TransactionalDomainEventCommandOptions<TTx> =
  TransactionalDomainEventWriterOptions<TTx>;

export interface TransactionalDomainEventWriter<TTx> {
  write<TResult>(
    operation: (tx: TTx, collector: DomainEventCollector) => Promise<TResult>
  ): Promise<TResult>;
}

export async function writeTransactionalCommand<TTx, TResult>(
  options: TransactionalDomainEventCommandOptions<TTx>,
  operation: (tx: TTx, collector: DomainEventCollector) => Promise<TResult>
): Promise<TResult> {
  const dispatcher = options.dispatcher ?? createDispatcher(options.publishers);
  const { collector, flush } = createCollector(dispatcher);
  const result = await options.transactionRunner((tx) => operation(tx, collector));
  flush();
  return result;
}

export function createTransactionalWriter<TTx>(
  options: TransactionalDomainEventWriterOptions<TTx>
): TransactionalDomainEventWriter<TTx> {
  return {
    async write<TResult>(
      operation: (tx: TTx, collector: DomainEventCollector) => Promise<TResult>
    ): Promise<TResult> {
      return writeTransactionalCommand(options, operation);
    },
  };
}
