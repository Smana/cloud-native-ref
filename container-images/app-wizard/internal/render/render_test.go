package render

import "testing"

func TestParseRenderStream(t *testing.T) {
	stream := []byte(`---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: xplane-myapp
spec:
  replicas: 1
---
apiVersion: v1
kind: Service
metadata:
  name: xplane-myapp
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: xplane-myapp
`)
	got, err := ParseRenderStream(stream)
	if err != nil {
		t.Fatalf("ParseRenderStream: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("got %d resources, want 3: %+v", len(got), got)
	}
	if got[0].Kind != "Deployment" || got[0].Name != "xplane-myapp" {
		t.Errorf("first = %+v", got[0])
	}
	if got[0].Role == "" {
		t.Errorf("Deployment should have a role description")
	}
	if got[2].Kind != "HTTPRoute" {
		t.Errorf("third = %+v", got[2])
	}
}

func TestParseRenderStreamSkipsEmpty(t *testing.T) {
	got, err := ParseRenderStream([]byte("\n\n---\n\n"))
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("expected 0 resources, got %+v", got)
	}
}
