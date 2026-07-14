// Package validate runs the pre-submit gates on a candidate App spec: JSON
// Schema validation, CEL rule evaluation (mirroring the API server), and
// secret scanning (FR-002/007/010, T105).
package validate

import (
	"math"
	"regexp"
	"sort"
	"strings"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
)

var (
	awsAccessKeyRe = regexp.MustCompile(`AKIA[0-9A-Z]{16}`)
	pemHeaderRe    = regexp.MustCompile(`-----BEGIN [A-Z ]*PRIVATE KEY-----`)
)

// entropyThreshold is the Shannon-entropy (bits per char) above which a
// sufficiently long string is treated as a candidate high-entropy secret.
const (
	entropyThreshold = 4.0
	entropyMinLen    = 20
)

// ScanSecrets walks a spec object and flags string leaf values that look like
// secrets, returning findings keyed by JSON path (FR-010).
func ScanSecrets(spec map[string]any) []api.SecretFinding {
	var findings []api.SecretFinding
	walkStrings(spec, "spec", func(path, val string) {
		switch {
		case awsAccessKeyRe.MatchString(val):
			findings = append(findings, api.SecretFinding{Path: path, Reason: "matches AWS access key ID pattern (AKIA…)"})
		case pemHeaderRe.MatchString(val):
			findings = append(findings, api.SecretFinding{Path: path, Reason: "contains a PEM private-key header"})
		case looksHighEntropy(val):
			findings = append(findings, api.SecretFinding{Path: path, Reason: "high-entropy string, likely a credential"})
		}
	})
	sort.Slice(findings, func(i, j int) bool { return findings[i].Path < findings[j].Path })
	return findings
}

// walkStrings recurses into maps/slices invoking fn for every string leaf,
// building a dotted/indexed JSON path.
func walkStrings(v any, path string, fn func(path, val string)) {
	switch t := v.(type) {
	case string:
		fn(path, t)
	case map[string]any:
		keys := make([]string, 0, len(t))
		for k := range t {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			walkStrings(t[k], path+"."+k, fn)
		}
	case []any:
		for i, e := range t {
			walkStrings(e, path+"["+itoa(i)+"]", fn)
		}
	}
}

// looksHighEntropy reports whether s is long enough and dense enough (by
// Shannon entropy) to be treated as a probable secret, while excluding
// obviously non-secret strings like image references and URLs.
func looksHighEntropy(s string) bool {
	if len(s) < entropyMinLen {
		return false
	}
	// Skip strings with spaces (prose) or path/URL separators that inflate
	// entropy without being credentials.
	if strings.ContainsAny(s, " \t\n/") {
		return false
	}
	return shannonEntropy(s) >= entropyThreshold
}

// shannonEntropy returns the per-character Shannon entropy of s in bits.
func shannonEntropy(s string) float64 {
	if s == "" {
		return 0
	}
	counts := map[rune]int{}
	for _, r := range s {
		counts[r]++
	}
	n := float64(len([]rune(s)))
	var h float64
	for _, c := range counts {
		p := float64(c) / n
		h -= p * math.Log2(p)
	}
	return h
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}
