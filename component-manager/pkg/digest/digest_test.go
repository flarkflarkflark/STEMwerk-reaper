package digest

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestDigestRoundTrip(t *testing.T) {
	value := "sha256:" + strings.Repeat("a", 64)
	d, err := Parse(value)
	if err != nil || d.String() != value {
		t.Fatalf("Parse: %v, %q", err, d)
	}
	data, _ := json.Marshal(d)
	var got Digest
	if err := json.Unmarshal(data, &got); err != nil || got != d {
		t.Fatalf("JSON round trip: %v", err)
	}
}

func TestDigestRejectsInvalidForms(t *testing.T) {
	for _, value := range []string{
		"", "sha512:" + strings.Repeat("a", 64), "sha256:aa",
		"sha256:" + strings.Repeat("A", 64), "sha256:" + strings.Repeat("g", 64),
	} {
		t.Run(value, func(t *testing.T) {
			if _, err := Parse(value); err == nil {
				t.Fatalf("accepted %q", value)
			}
		})
	}
}

func TestDigestZeroValueInvalid(t *testing.T) {
	if (Digest{}).Valid() {
		t.Fatal("zero digest reported valid")
	}
}

func FuzzParseDigest(f *testing.F) {
	f.Add("sha256:" + strings.Repeat("0", 64))
	f.Fuzz(func(t *testing.T, value string) {
		d, err := Parse(value)
		if err == nil && (!d.Valid() || d.String() != value) {
			t.Fatalf("non-deterministic parse for %q", value)
		}
	})
}
