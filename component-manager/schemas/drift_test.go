package schemas

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func repositoryRoot(t *testing.T) string {
	t.Helper()
	command := exec.Command("git", "rev-parse", "--show-toplevel")
	output, err := command.Output()
	if err != nil {
		t.Fatalf("resolve repository root: %v", err)
	}
	return strings.TrimSpace(string(output))
}

func gitBlob(t *testing.T, repository, path string) []byte {
	t.Helper()
	command := exec.Command("git", "show", "HEAD:"+filepath.ToSlash(path))
	command.Dir = repository
	output, err := command.Output()
	if err != nil {
		t.Fatalf("read Git blob %s: %v", path, err)
	}
	return output
}

func TestAuthoritativeSchemasByteEqualAndManifestPinned(t *testing.T) {
	repository := repositoryRoot(t)
	manifestData := gitBlob(t, repository, filepath.Join("component-manager", "schemas", "SHA256SUMS"))
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
		authoritative := gitBlob(t, repository, filepath.Join("experiments", "component-manager-poa0", "contract-v1", "schemas", name))
		embedSource := gitBlob(t, repository, filepath.Join("component-manager", "schemas", name))
		if !bytes.Equal(embedSource, authoritative) {
			t.Errorf("embedded source Git blob drift: %s", name)
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
