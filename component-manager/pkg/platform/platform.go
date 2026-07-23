// Package platform defines contract-bound target values.
package platform

import (
	"encoding/json"
	"fmt"
)

type Platform string
type Architecture string
type Backend string

const (
	Linux    Platform     = "linux"
	Windows  Platform     = "windows"
	MacOS    Platform     = "macos"
	X8664    Architecture = "x86_64"
	ARM64    Architecture = "arm64"
	CPU      Backend      = "cpu"
	CUDA     Backend      = "cuda"
	ROCm     Backend      = "rocm"
	DirectML Backend      = "directml"
	MPS      Backend      = "mps"
)

func ParsePlatform(s string) (Platform, error) {
	p := Platform(s)
	if !p.Valid() {
		return "", fmt.Errorf("invalid platform %q", s)
	}
	return p, nil
}
func (p Platform) Valid() bool { return p == Linux || p == Windows || p == MacOS }
func ParseArchitecture(s string) (Architecture, error) {
	a := Architecture(s)
	if !a.Valid() {
		return "", fmt.Errorf("invalid architecture %q", s)
	}
	return a, nil
}
func (a Architecture) Valid() bool { return a == X8664 || a == ARM64 }
func ParseBackend(s string) (Backend, error) {
	b := Backend(s)
	if !b.Valid() {
		return "", fmt.Errorf("invalid backend %q", s)
	}
	return b, nil
}
func (b Backend) Valid() bool { return b == CPU || b == CUDA || b == ROCm || b == DirectML || b == MPS }
func decode(data []byte, set func(string) error) error {
	var s string
	if err := json.Unmarshal(data, &s); err != nil {
		return err
	}
	return set(s)
}
func (p *Platform) UnmarshalJSON(b []byte) error {
	return decode(b, func(s string) error {
		v, e := ParsePlatform(s)
		if e == nil {
			*p = v
		}
		return e
	})
}
func (a *Architecture) UnmarshalJSON(b []byte) error {
	return decode(b, func(s string) error {
		v, e := ParseArchitecture(s)
		if e == nil {
			*a = v
		}
		return e
	})
}
func (b *Backend) UnmarshalJSON(data []byte) error {
	return decode(data, func(s string) error {
		v, e := ParseBackend(s)
		if e == nil {
			*b = v
		}
		return e
	})
}
func (p Platform) MarshalText() ([]byte, error) {
	if !p.Valid() {
		return nil, fmt.Errorf("invalid platform")
	}
	return []byte(p), nil
}
func (p Platform) MarshalJSON() ([]byte, error) {
	b, err := p.MarshalText()
	if err != nil {
		return nil, err
	}
	return json.Marshal(string(b))
}
func (a Architecture) MarshalText() ([]byte, error) {
	if !a.Valid() {
		return nil, fmt.Errorf("invalid architecture")
	}
	return []byte(a), nil
}
func (a Architecture) MarshalJSON() ([]byte, error) {
	b, err := a.MarshalText()
	if err != nil {
		return nil, err
	}
	return json.Marshal(string(b))
}
func (b Backend) MarshalText() ([]byte, error) {
	if !b.Valid() {
		return nil, fmt.Errorf("invalid backend")
	}
	return []byte(b), nil
}
func (b Backend) MarshalJSON() ([]byte, error) {
	data, err := b.MarshalText()
	if err != nil {
		return nil, err
	}
	return json.Marshal(string(data))
}
