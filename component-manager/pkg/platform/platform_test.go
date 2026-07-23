package platform

import (
	"encoding/json"
	"testing"
)

func TestContractValues(t *testing.T) {
	for _, s := range []string{"linux", "windows", "macos"} {
		if _, e := ParsePlatform(s); e != nil {
			t.Fatal(e)
		}
	}
	for _, s := range []string{"x86_64", "arm64"} {
		if _, e := ParseArchitecture(s); e != nil {
			t.Fatal(e)
		}
	}
	for _, s := range []string{"cpu", "cuda", "rocm", "directml", "mps"} {
		if _, e := ParseBackend(s); e != nil {
			t.Fatal(e)
		}
	}
}
func TestZeroValuesDoNotMarshal(t *testing.T) {
	for _, value := range []any{Platform(""), Architecture(""), Backend("")} {
		if _, err := json.Marshal(value); err == nil {
			t.Fatal("marshaled zero value")
		}
	}
}
func TestInvalidValues(t *testing.T) {
	if _, e := ParsePlatform("Linux"); e == nil {
		t.Fatal("accepted invalid")
	}
	if _, e := ParseArchitecture(""); e == nil {
		t.Fatal("accepted invalid")
	}
	if _, e := ParseBackend("vulkan"); e == nil {
		t.Fatal("accepted invalid")
	}
}
