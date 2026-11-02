import assert from 'node:assert/strict';
import test from 'node:test';

import {
  createManagedIdentityOAuthProvider,
  resolveKafkaTransport,
} from '../src/kafkaTransport';

test('managed identity OAuth provider requests the Event Hubs namespace scope', async () => {
  const scopes: string[] = [];
  const provider = createManagedIdentityOAuthProvider(
    'https://aisoc.servicebus.windows.net',
    'pipeline-client-id',
    () => ({
      async getToken(scope: string) {
        scopes.push(scope);
        return { token: 'managed-identity-token', expiresOnTimestamp: 4_000_000 };
      },
    }),
    () => 1_000_000,
  );

  const first = await provider();
  const second = await provider();

  assert.equal(first.value, 'managed-identity-token');
  assert.equal(second.value, first.value);
  assert.deepEqual(scopes, ['https://aisoc.servicebus.windows.net/.default']);
});

test('SASL_SSL OAUTHBEARER resolves a managed identity provider', () => {
  const previous = {
    mechanism: process.env.KAFKA_SASL_MECHANISM,
    resource: process.env.KAFKA_OAUTH_RESOURCE,
    clientId: process.env.KAFKA_MANAGED_IDENTITY_CLIENT_ID,
  };
  process.env.KAFKA_SASL_MECHANISM = 'OAUTHBEARER';
  process.env.KAFKA_OAUTH_RESOURCE = 'https://aisoc.servicebus.windows.net';
  process.env.KAFKA_MANAGED_IDENTITY_CLIENT_ID = 'pipeline-client-id';

  try {
    const transport = resolveKafkaTransport('production', 'SASL_SSL');
    assert.equal(transport.ssl instanceof Object, true);
    assert.equal(transport.sasl?.mechanism, 'oauthbearer');
    assert.equal(
      transport.sasl && 'oauthBearerProvider' in transport.sasl
        ? typeof transport.sasl.oauthBearerProvider
        : 'missing',
      'function',
    );
  } finally {
    for (const [name, value] of [
      ['KAFKA_SASL_MECHANISM', previous.mechanism],
      ['KAFKA_OAUTH_RESOURCE', previous.resource],
      ['KAFKA_MANAGED_IDENTITY_CLIENT_ID', previous.clientId],
    ] as const) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  }
});
