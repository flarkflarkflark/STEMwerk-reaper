// Package canonicaljson wraps the pinned RFC 8785 implementation.
package canonicaljson

import (
	"fmt"

	"github.com/gowebpki/jcs"
)

const MaxInputSize = 4 << 20

func Canonicalize(data []byte) ([]byte, error) {
	if len(data) > MaxInputSize {
		return nil, fmt.Errorf("canonical JSON input exceeds %d bytes", MaxInputSize)
	}
	result, err := jcs.Transform(data)
	if err != nil {
		return nil, fmt.Errorf("canonicalize RFC8785 JSON: %w", err)
	}
	return result, nil
}
