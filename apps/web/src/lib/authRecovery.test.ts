/** Regression coverage for a console session being deleted by any 401. */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  apiRequest,
  AUTH_REFRESH_KEY,
  AUTH_TOKEN_KEY,
  AUTH_USER_KEY,
} from './api';

const USER = JSON.stringify({
  id: '00000000-0000-0000-0000-000000000010',
  email: 'operator@example.test',
  role: 'admin',
  tenant_id: '00000000-0000-0000-0000-000000000001',
});

describe('401 session recovery', () => {
  beforeEach(() => {
    window.history.replaceState(null, '', '/login');
    window.localStorage.clear();
    window.localStorage.setItem(AUTH_TOKEN_KEY, 'old-access');
    window.localStorage.setItem(AUTH_REFRESH_KEY, 'working-refresh');
    window.localStorage.setItem(AUTH_USER_KEY, USER);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    window.localStorage.clear();
  });

  it('keeps a valid console session when an optional route still returns 401', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(new Response('{"detail":"peer auth only"}', { status: 401 }))
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            access_token: 'new-access',
            refresh_token: 'new-refresh',
            token_type: 'bearer',
            expires_in: 1800,
          }),
          { status: 200, headers: { 'Content-Type': 'application/json' } },
        ),
      )
      .mockResolvedValueOnce(new Response('{"detail":"peer auth only"}', { status: 401 }))
      .mockResolvedValueOnce(new Response(USER, { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    await expect(apiRequest('/api/v1/optional-peer')).rejects.toMatchObject({
      status: 401,
    });

    expect(window.localStorage.getItem(AUTH_TOKEN_KEY)).toBe('new-access');
    expect(window.localStorage.getItem(AUTH_REFRESH_KEY)).toBe('new-refresh');
    expect(window.localStorage.getItem(AUTH_USER_KEY)).toBe(USER);
    expect(fetchMock).toHaveBeenCalledTimes(4);
    expect(fetchMock.mock.calls[3][0]).toBe('/api/v1/auth/me');
  });

  it('clears credentials only after refresh and session validation both fail', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(new Response('{"detail":"expired"}', { status: 401 }))
      .mockResolvedValueOnce(new Response('{"detail":"invalid refresh"}', { status: 401 }))
      .mockResolvedValueOnce(new Response('{"detail":"invalid session"}', { status: 401 }));
    vi.stubGlobal('fetch', fetchMock);

    await expect(apiRequest('/api/v1/protected')).rejects.toMatchObject({
      status: 401,
    });

    expect(window.localStorage.getItem(AUTH_TOKEN_KEY)).toBeNull();
    expect(window.localStorage.getItem(AUTH_REFRESH_KEY)).toBeNull();
    expect(window.localStorage.getItem(AUTH_USER_KEY)).toBeNull();
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });
});
