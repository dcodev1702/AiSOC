/**
 * Browser Fusion calls must cross the core API authentication boundary.
 * Fusion accepts a backend service token plus a trusted tenant assertion;
 * an analyst JWT sent directly to it is correctly rejected with 401.
 */
import { createRequire } from 'node:module';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';

const require = createRequire(import.meta.url);
const configFile = path.join(process.cwd(), 'next.config.js');
const originalApiUrl = process.env.API_URL;
const originalFusionUrl = process.env.FUSION_URL;

function loadConfig() {
  delete require.cache[configFile];
  return require(configFile);
}

afterEach(() => {
  if (originalApiUrl === undefined) delete process.env.API_URL;
  else process.env.API_URL = originalApiUrl;
  if (originalFusionUrl === undefined) delete process.env.FUSION_URL;
  else process.env.FUSION_URL = originalFusionUrl;
  delete require.cache[configFile];
});

describe('Fusion browser routing', () => {
  it('always falls through to the authenticated core API gateway', async () => {
    process.env.API_URL = 'https://api.internal.example';
    // A stale deployment variable must not re-enable direct browser access.
    process.env.FUSION_URL = 'https://fusion.internal.example';

    const rewrites = await loadConfig().rewrites();

    expect(rewrites).not.toContainEqual(
      expect.objectContaining({ source: '/api/v1/fusion/:path*' }),
    );
    expect(rewrites).toContainEqual({
      source: '/api/v1/:path*',
      destination: 'https://api.internal.example/api/v1/:path*',
    });
  });
});
