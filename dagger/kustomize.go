package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v2"
)

// Kustomization struct definition (assuming it's defined somewhere in your code)
type Kustomization struct {
	Resources []string `yaml:"resources"`
}

// updateKustomizationResources reads a kustomization.yaml file from the given path, updates the resources list, and writes it back.
func updateKustomizationResources(relativePath string, newResources []string) error {
	// Get the root of the current git repository
	gitRoot, err := getGitRoot()
	if err != nil {
		return err
	}

	// Construct the full path
	path := filepath.Join(gitRoot, relativePath)

	// Ensure the directory exists
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("failed to create directories: %w", err)
	}

	// Ensure the file exists
	if _, err := os.Stat(path); os.IsNotExist(err) {
		if _, err := os.Create(path); err != nil {
			return fmt.Errorf("failed to create file: %w", err)
		}
	}

	// Read the existing kustomization.yaml file
	fileData, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("failed to read kustomization file: %w", err)
	}

	// Unmarshal the YAML data into a generic map to check for the kustomization keys
	var genericData map[string]interface{}
	err = yaml.Unmarshal(fileData, &genericData)
	if err != nil {
		return fmt.Errorf("failed to unmarshal YAML: %w", err)
	}

	// Check if the file contains kustomization-specific keys
	if _, ok := genericData["resources"]; !ok {
		if _, ok := genericData["bases"]; !ok {
			if _, ok := genericData["patches"]; !ok {
				return errors.New("the provided file is not a valid kustomization.yaml")
			}
		}
	}

	// Unmarshal the YAML data into a Kustomization struct
	var kustomization Kustomization
	err = yaml.Unmarshal(fileData, &kustomization)
	if err != nil {
		return fmt.Errorf("failed to unmarshal YAML: %w", err)
	}

	// Update the resources field
	kustomization.Resources = newResources

	// Marshal the updated struct back to YAML
	updatedData, err := yaml.Marshal(&kustomization)
	if err != nil {
		return fmt.Errorf("failed to marshal updated YAML: %w", err)
	}

	// Write the updated YAML back to the file
	err = os.WriteFile(path, updatedData, 0644)
	if err != nil {
		return fmt.Errorf("failed to write updated kustomization file: %w", err)
	}

	return nil
}
