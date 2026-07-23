package component

import (
	"encoding/json"
	"testing"
)

func TestKinds(t *testing.T) {
	for _, s := range []string{"runtime", "model", "config", "catalog", "helper", "integration", "metadata"} {
		if _, e := ParseKind(s); e != nil {
			t.Fatal(e)
		}
	}
}
func TestZeroKindDoesNotMarshal(t *testing.T) {
	if _, err := json.Marshal(ComponentKind("")); err == nil {
		t.Fatal("marshaled zero kind")
	}
}
func TestInvalidKind(t *testing.T) {
	if _, e := ParseKind("Runtime"); e == nil {
		t.Fatal("accepted invalid")
	}
}
