package main

import (
	"context"
	"dagger/cloud-native-ref/internal/dagger"
	"fmt"
	"net"
	"strings"
	"time"
	"unicode"
)

// camelCaseToKebabCase converts a string from camelCase to kebab-case
func camelCaseToKebabCase(s string) string {
	var builder strings.Builder
	for i, r := range s {
		if i > 0 && unicode.IsUpper(r) {
			builder.WriteRune('-')
		}
		builder.WriteRune(unicode.ToLower(r))
	}
	return builder.String()
}

// getSecretValue returns the plaintext value of a secret
func getSecretValue(ctx context.Context, secret *dagger.Secret) (string, error) {
	plainText, err := secret.Plaintext(ctx)
	if err != nil {
		return "", fmt.Errorf("failed to get secret value from the secret passed: %w", err)
	}

	return plainText, nil
}

// checkDomainReachability checks if a domain is reachable on a specific port
func checkDomainReachability(domain string, port string, retries int, delay time.Duration) error {
	address := fmt.Sprintf("%s:%s", domain, port)
	for i := 0; i < retries; i++ {
		conn, err := net.DialTimeout("tcp", address, 10*time.Second)
		if err == nil {
			conn.Close()
			fmt.Printf("Successfully connected to %s on port %s\n", domain, port)
			return nil
		}
		fmt.Printf("Attempt %d: Failed to connect to %s on port %s. Retrying in %v...\n", i+1, domain, port, delay)
		time.Sleep(delay)
	}
	return fmt.Errorf("could not connect to %s on port %s after %d attempts", domain, port, retries)
}
