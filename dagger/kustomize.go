package main

import (
	"dagger/cloud-native-ref/internal/dagger"
	"fmt"
	"path/filepath"
	"strings"
)

// updateKustomization updates the kustomization.yaml file with the specified resources
func updateKustomization(ctr *dagger.Container, kustPath string, resources []string) (*dagger.Directory, error) {

	ctr = ctr.WithExec([]string{"apk", "add", "kustomize"})

	updateKustomizationScript := `#!/bin/bash
set -eo pipefail

# Check if the correct number of arguments are provided
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <resources>"
  exit 1
fi

RESOURCES="$1"

# Remove existing kustomization.yaml if it exists
if [ -f "kustomization.yaml" ]; then
  echo "Removing existing kustomization.yaml"
  rm -f "kustomization.yaml"
fi

# Run kustomize create with the specified resources
kustomize create --resources "$RESOURCES"
if [ $? -ne 0 ]; then
  echo "Failed to run kustomize create"
  exit 1
fi

echo "Script executed successfully!"
	`

	return ctr.WithWorkdir(filepath.Join(fmt.Sprintf("/%s", repoName), kustPath)).
		WithNewFile("/bin/update-kustomization", updateKustomizationScript, dagger.ContainerWithNewFileOpts{Permissions: 0750}).
		WithExec([]string{"/bin/update-kustomization", strings.Join(resources, ",")}).
		Directory(filepath.Join(fmt.Sprintf("/%s", repoName), kustPath)), nil
}
