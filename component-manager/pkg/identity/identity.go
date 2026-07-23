// Package identity implements Contract-v1 logical and content-derived identities.
package identity

import (
	"encoding/json"
	"regexp"

	"github.com/flarkflarkflark/STEMwerk-reaper/component-manager/pkg/contract"
)

var (
	logicalPattern = regexp.MustCompile("^[a-z0-9]+(?:[._-][a-z0-9]+)*$")
	contentPattern = regexp.MustCompile("^[a-f0-9]{64}$")
)

type ComponentID struct{ value string }
type ArtifactID struct{ value string }
type ModelID struct{ value string }
type GenerationID struct{ value string }
type ReceiptID struct{ value string }

func parseLogical(kind, value string) (string, error) {
	if !logicalPattern.MatchString(value) {
		return "", invalid(kind, value, nil)
	}
	return value, nil
}

func parseContent(kind, prefix, value string) (string, error) {
	if len(value) != len(prefix)+64 || value[:min(len(value), len(prefix))] != prefix ||
		!contentPattern.MatchString(value[len(prefix):]) {
		return "", invalid(kind, value, nil)
	}
	return value, nil
}

func ParseComponentID(value string) (ComponentID, error) {
	v, err := parseLogical("component_id", value)
	return ComponentID{v}, err
}
func ParseModelID(value string) (ModelID, error) {
	v, err := parseLogical("model_id", value)
	return ModelID{v}, err
}
func ParseArtifactID(value string) (ArtifactID, error) {
	v, err := parseContent("artifact_id", "artifact.sha256.", value)
	return ArtifactID{v}, err
}
func ParseGenerationID(value string) (GenerationID, error) {
	v, err := parseContent("generation_id", "generation.sha256.", value)
	return GenerationID{v}, err
}
func ParseReceiptID(value string) (ReceiptID, error) {
	v, err := parseContent("receipt_id", "receipt.sha256.", value)
	return ReceiptID{v}, err
}

func (v ComponentID) String() string  { return v.value }
func (v ArtifactID) String() string   { return v.value }
func (v ModelID) String() string      { return v.value }
func (v GenerationID) String() string { return v.value }
func (v ReceiptID) String() string    { return v.value }

func (v ComponentID) Valid() bool  { return logicalPattern.MatchString(v.value) }
func (v ModelID) Valid() bool      { return logicalPattern.MatchString(v.value) }
func (v ArtifactID) Valid() bool   { return validContent(v.value, "artifact.sha256.") }
func (v GenerationID) Valid() bool { return validContent(v.value, "generation.sha256.") }
func (v ReceiptID) Valid() bool    { return validContent(v.value, "receipt.sha256.") }
func validContent(value, prefix string) bool {
	return len(value) == len(prefix)+64 && value[:len(prefix)] == prefix && contentPattern.MatchString(value[len(prefix):])
}

func marshal(value string, valid bool) ([]byte, error) {
	if !valid {
		return nil, invalid("zero_value", value, nil)
	}
	return json.Marshal(value)
}
func decode(data []byte, set func(string) error) error {
	var value string
	if err := json.Unmarshal(data, &value); err != nil {
		return invalid("json_identity", "", err)
	}
	return set(value)
}
func text(value string, valid bool) ([]byte, error) {
	if !valid {
		return nil, invalid("zero_value", value, nil)
	}
	return []byte(value), nil
}

func (v ComponentID) MarshalJSON() ([]byte, error)  { return marshal(v.value, v.Valid()) }
func (v ArtifactID) MarshalJSON() ([]byte, error)   { return marshal(v.value, v.Valid()) }
func (v ModelID) MarshalJSON() ([]byte, error)      { return marshal(v.value, v.Valid()) }
func (v GenerationID) MarshalJSON() ([]byte, error) { return marshal(v.value, v.Valid()) }
func (v ReceiptID) MarshalJSON() ([]byte, error)    { return marshal(v.value, v.Valid()) }

func (v *ComponentID) UnmarshalJSON(data []byte) error {
	return decode(data, func(s string) error { parsed, err := ParseComponentID(s); *v = parsed; return err })
}
func (v *ArtifactID) UnmarshalJSON(data []byte) error {
	return decode(data, func(s string) error { parsed, err := ParseArtifactID(s); *v = parsed; return err })
}
func (v *ModelID) UnmarshalJSON(data []byte) error {
	return decode(data, func(s string) error { parsed, err := ParseModelID(s); *v = parsed; return err })
}
func (v *GenerationID) UnmarshalJSON(data []byte) error {
	return decode(data, func(s string) error { parsed, err := ParseGenerationID(s); *v = parsed; return err })
}
func (v *ReceiptID) UnmarshalJSON(data []byte) error {
	return decode(data, func(s string) error { parsed, err := ParseReceiptID(s); *v = parsed; return err })
}

func (v ComponentID) MarshalText() ([]byte, error)  { return text(v.value, v.Valid()) }
func (v ArtifactID) MarshalText() ([]byte, error)   { return text(v.value, v.Valid()) }
func (v ModelID) MarshalText() ([]byte, error)      { return text(v.value, v.Valid()) }
func (v GenerationID) MarshalText() ([]byte, error) { return text(v.value, v.Valid()) }
func (v ReceiptID) MarshalText() ([]byte, error)    { return text(v.value, v.Valid()) }
func (v *ComponentID) UnmarshalText(data []byte) error {
	parsed, err := ParseComponentID(string(data))
	*v = parsed
	return err
}
func (v *ArtifactID) UnmarshalText(data []byte) error {
	parsed, err := ParseArtifactID(string(data))
	*v = parsed
	return err
}
func (v *ModelID) UnmarshalText(data []byte) error {
	parsed, err := ParseModelID(string(data))
	*v = parsed
	return err
}
func (v *GenerationID) UnmarshalText(data []byte) error {
	parsed, err := ParseGenerationID(string(data))
	*v = parsed
	return err
}
func (v *ReceiptID) UnmarshalText(data []byte) error {
	parsed, err := ParseReceiptID(string(data))
	*v = parsed
	return err
}

func invalid(kind, value string, cause error) error {
	return contract.Invalid(contract.CategoryIdentityInvalid, "identity_invalid", "parse_identity", "validate", "invalid "+kind, value, cause)
}
