package main

import (
	"context"
	"dagger/cloud-native-ref/internal/dagger"
	"fmt"
)

// getSecretValue returns the plaintext value of a secret
func getSecretValue(ctx context.Context, secret *dagger.Secret) (string, error) {
	plainText, err := secret.Plaintext(ctx)
	if err != nil {
		return "", fmt.Errorf("failed to get secret value from the secret passed: %w", err)
	}

	return plainText, nil
}
