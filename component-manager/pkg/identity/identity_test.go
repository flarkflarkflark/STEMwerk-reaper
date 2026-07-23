package identity

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestComponentIDRoundTrips(t *testing.T) {
	id, err := ParseComponentID("runtime.main")
	if err != nil || id.String() != "runtime.main" {
		t.Fatalf("ParseComponentID: %v, %q", err, id)
	}
	data, err := json.Marshal(id)
	if err != nil {
		t.Fatal(err)
	}
	var got ComponentID
	if err := json.Unmarshal(data, &got); err != nil || got != id {
		t.Fatalf("JSON round trip: %v, %q", err, got)
	}
}

func TestLogicalIDsRejectUnsafeValues(t *testing.T) {
	tests := []string{"", "Runtime.Main", " runtime.main", "runtime..main", "runtime/main", "../runtime", "rüntime.main"}
	for _, value := range tests {
		t.Run(value, func(t *testing.T) {
			if _, err := ParseComponentID(value); err == nil {
				t.Fatalf("accepted %q", value)
			}
		})
	}
}

func TestContentIDsRequireExactPrefixAndSHA256(t *testing.T) {
	hex := strings.Repeat("a", 64)
	tests := []struct {
		name  string
		parse func(string) error
		value string
		ok    bool
	}{
		{"artifact valid", func(s string) error { _, err := ParseArtifactID(s); return err }, "artifact.sha256." + hex, true},
		{"artifact uppercase", func(s string) error { _, err := ParseArtifactID(s); return err }, "artifact.sha256." + strings.ToUpper(hex), false},
		{"model logical", func(s string) error { _, err := ParseModelID(s); return err }, "model.bs_roformer.vocals_hq", true},
		{"generation valid", func(s string) error { _, err := ParseGenerationID(s); return err }, "generation.sha256." + hex, true},
		{"generation wrong prefix", func(s string) error { _, err := ParseGenerationID(s); return err }, "artifact.sha256." + hex, false},
		{"receipt short", func(s string) error { _, err := ParseReceiptID(s); return err }, "receipt.sha256.aa", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.parse(tt.value)
			if (err == nil) != tt.ok {
				t.Fatalf("error=%v, want ok=%v", err, tt.ok)
			}
		})
	}
}

func TestZeroValuesAreInvalid(t *testing.T) {
	if (ComponentID{}).Valid() || (ArtifactID{}).Valid() || (ModelID{}).Valid() ||
		(GenerationID{}).Valid() || (ReceiptID{}).Valid() {
		t.Fatal("zero identity reported valid")
	}
}

func FuzzParseComponentID(f *testing.F) {
	f.Add("runtime.main")
	f.Fuzz(func(t *testing.T, value string) {
		id, err := ParseComponentID(value)
		if err == nil && (!id.Valid() || id.String() != value) {
			t.Fatalf("non-deterministic parse for %q", value)
		}
	})
}
