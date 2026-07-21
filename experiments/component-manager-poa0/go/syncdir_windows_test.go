//go:build windows

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSyncDirRejectsMissingDirectory(t *testing.T) {
	if err := syncDir(filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Fatal("missing directory unexpectedly synced")
	}
}

func TestSyncDirRejectsFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(path, []byte("fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := syncDir(path); err == nil {
		t.Fatal("file unexpectedly accepted as directory")
	}
}

func TestSyncDirFlushesDirectory(t *testing.T) {
	if err := syncDir(t.TempDir()); err != nil {
		t.Fatal(err)
	}
}
