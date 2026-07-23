// Package schemavalidation provides bounded, offline Contract-v1 validation.
package schemavalidation

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"sync"

	"github.com/flarkflarkflark/STEMwerk-reaper/component-manager/schemas"
	jsonschema "github.com/santhosh-tekuri/jsonschema/v6"
)

const MaxInputSize = 4 << 20
const schemaBase = "https://stemwerk.example/contracts/component-manager/v1/"

var compiled struct {
	sync.Once
	values map[string]*jsonschema.Schema
	err    error
}

type offlineLoader struct{}

func (offlineLoader) Load(url string) (any, error) {
	return nil, fmt.Errorf("external schema loading disabled: %s", url)
}

func build() {
	compiled.values = make(map[string]*jsonschema.Schema)
	c := jsonschema.NewCompiler()
	c.DefaultDraft(jsonschema.Draft2020)
	c.UseLoader(offlineLoader{})
	for _, name := range schemas.Names() {
		data, err := schemas.Load(name)
		if err != nil {
			compiled.err = err
			return
		}
		doc, err := jsonschema.UnmarshalJSON(bytes.NewReader(data))
		if err != nil {
			compiled.err = fmt.Errorf("decode schema %s: %w", name, err)
			return
		}
		if err := c.AddResource(schemaBase+name, doc); err != nil {
			compiled.err = fmt.Errorf("bind schema %s: %w", name, err)
			return
		}
	}
	for _, name := range schemas.Names() {
		schema, err := c.Compile(schemaBase + name)
		if err != nil {
			compiled.err = fmt.Errorf("compile schema %s: %w", name, err)
			return
		}
		compiled.values[name] = schema
	}
}

func Validate(name string, data []byte) error {
	if len(data) > MaxInputSize {
		return fmt.Errorf("input exceeds %d bytes", MaxInputSize)
	}
	if !strings.HasSuffix(name, ".schema.json") || strings.ContainsAny(name, `/\\`) {
		return fmt.Errorf("unknown schema %q", name)
	}
	compiled.Do(build)
	if compiled.err != nil {
		return compiled.err
	}
	schema, ok := compiled.values[name]
	if !ok {
		return fmt.Errorf("unknown schema %q", name)
	}
	var value any
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(&value); err != nil {
		return fmt.Errorf("invalid JSON: %w", err)
	}
	if decoder.Decode(&struct{}{}) == nil {
		return fmt.Errorf("invalid JSON: trailing value")
	}
	if object, ok := value.(map[string]any); ok {
		if raw, exists := object["schema_version"]; exists {
			version, ok := raw.(string)
			if !ok || !strings.HasPrefix(version, "1.") {
				return fmt.Errorf("unsupported schema version")
			}
		}
	}
	if err := schema.Validate(value); err != nil {
		return fmt.Errorf("schema validation failed: %w", err)
	}
	return nil
}
