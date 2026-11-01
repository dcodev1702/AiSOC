import { describe, expect, it } from 'vitest';

import {
  buildInitialValues,
  fieldIsVisible,
  missingRequiredFields,
  partitionFormValues,
} from './AddConnectorModal';
import type { ConnectorSchemaField } from '@/lib/api';

const fields: ConnectorSchemaField[] = [
  {
    name: 'auth_mode',
    type: 'select',
    label: 'Authentication mode',
    default: 'client_secret',
    options: [
      { value: 'client_secret', label: 'Client secret' },
      { value: 'managed_identity', label: 'Managed identity' },
    ],
  },
  {
    name: 'client_secret',
    type: 'secret',
    label: 'Client secret',
    required: true,
    visible_when: { auth_mode: 'client_secret' },
  },
  { name: 'workspace', type: 'string', label: 'Workspace', required: true },
];

describe('conditional connector fields', () => {
  it('shows fields only when their equality condition matches', () => {
    expect(fieldIsVisible(fields[1], { auth_mode: 'client_secret' })).toBe(true);
    expect(fieldIsVisible(fields[1], { auth_mode: 'managed_identity' })).toBe(false);
  });

  it('does not submit a hidden secret left over after switching auth modes', () => {
    const values = {
      ...buildInitialValues(fields),
      auth_mode: 'managed_identity',
      client_secret: 'must-not-leave-the-browser',
      workspace: 'drydock-law',
    };

    expect(partitionFormValues(fields, values)).toEqual({
      auth_config: {},
      connector_config: {
        auth_mode: 'managed_identity',
        workspace: 'drydock-law',
      },
    });
  });

  it('requires a client secret only while that field is visible', () => {
    expect(missingRequiredFields(fields, buildInitialValues(fields)).map((field) => field.name)).toEqual([
      'client_secret',
      'workspace',
    ]);

    expect(
      missingRequiredFields(fields, {
        ...buildInitialValues(fields),
        auth_mode: 'managed_identity',
        workspace: 'drydock-law',
      }),
    ).toEqual([]);
  });
});
