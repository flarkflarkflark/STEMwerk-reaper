// Package contract contains stable errors shared by SLICE-0 boundaries.
package contract

import "fmt"

type Category string

const (
	CategorySchemaInvalid          Category = "schema_invalid"
	CategoryIdentityInvalid        Category = "identity_invalid"
	CategoryVersionInvalid         Category = "version_invalid"
	CategoryArtifactDigestMismatch Category = "artifact_digest_mismatch"
	CategoryCatalogInvalid         Category = "catalog_invalid"
	CategoryInternalError          Category = "internal_error"
)

// Error is the stable, machine-readable SLICE-0 error model.
// Detail is diagnostic-only and deliberately excluded from Error().
type Error struct {
	Code        string
	Category    Category
	Operation   string
	Phase       string
	Message     string
	Detail      string
	Retryable   bool
	Recoverable bool
	Cause       error
}

func (e *Error) Error() string {
	if e == nil {
		return "<nil>"
	}
	return fmt.Sprintf("%s: %s", e.Code, e.Message)
}

func (e *Error) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.Cause
}

func Invalid(category Category, code, operation, phase, message, detail string, cause error) *Error {
	return &Error{Code: code, Category: category, Operation: operation, Phase: phase, Message: message, Detail: detail, Cause: cause}
}
