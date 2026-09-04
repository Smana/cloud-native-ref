package main

import (
	"os"
	"strings"
	"testing"
)

func TestValidateRejectsMissingRequired(t *testing.T) {
	err := Config{RequestEncoding: EncodingJSON}.Validate()
	if err == nil {
		t.Fatal("expected an error when required values are absent")
	}
	for _, want := range []string{"TEP_STS_URL", "TEP_UPSTREAM_URL"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error should name %s, got %q", want, err)
		}
	}
}

func TestValidateRejectsUnknownEncoding(t *testing.T) {
	c := Config{
		STSURL: "https://sts.example/v1/token", UpstreamURL: "http://up",
		SubjectHeader: "Authorization", InjectHeader: "Authorization",
		RequestEncoding: "xml",
	}
	if err := c.Validate(); err == nil {
		t.Fatal("expected an error for an unsupported encoding")
	}
}

func TestValidateAcceptsBothEncodings(t *testing.T) {
	for _, enc := range []Encoding{EncodingForm, EncodingJSON} {
		c := Config{
			STSURL: "https://sts.example/v1/token", UpstreamURL: "http://up",
			SubjectHeader: "Authorization", InjectHeader: "Authorization",
			RequestEncoding: enc,
		}
		if err := c.Validate(); err != nil {
			t.Errorf("encoding %q should be valid: %v", enc, err)
		}
	}
}

// An explicitly EMPTY variable must be honoured, not replaced by the default.
// TEP_INJECT_PREFIX="" means "inject the raw token"; silently substituting
// "Bearer " produced a doubled prefix at the upstream and a 401 that named
// nothing. This is the regression test for that.
func TestEmptyEnvIsHonouredNotDefaulted(t *testing.T) {
	t.Setenv("TEP_STS_URL", "https://sts.example/v1/token")
	t.Setenv("TEP_UPSTREAM_URL", "http://upstream.invalid")
	t.Setenv("TEP_INJECT_PREFIX", "")
	t.Setenv("TEP_SUBJECT_PREFIX", "")

	c, err := LoadConfig()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if c.InjectPrefix != "" {
		t.Errorf("InjectPrefix = %q, want \"\" (an explicitly empty value must survive)", c.InjectPrefix)
	}
	if c.SubjectPrefix != "" {
		t.Errorf("SubjectPrefix = %q, want \"\"", c.SubjectPrefix)
	}
}

// An ABSENT variable still gets its default -- the fix above must not break this.
func TestAbsentEnvStillDefaults(t *testing.T) {
	t.Setenv("TEP_STS_URL", "https://sts.example/v1/token")
	t.Setenv("TEP_UPSTREAM_URL", "http://upstream.invalid")
	os.Unsetenv("TEP_INJECT_PREFIX")

	c, err := LoadConfig()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if c.InjectPrefix != "Bearer " {
		t.Errorf("InjectPrefix = %q, want \"Bearer \" when unset", c.InjectPrefix)
	}
}
