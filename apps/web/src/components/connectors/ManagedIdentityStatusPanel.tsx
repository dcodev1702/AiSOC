'use client';

import useSWR from 'swr';
import { clsx } from 'clsx';

import { connectorsApi, type ManagedIdentityStatus, type SentinelManagedIdentityStatus } from '@/lib/api';

const CONNECTION_COPY: Record<
  SentinelManagedIdentityStatus['connection_status'],
  { label: string; detail: string; tone: string; dot: string }
> = {
  connected: {
    label: 'Connected with managed identity',
    detail: 'The latest read-only Sentinel and Log Analytics probe passed.',
    tone: 'text-emerald-200 bg-emerald-500/10 border-emerald-500/30',
    dot: 'bg-emerald-400',
  },
  verification_pending: {
    label: 'Managed identity verification pending',
    detail: 'The connector is saved but has not completed a live access test yet.',
    tone: 'text-amber-200 bg-amber-500/10 border-amber-500/30',
    dot: 'bg-amber-400',
  },
  error: {
    label: 'Managed identity connection failed',
    detail: 'The last live Sentinel access test failed. Review connector health before relying on it.',
    tone: 'text-red-200 bg-red-500/10 border-red-500/30',
    dot: 'bg-red-400',
  },
  legacy_credentials: {
    label: 'Legacy credential connector detected',
    detail: 'Replace this connector with managed identity to remove the stored client secret.',
    tone: 'text-amber-200 bg-amber-500/10 border-amber-500/30',
    dot: 'bg-amber-400',
  },
  not_configured: {
    label: 'Managed identity ready — connector not saved',
    detail: 'Add Microsoft Sentinel and choose Managed identity; no client secret is required.',
    tone: 'text-blue-200 bg-blue-500/10 border-blue-500/30',
    dot: 'bg-blue-400',
  },
};

function shortId(value: string): string {
  if (value.length <= 18) return value;
  return `${value.slice(0, 8)}…${value.slice(-6)}`;
}

function IdentityCard({
  title,
  identity,
}: {
  title: string;
  identity: ManagedIdentityStatus;
}) {
  return (
    <div className="rounded-lg border border-gray-800 bg-gray-950/40 p-3">
      <div className="flex items-start justify-between gap-2">
        <div>
          <p className="text-[10px] uppercase tracking-wider text-gray-500">{title}</p>
          <p className="mt-1 text-sm font-medium text-gray-200">{identity.name || 'Not configured'}</p>
        </div>
        <span
          className={clsx(
            'rounded-full border px-2 py-0.5 text-[10px]',
            identity.configured
              ? 'border-emerald-500/30 bg-emerald-500/10 text-emerald-300'
              : 'border-gray-700 bg-gray-800 text-gray-400',
          )}
        >
          {identity.configured ? 'Assigned' : 'Missing'}
        </span>
      </div>
      {identity.client_id && (
        <p className="mt-2 font-mono text-[10px] text-gray-500" title={identity.client_id}>
          Client ID {shortId(identity.client_id)}
        </p>
      )}
      <div className="mt-2 flex flex-wrap gap-1.5">
        {identity.roles.map((role) => (
          <span
            key={`${role.name}:${role.scope}`}
            title={`${role.name} at ${role.scope} · assigned by ${role.assignment_source}`}
            className="rounded-full border border-blue-500/30 bg-blue-500/10 px-2 py-0.5 text-[10px] text-blue-200"
          >
            {role.name}
          </span>
        ))}
      </div>
    </div>
  );
}

export function ManagedIdentityStatusDetails({
  status,
  compact = false,
}: {
  status: SentinelManagedIdentityStatus;
  compact?: boolean;
}) {
  const connection = CONNECTION_COPY[status.connection_status];
  return (
    <section className="rounded-xl border border-gray-800/80 bg-gray-900/50 p-4" aria-label="Sentinel managed identity status">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="flex items-center gap-2">
            <span className={clsx('h-2 w-2 rounded-full', connection.dot)} />
            <h2 className="text-sm font-semibold text-gray-100">{connection.label}</h2>
          </div>
          <p className="mt-1 text-xs text-gray-500">{connection.detail}</p>
        </div>
        <div className="text-right">
          <p className="text-[10px] uppercase tracking-wider text-gray-600">Sentinel workspace</p>
          <p className="mt-0.5 text-xs font-medium text-gray-300">
            {status.workspace.resource_group} / {status.workspace.name}
          </p>
        </div>
      </div>

      <div className={clsx('mt-3 grid gap-3', compact ? 'grid-cols-1' : 'md:grid-cols-2')}>
        <IdentityCard title="Read / poll identity" identity={status.reader_identity} />
        <IdentityCard title="Governed writeback identity" identity={status.responder_identity} />
      </div>

      <div className={clsx('mt-3 rounded-lg border px-3 py-2 text-xs', connection.tone)}>
        {status.connector ? (
          <>
            Connector <span className="font-medium">{status.connector.name}</span> uses{' '}
            <span className="font-mono">{status.connector.auth_mode}</span>.
            {status.connector.last_verified_at && (
              <> Last verified {new Date(status.connector.last_verified_at).toLocaleString()}.</>
            )}
          </>
        ) : (
          <>The deployment identities are assigned; save the Sentinel connector to begin live polling.</>
        )}
      </div>
      <p className="mt-2 text-[10px] text-gray-600">
        Roles and scope come from the Terraform deployment. Connection status comes from the live Sentinel access test.
      </p>
    </section>
  );
}

export function ManagedIdentityStatusPanel({ compact = false }: { compact?: boolean }) {
  const { data, error, isLoading } = useSWR(
    'connectors:managed-identity-status',
    connectorsApi.managedIdentityStatus,
    { revalidateOnFocus: false, refreshInterval: 60_000 },
  );

  if (isLoading) {
    return <div className="h-32 animate-pulse rounded-xl border border-gray-800 bg-gray-900/40" />;
  }
  if (error || !data) {
    return (
      <div className="rounded-xl border border-amber-500/20 bg-amber-500/5 p-3 text-xs text-amber-200">
        Managed identity status could not be loaded. Treat the Sentinel authentication state as unknown.
      </div>
    );
  }
  if (!data.deployment_configured && data.connection_status === 'not_configured') return null;
  return <ManagedIdentityStatusDetails status={data} compact={compact} />;
}
