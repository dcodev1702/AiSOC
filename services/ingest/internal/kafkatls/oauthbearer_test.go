package kafkatls

import (
	"context"
	"strings"
	"testing"
)

type staticOAuthCredential struct {
	token string
	scope string
}

func (c *staticOAuthCredential) Token(_ context.Context, scope string) (string, error) {
	c.scope = scope
	return c.token, nil
}

func TestOAuthBearerMechanismUsesManagedIdentityToken(t *testing.T) {
	credential := &staticOAuthCredential{token: "managed-identity-token"}
	mechanism := &oauthBearerMechanism{
		credential: credential,
		scope:      "https://aisoc.servicebus.windows.net/.default",
	}

	if got := mechanism.Name(); got != "OAUTHBEARER" {
		t.Fatalf("Name() = %q, want OAUTHBEARER", got)
	}
	session, initial, err := mechanism.Start(context.Background())
	if err != nil {
		t.Fatalf("Start() error = %v", err)
	}
	if credential.scope != "https://aisoc.servicebus.windows.net/.default" {
		t.Fatalf("token scope = %q", credential.scope)
	}
	if !strings.Contains(string(initial), "auth=Bearer managed-identity-token") {
		t.Fatalf("initial response does not contain bearer token: %q", string(initial))
	}
	done, response, err := session.Next(context.Background(), nil)
	if err != nil || !done || response != nil {
		t.Fatalf("Next() = done:%v response:%q err:%v", done, response, err)
	}
}
