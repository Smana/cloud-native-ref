// Package render produces a resource preview for a claim by running
// `crossplane render` (FR-008, T106). The real implementation shells out to the
// crossplane CLI against the repo's composition files; a fake implementation
// backs unit tests so they need neither a cluster nor Docker.
package render

import (
	"context"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
)

// Renderer renders a claim YAML into the list of resources it would create.
type Renderer interface {
	Render(ctx context.Context, claimYAML []byte) ([]api.RenderedResource, error)
}
