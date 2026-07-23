package contract

import (
	"errors"
	"strings"
	"testing"
)

func TestErrorModelPreservesCauseAndRedactsDetail(t *testing.T) {
	cause := errors.New("cause")
	err := Invalid(CategoryCatalogInvalid, "catalog_invalid", "parse_catalog", "validation", "catalog rejected", "/absolute/private/path", cause)
	if !errors.Is(err, cause) {
		t.Fatal("cause not preserved")
	}
	if strings.Contains(err.Error(), "/absolute") {
		t.Fatal("diagnostic detail leaked")
	}
	if err.Retryable || err.Recoverable {
		t.Fatal("invalid error unexpectedly retryable or recoverable")
	}
}

func TestRequiredErrorCategoriesStable(t *testing.T) {
	got := []Category{CategorySchemaInvalid, CategoryIdentityInvalid, CategoryVersionInvalid, CategoryArtifactDigestMismatch, CategoryCatalogInvalid, CategoryInternalError}
	want := []string{"schema_invalid", "identity_invalid", "version_invalid", "artifact_digest_mismatch", "catalog_invalid", "internal_error"}
	for i := range want {
		if string(got[i]) != want[i] {
			t.Fatalf("category %d changed", i)
		}
	}
}
