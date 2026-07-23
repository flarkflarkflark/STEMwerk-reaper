package identity

import "testing"

func TestGenerationIDDerivationOmitsSelfReference(t *testing.T) {
	without := []byte(`{"schema_version":"1.0.0","components":[]}`)
	first, err := DeriveGenerationID(without)
	if err != nil {
		t.Fatal(err)
	}
	with := []byte(`{"components":[],"generation_id":"generation.sha256.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","schema_version":"1.0.0"}`)
	second, err := DeriveGenerationID(with)
	if err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Fatalf("self-reference affected identity: %s != %s", first, second)
	}
	if first.String() != "generation.sha256.0c28b428b93234f8b8fd20718ca42dbacb03635d9eed9bab3cfdbfddd55732d1" {
		t.Fatalf("fixed vector changed: %s", first)
	}
	if err := VerifyGenerationID(with, first); err != nil {
		t.Fatal(err)
	}
}
func TestGenerationIDMismatch(t *testing.T) {
	id, _ := ParseGenerationID("generation.sha256.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	if err := VerifyGenerationID([]byte(`{}`), id); err == nil {
		t.Fatal("accepted mismatch")
	}
}
