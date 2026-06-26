import { useEffect, useState } from 'react';
import type { Dispatch, SetStateAction } from 'react';
import type { DomainRequest } from '@openpath/api';

import { useT } from '../i18n/product-i18n';

interface UseDomainRequestsBulkActionsOptions {
  requests: DomainRequest[];
  selectedPendingRequests: DomainRequest[];
  setSelectedRequestIds: Dispatch<SetStateAction<string[]>>;
  approveRequest: (id: string) => Promise<unknown>;
  rejectRequest: (input: { id: string; reason?: string }) => Promise<unknown>;
}

export function useDomainRequestsBulkActions({
  requests,
  selectedPendingRequests,
  setSelectedRequestIds,
  approveRequest,
  rejectRequest,
}: UseDomainRequestsBulkActionsOptions) {
  const t = useT();
  const [bulkRejectReason, setBulkRejectReason] = useState('');
  const [bulkLoading, setBulkLoading] = useState(false);
  const [bulkProgress, setBulkProgress] = useState<{
    mode: 'approve' | 'reject';
    done: number;
    total: number;
  } | null>(null);
  const [bulkMessage, setBulkMessage] = useState<string | null>(null);
  const [bulkFailedIds, setBulkFailedIds] = useState<string[]>([]);
  const [bulkFailedMode, setBulkFailedMode] = useState<'approve' | 'reject' | null>(null);
  const [bulkConfirm, setBulkConfirm] = useState<{
    mode: 'approve' | 'reject';
    requestIds: string[];
    rejectReason?: string;
  } | null>(null);

  useEffect(() => {
    if (!bulkMessage) return;
    const timeout = window.setTimeout(() => setBulkMessage(null), 4000);
    return () => window.clearTimeout(timeout);
  }, [bulkMessage]);

  const openBulkApproveConfirm = () => {
    if (selectedPendingRequests.length === 0) return;
    setBulkConfirm({
      mode: 'approve',
      requestIds: selectedPendingRequests.map((request) => request.id),
    });
  };

  const openBulkRejectConfirm = () => {
    if (selectedPendingRequests.length === 0) return;
    const reason = bulkRejectReason.trim();
    setBulkConfirm({
      mode: 'reject',
      requestIds: selectedPendingRequests.map((request) => request.id),
      rejectReason: reason ? reason : undefined,
    });
  };

  const runBulkApprove = async (requestIds: string[]) => {
    if (requestIds.length === 0) return;

    setBulkMessage(null);
    setBulkLoading(true);
    setBulkProgress({ mode: 'approve', done: 0, total: requestIds.length });
    let successCount = 0;
    let failedCount = 0;
    let processedCount = 0;
    const failedIds: string[] = [];

    for (const id of requestIds) {
      try {
        await approveRequest(id);
        successCount++;
      } catch {
        failedCount++;
        failedIds.push(id);
      }
      processedCount++;
      setBulkProgress({
        mode: 'approve',
        done: processedCount,
        total: requestIds.length,
      });
    }

    if (successCount > 0) {
      setSelectedRequestIds([]);
    }

    setBulkMessage(
      failedCount > 0
        ? t('domainRequests.bulk.approvedWithFailed', { successCount, failedCount })
        : t('domainRequests.bulk.approvedAll', { successCount })
    );
    setBulkFailedIds(failedIds);
    setBulkFailedMode(failedCount > 0 ? 'approve' : null);
    setBulkProgress(null);
    setBulkLoading(false);
  };

  const runBulkReject = async (requestIds: string[], reason?: string) => {
    if (requestIds.length === 0) return;

    setBulkMessage(null);
    setBulkLoading(true);
    setBulkProgress({ mode: 'reject', done: 0, total: requestIds.length });
    let successCount = 0;
    let failedCount = 0;
    let processedCount = 0;
    const failedIds: string[] = [];

    for (const id of requestIds) {
      try {
        await rejectRequest({ id, reason });
        successCount++;
      } catch {
        failedCount++;
        failedIds.push(id);
      }
      processedCount++;
      setBulkProgress({
        mode: 'reject',
        done: processedCount,
        total: requestIds.length,
      });
    }

    if (successCount > 0) {
      setSelectedRequestIds([]);
      setBulkRejectReason('');
    }

    setBulkMessage(
      failedCount > 0
        ? t('domainRequests.bulk.rejectedWithFailed', { successCount, failedCount })
        : t('domainRequests.bulk.rejectedAll', { successCount })
    );
    setBulkFailedIds(failedIds);
    setBulkFailedMode(failedCount > 0 ? 'reject' : null);
    setBulkProgress(null);
    setBulkLoading(false);
  };

  const handleRetryFailed = () => {
    if (bulkFailedIds.length === 0 || !bulkFailedMode) return;

    const retryCandidates = requests.filter(
      (request) => request.status === 'pending' && bulkFailedIds.includes(request.id)
    );
    if (retryCandidates.length === 0) {
      setBulkMessage(t('domainRequests.bulk.noFailedToRetry'));
      setBulkFailedIds([]);
      setBulkFailedMode(null);
      return;
    }

    setSelectedRequestIds(retryCandidates.map((request) => request.id));

    if (bulkFailedMode === 'approve') {
      setBulkConfirm({
        mode: 'approve',
        requestIds: retryCandidates.map((request) => request.id),
      });
      return;
    }

    const reason = bulkRejectReason.trim();
    setBulkConfirm({
      mode: 'reject',
      requestIds: retryCandidates.map((request) => request.id),
      rejectReason: reason ? reason : undefined,
    });
  };

  const clearBulkSelection = () => {
    setSelectedRequestIds([]);
    setBulkFailedIds([]);
    setBulkFailedMode(null);
    setBulkRejectReason('');
  };

  return {
    bulkRejectReason,
    setBulkRejectReason,
    bulkLoading,
    bulkProgress,
    bulkMessage,
    bulkFailedIds,
    bulkConfirm,
    setBulkConfirm,
    openBulkApproveConfirm,
    openBulkRejectConfirm,
    runBulkApprove,
    runBulkReject,
    handleRetryFailed,
    clearBulkSelection,
  };
}
