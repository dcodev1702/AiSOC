# AiSOC Azure test deployment log

Target environment:

- Tenant: `967cf3e2-7fdc-4f31-804e-b5f228a10c77`
- Subscription: `dev-defconai` (`2c6d3f6e-b79a-405d-82c9-ce44363a1374`)
- Sentinel workspace: `drydock-dev/drydock-law`
- Log Analytics workspace ID: `86105a9e-b71a-4cdd-a0e3-f4556a984119`
- Operator: `lorenzo@cyberdefenseai.onmicrosoft.com`

This log contains no credentials or secret values. Times are Europe/Berlin.

| Time | Action | Result |
| --- | --- | --- |
| 2026-11-01 14:22 CET | Ran a read-only Terraform plan against the target subscription and Sentinel resource group. | Plan succeeded: 54 to add, 0 to change, 0 to destroy. No apply was run. |
| 2026-11-01 14:23 CET | Restored Azure provider state after the AzureRM provider began automatic registration during the first plan. | `Microsoft.AVS` returned to `Unregistered`; `skip_provider_registration = true` was added to both AzureRM providers. No AVS resources were created. |
| 2026-11-01 14:36 CET | Completed connector, actions, API, web, generated-document, dependency-lock, lint, and Terraform validation. | 1,239 connector tests passed; 1,560 action tests passed and 9 skipped; 28 affected API tests passed; 3 web tests and TypeScript checks passed. |
| 2026-11-01 14:43 CET | Rechecked tenant, subscription, Sentinel incidents, and Log Analytics access. | Correct tenant/subscription selected; incident list returned 0; `print Result=1` returned 1; no AiSOC managed identities existed. |
| 2026-11-01 14:45 CET | Started the authorized test deployment run. | Audit implementation is ready to commit and push before Azure mutations. |

