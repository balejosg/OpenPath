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

export interface TransactionalDomainEventWriter<TTx> {
  write<TResult>(
    operation: (tx: TTx, collector: DomainEventCollector) => Promise<TResult>
  ): Promise<TResult>;
}

export function createTransactionalWriter<TTx>(
  options: TransactionalDomainEventWriterOptions<TTx>
): TransactionalDomainEventWriter<TTx> {
  const dispatcher = options.dispatcher ?? createDispatcher(options.publishers);

  return {
    async write<TResult>(
      operation: (tx: TTx, collector: DomainEventCollector) => Promise<TResult>
    ): Promise<TResult> {
      const { collector, flush } = createCollector(dispatcher);
      const result = await options.transactionRunner((tx) => operation(tx, collector));
      flush();
      return result;
    },
  };
}
