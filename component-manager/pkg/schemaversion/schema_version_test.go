package schemaversion

import (
	"encoding/json"
	"testing"
)

func TestCurrentSchemaVersion(t *testing.T) {
	v, err := Parse("1.0.0")
	if err != nil || v != CurrentWritable || !ReaderSupports(v) {
		t.Fatalf("current version: %v, %#v", err, v)
	}
	data, _ := json.Marshal(v)
	var got Version
	if err := json.Unmarshal(data, &got); err != nil || got != v {
		t.Fatalf("JSON round trip: %v", err)
	}
}

func TestSchemaVersionFailsClosed(t *testing.T) {
	for _, value := range []string{"", "2.0.0", "1.1.0", "1.0", "01.0.0", "1.0.0-alpha"} {
		if _, err := Parse(value); err == nil {
			t.Fatalf("accepted %q", value)
		}
	}
}

func FuzzParseSchemaVersion(f *testing.F) {
	f.Add("1.0.0")
	f.Fuzz(func(t *testing.T, value string) {
		v, err := Parse(value)
		if err == nil && (!v.Valid() || v.String() != value) {
			t.Fatalf("non-deterministic parse for %q", value)
		}
	})
}
