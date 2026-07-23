// Package catalog parses and validates immutable Contract-v1 catalog data.
package catalog

import (
	"encoding/json"
	"fmt"
	"io"

	"github.com/flarkflarkflark/STEMwerk-reaper/component-manager/internal/canonicaljson"
	"github.com/flarkflarkflark/STEMwerk-reaper/component-manager/pkg/component"
	"github.com/flarkflarkflark/STEMwerk-reaper/component-manager/pkg/contract"
	"github.com/flarkflarkflark/STEMwerk-reaper/component-manager/pkg/digest"
	"github.com/flarkflarkflark/STEMwerk-reaper/component-manager/pkg/identity"
	"github.com/flarkflarkflark/STEMwerk-reaper/component-manager/pkg/schemaversion"
	"github.com/flarkflarkflark/STEMwerk-reaper/component-manager/pkg/version"
)

const MaxInputSize = contract.MaxJSONInputSize

type Artifact struct {
	ID     identity.ArtifactID
	Digest digest.Digest
}
type Component struct {
	ID       identity.ComponentID
	Kind     component.ComponentKind
	Version  json.RawMessage
	Artifact Artifact
}
type Flow struct {
	ID                 string
	RequiredComponents []identity.ComponentID
	Outputs            []string
	Pipeline           []string
	ModelFilename      string
}
type Catalog struct {
	SchemaVersion schemaversion.Version
	Version       version.CatalogVersion
	TrustStatus   string
	Components    []Component
	Flows         []Flow
	ID            string
	Sequence      uint64
	Digest        digest.Digest
}

type wireCatalog struct {
	SchemaVersion  string            `json:"schema_version"`
	CatalogVersion string            `json:"catalog_version"`
	TrustStatus    string            `json:"trust_status"`
	Components     []json.RawMessage `json:"components"`
	Flows          []wireFlow        `json:"flows"`
	ID             string            `json:"catalog_id"`
	Sequence       uint64            `json:"sequence"`
	Digest         string            `json:"digest"`
}
type wireFlow struct {
	ID            string   `json:"flow_id"`
	Required      []string `json:"required_components"`
	Outputs       []string `json:"outputs"`
	Pipeline      []string `json:"pipeline"`
	ModelFilename string   `json:"model_filename"`
}
type wireComponent struct {
	SchemaVersion string          `json:"schema_version"`
	ID            string          `json:"component_id"`
	Kind          string          `json:"component_kind"`
	Version       json.RawMessage `json:"version"`
	Artifact      struct {
		ID     string `json:"artifact_id"`
		Digest string `json:"digest"`
	} `json:"artifact"`
}

func ParseBytes(data []byte) (*Catalog, error) {
	if len(data) > MaxInputSize {
		return nil, invalid("catalog input exceeds size limit", nil, contract.CategoryCatalogInvalid)
	}
	if err := contract.ValidateJSON("catalog.schema.json", data); err != nil {
		return nil, invalid("catalog schema validation failed", err, contract.CategoryCatalogInvalid)
	}
	var wire wireCatalog
	if err := json.Unmarshal(data, &wire); err != nil {
		return nil, invalid("catalog JSON decoding failed", err, contract.CategoryCatalogInvalid)
	}
	sv, err := schemaversion.Parse(wire.SchemaVersion)
	if err != nil {
		return nil, invalid("unsupported catalog schema version", err, contract.CategoryCatalogInvalid)
	}
	cv, err := version.ParseCatalogVersion(wire.CatalogVersion)
	if err != nil {
		return nil, invalid("invalid catalog version", err, contract.CategoryCatalogInvalid)
	}
	cd, err := digest.Parse(wire.Digest)
	if err != nil {
		return nil, invalid("invalid catalog digest", err, contract.CategoryCatalogInvalid)
	}
	result := &Catalog{SchemaVersion: sv, Version: cv, TrustStatus: wire.TrustStatus, ID: wire.ID, Sequence: wire.Sequence, Digest: cd}
	seen := make(map[string]digest.Digest)
	for _, raw := range wire.Components {
		if err := contract.ValidateJSON("component.schema.json", raw); err != nil {
			return nil, invalid("component schema validation failed", err, contract.CategoryCatalogInvalid)
		}
		var item wireComponent
		if err := json.Unmarshal(raw, &item); err != nil {
			return nil, invalid("component decoding failed", err, contract.CategoryCatalogInvalid)
		}
		id, err := identity.ParseComponentID(item.ID)
		if err != nil {
			return nil, invalid("invalid component identity", err, contract.CategoryCatalogInvalid)
		}
		kind, err := component.ParseKind(item.Kind)
		if err != nil {
			return nil, invalid("invalid component kind", err, contract.CategoryCatalogInvalid)
		}
		artifactID, err := identity.ParseArtifactID(item.Artifact.ID)
		if err != nil {
			return nil, invalid("invalid artifact identity", err, contract.CategoryCatalogInvalid)
		}
		artifactDigest, err := digest.Parse(item.Artifact.Digest)
		if err != nil {
			return nil, invalid("invalid artifact digest", err, contract.CategoryCatalogInvalid)
		}
		canonicalVersion, err := canonicaljson.Canonicalize(item.Version)
		if err != nil {
			return nil, invalid("invalid component version", err, contract.CategoryCatalogInvalid)
		}
		key := id.String() + "\x00" + string(canonicalVersion)
		if previous, exists := seen[key]; exists {
			if previous != artifactDigest {
				return nil, invalid("same component version has a different artifact digest", nil, contract.CategoryArtifactDigestMismatch)
			}
			return nil, invalid("duplicate component identity and version", nil, contract.CategoryCatalogInvalid)
		}
		seen[key] = artifactDigest
		result.Components = append(result.Components, Component{ID: id, Kind: kind, Version: append(json.RawMessage(nil), item.Version...), Artifact: Artifact{ID: artifactID, Digest: artifactDigest}})
	}
	for _, flow := range wire.Flows {
		if _, err := identity.ParseComponentID(flow.ID); err != nil {
			return nil, invalid("invalid flow identity", err, contract.CategoryCatalogInvalid)
		}
		out := Flow{ID: flow.ID, Outputs: append([]string(nil), flow.Outputs...), Pipeline: append([]string(nil), flow.Pipeline...), ModelFilename: flow.ModelFilename}
		for _, raw := range flow.Required {
			id, err := identity.ParseComponentID(raw)
			if err != nil {
				return nil, invalid("invalid required component identity", err, contract.CategoryCatalogInvalid)
			}
			out.RequiredComponents = append(out.RequiredComponents, id)
		}
		result.Flows = append(result.Flows, out)
	}
	return result, nil
}

func ParseReader(reader io.Reader) (*Catalog, error) {
	data, err := io.ReadAll(io.LimitReader(reader, MaxInputSize+1))
	if err != nil {
		return nil, invalid("catalog read failed", err, contract.CategoryCatalogInvalid)
	}
	return ParseBytes(data)
}

func invalid(message string, cause error, category contract.Category) error {
	return contract.Invalid(category, string(category), "parse_catalog", "validation", message, fmt.Sprint(cause), cause)
}
