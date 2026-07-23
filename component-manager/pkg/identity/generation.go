package identity

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"

	"github.com/flarkflarkflark/STEMwerk-reaper/component-manager/internal/canonicaljson"
)

func DeriveGenerationID(manifestJSON []byte) (GenerationID, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(manifestJSON, &fields); err != nil || fields == nil {
		return GenerationID{}, fmt.Errorf("generation manifest must be a JSON object")
	}
	delete(fields, "generation_id")
	withoutID, err := json.Marshal(fields)
	if err != nil {
		return GenerationID{}, fmt.Errorf("encode generation manifest: %w", err)
	}
	canonical, err := canonicaljson.Canonicalize(withoutID)
	if err != nil {
		return GenerationID{}, err
	}
	hash := sha256.Sum256(canonical)
	return ParseGenerationID("generation.sha256." + hex.EncodeToString(hash[:]))
}

func VerifyGenerationID(manifestJSON []byte, supplied GenerationID) error {
	derived, err := DeriveGenerationID(manifestJSON)
	if err != nil {
		return err
	}
	if derived != supplied {
		return fmt.Errorf("generation identity does not match canonical manifest")
	}
	return nil
}
