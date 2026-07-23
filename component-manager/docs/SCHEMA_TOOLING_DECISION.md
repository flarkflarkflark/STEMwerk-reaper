# Schema tooling decision

Selected: `github.com/santhosh-tekuri/jsonschema/v6@v6.0.2`, Apache-2.0. It supports JSON Schema Draft 2020-12, local references, preloaded resources, a custom loader, offline compilation, format assertions, and structured errors. SLICE-0 installs an always-deny URL loader and preloads exactly the 21 embedded schemas.

Bounded candidates (three):

1. santhosh-tekuri/jsonschema/v6 — selected for explicit Draft 2020-12 and loader/resource APIs.
2. qri-io/jsonschema — rejected for this slice because the reviewed primary material did not establish an equally clear stable Draft 2020-12/offline API.
3. xeipuuv/gojsonschema — rejected because its documented dialect support does not meet Draft 2020-12.

Primary sources: `https://github.com/santhosh-tekuri/jsonschema`, `https://pkg.go.dev/github.com/santhosh-tekuri/jsonschema/v6`. A generator is `TO_BE_SELECTED`: handwritten strong types plus runtime validation cover SLICE-0. Generated bindings require a later bounded proof of schema coverage, deterministic output, semantic strong-type preservation, license, maintenance, and drift behavior.
