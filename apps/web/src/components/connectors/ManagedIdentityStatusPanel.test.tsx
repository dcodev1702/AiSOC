import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import { ManagedIdentityStatusDetails } from './ManagedIdentityStatusPanel';
import type { SentinelManagedIdentityStatus } from '@/lib/api';

const status: SentinelManagedIdentityStatus = {
  deployment_configured: true,
  connection_status: 'connected',
  workspace: {
    subscription_id: 'sentinel-sub',
    resource_group: 'drydock-dev',
    name: 'drydock-law',
  },
  reader_identity: {
    name: 'aisocdev-connectors',
    client_id: 'reader-client',
    principal_id: 'reader-principal',
    configured: true,
    roles: [
      {
        name: 'Microsoft Sentinel Reader',
        scope: '/subscriptions/sentinel-sub/resourceGroups/drydock-dev',
        assignment_source: 'terraform',
      },
    ],
  },
  responder_identity: {
    name: 'aisocdev-actions',
    client_id: 'responder-client',
    principal_id: 'responder-principal',
    configured: true,
    roles: [
      {
        name: 'Microsoft Sentinel Responder',
        scope: '/subscriptions/sentinel-sub/resourceGroups/drydock-dev',
        assignment_source: 'terraform',
      },
    ],
  },
  connector: {
    id: '22222222-2222-2222-2222-222222222222',
    name: 'Drydock Sentinel',
    enabled: true,
    auth_mode: 'managed_identity',
    health_status: 'healthy',
    last_verified_at: '2026-11-01T15:59:00Z',
    last_sync: '2026-11-01T15:59:00Z',
  },
};

describe('ManagedIdentityStatusDetails', () => {
  it('shows the live Sentinel connection and both least-privilege identities', () => {
    render(<ManagedIdentityStatusDetails status={status} />);

    expect(screen.getByText('Connected with managed identity')).toBeInTheDocument();
    expect(screen.getByText('aisocdev-connectors')).toBeInTheDocument();
    expect(screen.getByText('Microsoft Sentinel Reader')).toBeInTheDocument();
    expect(screen.getByText('aisocdev-actions')).toBeInTheDocument();
    expect(screen.getByText('Microsoft Sentinel Responder')).toBeInTheDocument();
    expect(screen.getByText('drydock-dev / drydock-law')).toBeInTheDocument();
    expect(screen.queryByText(/client secret/i)).not.toBeInTheDocument();
  });
});
