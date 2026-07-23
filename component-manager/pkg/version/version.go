// Package version implements Contract-v1 software and model revisions.
package version

import (
	"encoding/json"
	"regexp"
	"strconv"
	"strings"

	"github.com/flarkflarkflark/STEMwerk-reaper/component-manager/pkg/contract"
)

var semverPattern = regexp.MustCompile("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*))?(?:\\+([0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*))?$")

type SoftwareVersion struct {
	raw             string
	major           uint64
	minor           uint64
	patch           uint64
	prerelease      string
	packageRevision int64
	valid           bool
}

type softwareJSON struct {
	Version         string `json:"version"`
	PackageRevision int64  `json:"package_revision"`
}

func ParseSoftwareVersion(value string, packageRevision int64) (SoftwareVersion, error) {
	m := semverPattern.FindStringSubmatch(value)
	if m == nil || packageRevision < 0 || invalidNumericPrerelease(m[4]) {
		return SoftwareVersion{}, invalid("software version", value, nil)
	}
	major, err1 := strconv.ParseUint(m[1], 10, 64)
	minor, err2 := strconv.ParseUint(m[2], 10, 64)
	patch, err3 := strconv.ParseUint(m[3], 10, 64)
	if err1 != nil || err2 != nil || err3 != nil {
		return SoftwareVersion{}, invalid("software version", value, nil)
	}
	return SoftwareVersion{raw: value, major: major, minor: minor, patch: patch, prerelease: m[4], packageRevision: packageRevision, valid: true}, nil
}

func invalidNumericPrerelease(pre string) bool {
	for _, part := range strings.Split(pre, ".") {
		if len(part) > 1 && part[0] == '0' {
			if _, err := strconv.ParseUint(part, 10, 64); err == nil {
				return true
			}
		}
	}
	return false
}

func (v SoftwareVersion) String() string         { return v.raw }
func (v SoftwareVersion) Valid() bool            { return v.valid }
func (v SoftwareVersion) PackageRevision() int64 { return v.packageRevision }

func (v SoftwareVersion) Compare(other SoftwareVersion) int {
	for _, pair := range [][2]uint64{{v.major, other.major}, {v.minor, other.minor}, {v.patch, other.patch}} {
		if pair[0] < pair[1] {
			return -1
		}
		if pair[0] > pair[1] {
			return 1
		}
	}
	if result := comparePrerelease(v.prerelease, other.prerelease); result != 0 {
		return result
	}
	if v.packageRevision < other.packageRevision {
		return -1
	}
	if v.packageRevision > other.packageRevision {
		return 1
	}
	return 0
}

func comparePrerelease(a, b string) int {
	if a == b {
		return 0
	}
	if a == "" {
		return 1
	}
	if b == "" {
		return -1
	}
	ap, bp := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(ap) && i < len(bp); i++ {
		if ap[i] == bp[i] {
			continue
		}
		an, ae := strconv.ParseUint(ap[i], 10, 64)
		bn, be := strconv.ParseUint(bp[i], 10, 64)
		switch {
		case ae == nil && be == nil:
			if an < bn {
				return -1
			}
			return 1
		case ae == nil:
			return -1
		case be == nil:
			return 1
		case ap[i] < bp[i]:
			return -1
		default:
			return 1
		}
	}
	if len(ap) < len(bp) {
		return -1
	}
	return 1
}

func (v SoftwareVersion) MarshalJSON() ([]byte, error) {
	if !v.valid {
		return nil, invalid("software version", "", nil)
	}
	return json.Marshal(softwareJSON{v.raw, v.packageRevision})
}
func (v *SoftwareVersion) UnmarshalJSON(data []byte) error {
	var raw softwareJSON
	if err := json.Unmarshal(data, &raw); err != nil {
		return invalid("software version", "", err)
	}
	parsed, err := ParseSoftwareVersion(raw.Version, raw.PackageRevision)
	*v = parsed
	return err
}

type ModelRevision struct{ value string }

type CatalogVersion struct{ value string }

func ParseCatalogVersion(value string) (CatalogVersion, error) {
	if value == "" {
		return CatalogVersion{}, invalid("catalog version", value, nil)
	}
	return CatalogVersion{value}, nil
}
func (v CatalogVersion) String() string { return v.value }
func (v CatalogVersion) Valid() bool    { return v.value != "" }
func (v CatalogVersion) MarshalText() ([]byte, error) {
	if !v.Valid() {
		return nil, invalid("catalog version", "", nil)
	}
	return []byte(v.value), nil
}
func (v *CatalogVersion) UnmarshalText(data []byte) error {
	n, e := ParseCatalogVersion(string(data))
	if e == nil {
		*v = n
	}
	return e
}
func (v CatalogVersion) MarshalJSON() ([]byte, error) {
	b, e := v.MarshalText()
	if e != nil {
		return nil, e
	}
	return json.Marshal(string(b))
}
func (v *CatalogVersion) UnmarshalJSON(data []byte) error {
	var s string
	if e := json.Unmarshal(data, &s); e != nil {
		return e
	}
	return v.UnmarshalText([]byte(s))
}

func ParseModelRevision(value string) (ModelRevision, error) {
	if value == "" || strings.TrimSpace(value) != value || strings.ContainsAny(value, "\r\n\t\x00") {
		return ModelRevision{}, invalid("model revision", value, nil)
	}
	return ModelRevision{value}, nil
}
func (v ModelRevision) String() string { return v.value }
func (v ModelRevision) Valid() bool {
	parsed, err := ParseModelRevision(v.value)
	return err == nil && parsed == v
}
func (v ModelRevision) MarshalJSON() ([]byte, error) {
	if !v.Valid() {
		return nil, invalid("model revision", "", nil)
	}
	return json.Marshal(v.value)
}
func (v *ModelRevision) UnmarshalJSON(data []byte) error {
	var value string
	if err := json.Unmarshal(data, &value); err != nil {
		return invalid("model revision", "", err)
	}
	parsed, err := ParseModelRevision(value)
	*v = parsed
	return err
}
func (v ModelRevision) MarshalText() ([]byte, error) {
	if !v.Valid() {
		return nil, invalid("model revision", "", nil)
	}
	return []byte(v.value), nil
}
func (v *ModelRevision) UnmarshalText(data []byte) error {
	parsed, err := ParseModelRevision(string(data))
	*v = parsed
	return err
}
func invalid(kind, value string, cause error) error {
	return contract.Invalid(contract.CategoryVersionInvalid, "version_invalid", "parse_version", "validate", "invalid "+kind, value, cause)
}
