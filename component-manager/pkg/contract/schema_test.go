package contract_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/flarkflarkflark/STEMwerk-reaper/component-manager/pkg/contract"
	"github.com/flarkflarkflark/STEMwerk-reaper/component-manager/schemas"
)

func TestAllSchemasLoad(t *testing.T) {
	if len(schemas.Names()) != 21 {
		t.Fatalf("got %d schemas", len(schemas.Names()))
	}
	for _, n := range schemas.Names() {
		if _, err := schemas.Load(n); err != nil {
			t.Fatal(err)
		}
	}
}

func TestAllContractExamplesValidate(t *testing.T) {
	paths, err := filepath.Glob(filepath.Join("..", "..", "..", "experiments", "component-manager-poa0", "contract-v1", "examples", "*.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range paths {
		t.Run(filepath.Base(path), func(t *testing.T) {
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			var object map[string]any
			if err := json.Unmarshal(data, &object); err != nil {
				t.Fatal(err)
			}
			ref, ok := object["$schema_ref"].(string)
			if !ok {
				t.Skip("policy fixture without schema reference")
			}
			delete(object, "$schema_ref")
			data, _ = json.Marshal(object)
			if err := contract.ValidateJSON(filepath.Base(strings.TrimPrefix(ref, "../schemas/")), data); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func FuzzValidateJSON(f *testing.F) {
	f.Add([]byte(`{}`))
	f.Fuzz(func(t *testing.T, data []byte) { _ = contract.ValidateJSON("catalog.schema.json", data) })
}
func TestCatalogSchemaValidation(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "experiments", "component-manager-poa0", "contract-v1", "examples", "catalog.json"))
	if err != nil {
		t.Fatal(err)
	}
	data = removeSchemaRef(t, data)
	if err := contract.ValidateJSON("catalog.schema.json", data); err != nil {
		t.Fatal(err)
	}
}
func TestSchemaValidationRejects(t *testing.T) {
	for _, tc := range []struct {
		name string
		data []byte
	}{{"missing.schema.json", []byte(`{}`)}, {"catalog.schema.json", []byte(`{"schema_version":"2.0.0"}`)}, {"catalog.schema.json", make([]byte, contract.MaxJSONInputSize+1)}} {
		if err := contract.ValidateJSON(tc.name, tc.data); err == nil {
			t.Fatalf("accepted %s", tc.name)
		}
	}
}

func TestRepresentativeNegativeFixturesReject(t *testing.T) {
	for _, name := range []string{"unsupported-schema-major.json", "invalid-receipt.json"} {
		data, err := os.ReadFile(filepath.Join("..", "..", "..", "experiments", "component-manager-poa0", "contract-v1", "negative-fixtures", name))
		if err != nil {
			t.Fatal(err)
		}
		var wrapper struct {
			SchemaRef string          `json:"$schema_ref"`
			Fixture   json.RawMessage `json:"fixture"`
		}
		if err := json.Unmarshal(data, &wrapper); err != nil {
			t.Fatal(err)
		}
		if err := contract.ValidateJSON(filepath.Base(wrapper.SchemaRef), wrapper.Fixture); err == nil {
			t.Fatalf("accepted %s", name)
		}
	}
}
func removeSchemaRef(t *testing.T, data []byte) []byte {
	t.Helper()
	var object map[string]any
	if err := json.Unmarshal(data, &object); err != nil {
		t.Fatal(err)
	}
	delete(object, "$schema_ref")
	out, err := json.Marshal(object)
	if err != nil {
		t.Fatal(err)
	}
	return out
}
