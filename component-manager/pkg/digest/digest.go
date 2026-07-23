// Package digest implements strict SHA-256 digest values.
package digest

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"

	"github.com/flarkflarkflark/STEMwerk-reaper/component-manager/pkg/contract"
)

type Digest struct {
	sum   [sha256.Size]byte
	valid bool
}

func Parse(value string) (Digest, error) {
	const prefix = "sha256:"
	if len(value) != len(prefix)+sha256.Size*2 || value[:min(len(value), len(prefix))] != prefix {
		return Digest{}, invalid(value, nil)
	}
	raw := value[len(prefix):]
	for _, c := range raw {
		if !('0' <= c && c <= '9') && !('a' <= c && c <= 'f') {
			return Digest{}, invalid(value, nil)
		}
	}
	decoded, err := hex.DecodeString(raw)
	if err != nil || len(decoded) != sha256.Size {
		return Digest{}, invalid(value, err)
	}
	var sum [sha256.Size]byte
	copy(sum[:], decoded)
	return Digest{sum: sum, valid: true}, nil
}

func FromBytes(data []byte) Digest { return Digest{sum: sha256.Sum256(data), valid: true} }
func (d Digest) Valid() bool       { return d.valid }
func (d Digest) String() string {
	if !d.valid {
		return ""
	}
	return "sha256:" + hex.EncodeToString(d.sum[:])
}
func (d Digest) MarshalJSON() ([]byte, error) {
	if !d.valid {
		return nil, invalid("", nil)
	}
	return json.Marshal(d.String())
}
func (d *Digest) UnmarshalJSON(data []byte) error {
	var value string
	if err := json.Unmarshal(data, &value); err != nil {
		return invalid("", err)
	}
	parsed, err := Parse(value)
	*d = parsed
	return err
}
func (d Digest) MarshalText() ([]byte, error) {
	if !d.valid {
		return nil, invalid("", nil)
	}
	return []byte(d.String()), nil
}
func (d *Digest) UnmarshalText(data []byte) error {
	parsed, err := Parse(string(data))
	*d = parsed
	return err
}
func invalid(value string, cause error) error {
	return contract.Invalid(contract.CategoryIdentityInvalid, "digest_invalid", "parse_digest", "validate", "invalid SHA-256 digest", value, cause)
}
