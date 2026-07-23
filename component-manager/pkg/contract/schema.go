package contract

import "github.com/flarkflarkflark/STEMwerk-reaper/component-manager/internal/schemavalidation"

const MaxJSONInputSize = schemavalidation.MaxInputSize

func ValidateJSON(schemaName string, data []byte) error {
	if err := schemavalidation.Validate(schemaName, data); err != nil {
		return Invalid(CategorySchemaInvalid, "schema_invalid", "validate_json", "schema_validation", "schema validation failed", err.Error(), err)
	}
	return nil
}
