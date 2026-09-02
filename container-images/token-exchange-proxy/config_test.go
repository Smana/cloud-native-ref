package main

import "testing"

func TestValidateRejectsMissingRequired(t *testing.T) {
	err := Config{RequestEncoding: EncodingJSON}.Validate()
	if err == nil {
		t.Fatal("expected an error when required values are absent")
	}
	for _, want := range []string{"TEP_STS_URL", "TEP_UPSTREAM_URL"} {
		if !contains(err.Error(), want) {
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

func contains(hay, needle string) bool {
	return len(hay) >= len(needle) && (hay == needle || len(needle) == 0 ||
		func() bool {
			for i := 0; i+len(needle) <= len(hay); i++ {
				if hay[i:i+len(needle)] == needle {
					return true
				}
			}
			return false
		}())
}
