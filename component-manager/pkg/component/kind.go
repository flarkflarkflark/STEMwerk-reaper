// Package component defines contract-bound component metadata.
package component

import (
	"encoding/json"
	"fmt"
)

type ComponentKind string

const (
	Runtime     ComponentKind = "runtime"
	Model       ComponentKind = "model"
	Config      ComponentKind = "config"
	Catalog     ComponentKind = "catalog"
	Helper      ComponentKind = "helper"
	Integration ComponentKind = "integration"
	Metadata    ComponentKind = "metadata"
)

func ParseKind(s string) (ComponentKind, error) {
	k := ComponentKind(s)
	if !k.Valid() {
		return "", fmt.Errorf("invalid component kind %q", s)
	}
	return k, nil
}
func (k ComponentKind) Valid() bool {
	switch k {
	case Runtime, Model, Config, Catalog, Helper, Integration, Metadata:
		return true
	}
	return false
}
func (k ComponentKind) String() string { return string(k) }
func (k ComponentKind) MarshalText() ([]byte, error) {
	if !k.Valid() {
		return nil, fmt.Errorf("invalid component kind")
	}
	return []byte(k), nil
}
func (k ComponentKind) MarshalJSON() ([]byte, error) {
	b, err := k.MarshalText()
	if err != nil {
		return nil, err
	}
	return json.Marshal(string(b))
}
func (k *ComponentKind) UnmarshalJSON(b []byte) error {
	var s string
	if e := json.Unmarshal(b, &s); e != nil {
		return e
	}
	v, e := ParseKind(s)
	if e == nil {
		*k = v
	}
	return e
}
