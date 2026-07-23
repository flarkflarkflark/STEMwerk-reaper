package schemavalidation

import "testing"

func TestOfflineLoaderRejectsRemoteReference(t *testing.T) {
	if _, err := (offlineLoader{}).Load("https://remote.invalid/schema.json"); err == nil {
		t.Fatal("remote schema reference accepted")
	}
}
