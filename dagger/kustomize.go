package main

import (
	"context"
	"dagger/cloud-native-ref/internal/dagger"
	"path"
	"strings"
)

func createKustomization(ctx context.Context, ctr *dagger.Container, source *dagger.Directory, branch string, kustPath string, resources []string) (*dagger.Directory, error) {

	ctr = ctr.WithExec([]string{"apk", "add", "kustomize"})

	// bash script that changes the git branch given a parameter --branch <branch>, kustdir <kustdir>, and resources <resources>
	// it should change the current directory to the kustdir and run the kustomize create --resources <resources>
	// the resources should be a comma separated list of resources
	updateKustomizationScript := `#!/bin/bash
set -e
# Function to display usage instructions
usage() {
  echo "Usage: $0 --resources <resources>"
  exit 1
}

# Check if the correct number of arguments are provided
if [ "$#" -ne 2 ]; then
  usage
fi

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --resources)
      RESOURCES="$2"
      shift
      ;;
    *)
      usage
      ;;
  esac
  shift
done

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

	return ctr.WithWorkdir(path.Join("/cloud-native-ref", kustPath)).
		WithNewFile("/bin/update-kustomization", updateKustomizationScript, dagger.ContainerWithNewFileOpts{Permissions: 0750}).
		WithExec([]string{"/bin/update-kustomization", "--resources", strings.Join(resources, ",")}).
		Directory(path.Join("/cloud-native-ref", kustPath)), nil
}
