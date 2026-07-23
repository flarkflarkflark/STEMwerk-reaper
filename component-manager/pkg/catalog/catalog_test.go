package catalog

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func fixture(t *testing.T, name string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "experiments", "component-manager-poa0", "contract-v1", "examples", name))
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := json.Unmarshal(data, &value); err != nil {
		t.Fatal(err)
	}
	delete(value, "$schema_ref")
	return value
}
func encode(t *testing.T, value any) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestSevenFlowCatalogFixture(t *testing.T) {
	data := encode(t, fixture(t, "catalog.json"))
	parsed, err := ParseBytes(data)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"normal-stems", "six-stem", "direct-kit", "kit-split", "vocals-hq", "de-reverb", "vocal-de-reverb"}
	if len(parsed.Flows) != len(want) {
		t.Fatalf("got %d flows", len(parsed.Flows))
	}
	for i := range want {
		if parsed.Flows[i].ID != want[i] {
			t.Fatalf("flow %d: %s", i, parsed.Flows[i].ID)
		}
	}
	fromReader, err := ParseReader(bytes.NewReader(data))
	if err != nil || len(fromReader.Flows) != 7 {
		t.Fatalf("reader: %v", err)
	}
}

func validComponent(t *testing.T, digestByte string) map[string]any {
	item := fixture(t, "component-runtime-main.json")
	artifact := item["artifact"].(map[string]any)
	artifact["artifact_id"] = "artifact.sha256." + digestByte
	artifact["digest"] = "sha256:" + digestByte
	return item
}

func TestCatalogRejectsDuplicateAndDigestConflict(t *testing.T) {
	a := validComponent(t, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	for _, tc := range []struct {
		name   string
		second map[string]any
	}{
		{"duplicate", validComponent(t, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")},
		{"digest-conflict", validComponent(t, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")},
	} {
		catalog := fixture(t, "catalog.json")
		catalog["components"] = []any{a, tc.second}
		if _, err := ParseBytes(encode(t, catalog)); err == nil {
			t.Fatalf("accepted %s", tc.name)
		}
	}
}

func TestCatalogRejectsInvalidInput(t *testing.T) {
	invalidID := fixture(t, "catalog.json")
	component := validComponent(t, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	component["component_id"] = "Runtime/Main"
	invalidID["components"] = []any{component}
	unknown := fixture(t, "catalog.json")
	unknown["unexpected"] = true
	unsupported := fixture(t, "catalog.json")
	unsupported["schema_version"] = "2.0.0"
	for name, data := range map[string][]byte{"invalid-id": encode(t, invalidID), "unknown-field": encode(t, unknown), "unsupported": encode(t, unsupported), "oversize": make([]byte, MaxInputSize+1)} {
		if _, err := ParseBytes(data); err == nil {
			t.Fatalf("accepted %s", name)
		}
	}
}

func FuzzParseBytes(f *testing.F) {
	f.Add([]byte(`{}`))
	f.Fuzz(func(t *testing.T, data []byte) { _, _ = ParseBytes(data) })
}
