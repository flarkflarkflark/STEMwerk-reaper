// Package schemaversion implements Contract-v1 schema-family version gates.
package schemaversion

import (
	"encoding/json"
	"strconv"
	"strings"

	"github.com/flarkflarkflark/STEMwerk-reaper/component-manager/pkg/contract"
)

type Version struct {
	Major uint64
	Minor uint64
	Patch uint64
	valid bool
}

// SchemaVersion is the contract name for Version.
type SchemaVersion = Version

var CurrentWritable = Version{Major: 1, Minor: 0, Patch: 0, valid: true}

func Parse(value string) (Version, error) {
	parts := strings.Split(value, ".")
	if len(parts) != 3 {
		return Version{}, invalid(value, nil)
	}
	nums := [3]uint64{}
	for i, part := range parts {
		if part == "" || (len(part) > 1 && part[0] == '0') {
			return Version{}, invalid(value, nil)
		}
		n, err := strconv.ParseUint(part, 10, 64)
		if err != nil {
			return Version{}, invalid(value, err)
		}
		nums[i] = n
	}
	v := Version{Major: nums[0], Minor: nums[1], Patch: nums[2], valid: true}
	if !ReaderSupports(v) {
		return Version{}, invalid(value, nil)
	}
	return v, nil
}
func ReaderSupports(v Version) bool {
	return v.valid && v.Major == 1 && v.Minor <= CurrentWritable.Minor
}
func (v Version) Valid() bool { return ReaderSupports(v) }
func (v Version) String() string {
	if !v.valid {
		return ""
	}
	return strconv.FormatUint(v.Major, 10) + "." + strconv.FormatUint(v.Minor, 10) + "." + strconv.FormatUint(v.Patch, 10)
}
func (v Version) MarshalJSON() ([]byte, error) {
	if !v.Valid() {
		return nil, invalid("", nil)
	}
	return json.Marshal(v.String())
}
func (v *Version) UnmarshalJSON(data []byte) error {
	var value string
	if err := json.Unmarshal(data, &value); err != nil {
		return invalid("", err)
	}
	parsed, err := Parse(value)
	*v = parsed
	return err
}
func (v Version) MarshalText() ([]byte, error) {
	if !v.Valid() {
		return nil, invalid("", nil)
	}
	return []byte(v.String()), nil
}
func (v *Version) UnmarshalText(data []byte) error {
	parsed, err := Parse(string(data))
	*v = parsed
	return err
}
func invalid(value string, cause error) error {
	return contract.Invalid(contract.CategorySchemaInvalid, "schema_version_unsupported", "parse_schema_version", "validate", "unsupported schema version", value, cause)
}
