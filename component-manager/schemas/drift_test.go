package schemas

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAuthoritativeSchemasByteEqualAndManifestPinned(t *testing.T) {
	manifestData, err := os.ReadFile("SHA256SUMS")
	if err != nil {
		t.Fatal(err)
	}
	manifest := make(map[string]string)
	for _, line := range strings.Split(strings.TrimSpace(string(manifestData)), "\n") {
		fields := strings.Fields(line)
		if len(fields) != 2 {
			t.Fatalf("invalid manifest line %q", line)
		}
		manifest[fields[1]] = fields[0]
	}
	if len(Names()) != 21 || len(manifest) != 21 {
		t.Fatalf("schema count=%d manifest count=%d", len(Names()), len(manifest))
	}
	for _, name := range Names() {
		embedded, err := Load(name)
		if err != nil {
			t.Fatal(err)
		}
		authoritative, err := os.ReadFile(filepath.Join("..", "..", "experiments", "component-manager-poa0", "contract-v1", "schemas", name))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(embedded, authoritative) {
			t.Errorf("schema drift: %s", name)
		}
		sum := fmt.Sprintf("%x", sha256.Sum256(embedded))
		if manifest[name] != sum {
			t.Errorf("manifest mismatch: %s", name)
		}
	}
}
