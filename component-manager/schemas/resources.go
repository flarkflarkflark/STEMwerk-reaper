// Package schemas embeds the byte-exact Contract-v1 JSON schemas.
package schemas

import (
	"embed"
	"fmt"
	"sort"
)

//go:embed *.schema.json
var files embed.FS

func Names() []string {
	entries, _ := files.ReadDir(".")
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() {
			names = append(names, entry.Name())
		}
	}
	sort.Strings(names)
	return names
}

func Load(name string) ([]byte, error) {
	data, err := files.ReadFile(name)
	if err != nil {
		return nil, fmt.Errorf("unknown contract schema %q", name)
	}
	return append([]byte(nil), data...), nil
}
