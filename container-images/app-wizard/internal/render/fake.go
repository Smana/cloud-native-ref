package render

import (
	"context"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
)

// FakeRenderer is a deterministic Renderer for tests. It returns Resources (or
// invokes RenderFunc when set) instead of shelling out to crossplane.
type FakeRenderer struct {
	Resources  []api.RenderedResource
	Err        error
	RenderFunc func(ctx context.Context, claimYAML []byte) ([]api.RenderedResource, error)

	// Calls records every claim rendered, for assertions.
	Calls [][]byte
}

func (f *FakeRenderer) Render(ctx context.Context, claimYAML []byte) ([]api.RenderedResource, error) {
	f.Calls = append(f.Calls, claimYAML)
	if f.RenderFunc != nil {
		return f.RenderFunc(ctx, claimYAML)
	}
	if f.Err != nil {
		return nil, f.Err
	}
	return f.Resources, nil
}

var _ Renderer = (*FakeRenderer)(nil)
