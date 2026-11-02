package kafkatls

import (
	"context"
	"fmt"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/segmentio/kafka-go/sasl"
)

type oauthTokenCredential interface {
	Token(context.Context, string) (string, error)
}

type azureManagedIdentityCredential struct {
	credential *azidentity.ManagedIdentityCredential
}

func (c *azureManagedIdentityCredential) Token(ctx context.Context, scope string) (string, error) {
	token, err := c.credential.GetToken(ctx, policy.TokenRequestOptions{Scopes: []string{scope}})
	if err != nil {
		return "", fmt.Errorf("getting managed identity token: %w", err)
	}
	return token.Token, nil
}

func newManagedIdentityCredential(clientID string) (oauthTokenCredential, error) {
	options := &azidentity.ManagedIdentityCredentialOptions{}
	if clientID != "" {
		options.ID = azidentity.ClientID(clientID)
	}
	credential, err := azidentity.NewManagedIdentityCredential(options)
	if err != nil {
		return nil, fmt.Errorf("creating managed identity credential: %w", err)
	}
	return &azureManagedIdentityCredential{credential: credential}, nil
}

type oauthBearerMechanism struct {
	credential oauthTokenCredential
	scope      string
}

var _ sasl.Mechanism = (*oauthBearerMechanism)(nil)

func (m *oauthBearerMechanism) Name() string { return "OAUTHBEARER" }

func (m *oauthBearerMechanism) Start(ctx context.Context) (sasl.StateMachine, []byte, error) {
	token, err := m.credential.Token(ctx, m.scope)
	if err != nil {
		return nil, nil, err
	}
	return oauthBearerState{}, []byte("n,,\x01auth=Bearer " + token + "\x01\x01"), nil
}

type oauthBearerState struct{}

func (oauthBearerState) Next(_ context.Context, challenge []byte) (bool, []byte, error) {
	if len(challenge) != 0 {
		return false, nil, fmt.Errorf("Azure Event Hubs rejected the OAUTHBEARER token: %s", string(challenge))
	}
	return true, nil, nil
}
