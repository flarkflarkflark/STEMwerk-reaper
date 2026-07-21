// EXPERIMENTAL_DISPOSABLE_POA_ONLY
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const managerVersion = "poa0-go"

type component struct {
	ID, Version, Artifact, SHA256 string
	DownloadSize, InstalledSize   int64
}
type receipt struct {
	SchemaVersion          int      `json:"schema_version"`
	ComponentID            string   `json:"component_id"`
	ComponentVersion       string   `json:"component_version"`
	ArtifactID             string   `json:"artifact_id"`
	ArtifactSHA256         string   `json:"artifact_sha256"`
	CatalogVersion         string   `json:"catalog_version"`
	CatalogEntryHash       string   `json:"catalog_entry_hash"`
	Platform               string   `json:"platform"`
	Architecture           string   `json:"architecture"`
	Backend                string   `json:"backend"`
	InstallTimestamp       string   `json:"install_timestamp"`
	InstalledFilesManifest []string `json:"installed_files_manifest"`
	TransactionID          string   `json:"transaction_id"`
	SourceType             string   `json:"source_type"`
	ProvenanceStatus       string   `json:"provenance_status"`
	ManagerVersion         string   `json:"manager_version"`
}
type generation struct {
	SchemaVersion          int               `json:"schema_version"`
	GenerationID           string            `json:"generation_id"`
	CatalogVersion         string            `json:"catalog_version"`
	CreatedAt              string            `json:"created_at"`
	SelectedFlows          []string          `json:"selected_flows"`
	Backend                string            `json:"backend"`
	Components             []string          `json:"components"`
	ComponentReceiptHashes map[string]string `json:"component_receipt_hashes"`
	PreviousGeneration     string            `json:"previous_generation"`
	PlanHash               string            `json:"plan_hash"`
}
type result struct {
	OK                 bool   `json:"ok"`
	OpID               string `json:"op_id"`
	ErrorCode          string `json:"error_code"`
	Message            string `json:"message"`
	ActiveGeneration   string `json:"active_generation"`
	PreviousGeneration string `json:"previous_generation"`
	State              string `json:"state"`
	LogPath            string `json:"log_path"`
}

var components = []component{
	{"runtime.fixture", "1.0.0", "runtime-fixture.txt", "a159ce98c9da7498ff385b4b799e4bac64313de699878e793654929a95e1bab5", 27, 27},
	{"model.fixture", "1.0.0", "model-fixture.txt", "d76c207e3cb3217db5350a9c8f58daeac9ff845f5a368d3583df2e05d2f36fcf", 25, 25},
}

var journalRoot string

func appendJournal(line string) {
	if journalRoot == "" {
		return
	}
	dir := filepath.Join(journalRoot, "state", "journal")
	if _, e := os.Stat(dir); e != nil {
		return
	}
	f, e := os.OpenFile(filepath.Join(dir, "operations.jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if e == nil {
		_, _ = f.WriteString(line + "\n")
		_ = f.Close()
	}
}
func emit(v any) {
	b, _ := json.Marshal(v)
	line := string(b)
	fmt.Println(line)
	appendJournal(line)
}
func event(op, name string) { emit(map[string]any{"schema_version": 1, "event": name, "op_id": op}) }
func fail(op, code, message, active, previous, state, log string) error {
	event(op, "op_failed")
	emit(result{false, op, code, message, active, previous, state, log})
	return errors.New(message)
}
func writeJSON(path string, v any) error {
	b, e := json.MarshalIndent(v, "", "  ")
	if e != nil {
		return e
	}
	b = append(b, '\n')
	return os.WriteFile(path, b, 0644)
}
func readActive(root string) string {
	b, e := os.ReadFile(filepath.Join(root, "state", "active"))
	if e != nil {
		return ""
	}
	var v struct {
		GenerationID string `json:"generation_id"`
	}
	if json.Unmarshal(b, &v) != nil {
		return ""
	}
	return v.GenerationID
}
func hashFile(path string) (string, error) {
	f, e := os.Open(path)
	if e != nil {
		return "", e
	}
	defer f.Close()
	h := sha256.New()
	if _, e = io.Copy(h, f); e != nil {
		return "", e
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
func activate(root, id string) error {
	state := filepath.Join(root, "state")
	tmp := filepath.Join(state, "active.tmp")
	if e := writeJSON(tmp, map[string]any{"schema_version": 1, "generation_id": id}); e != nil {
		return e
	}
	f, e := os.OpenFile(tmp, os.O_RDWR, 0)
	if e != nil {
		return e
	}
	e = f.Sync()
	f.Close()
	if e != nil {
		return e
	}
	if e = os.Rename(tmp, filepath.Join(state, "active")); e != nil {
		return e
	}
	return syncDir(state)
}
func sqlite(root string, statements string) error {
	db := filepath.Join(root, "state", "state.db")
	c := exec.Command("sqlite3", db)
	c.Stdin = strings.NewReader("PRAGMA journal_mode=WAL;" + statements)
	c.Stderr = os.Stderr
	return c.Run()
}
func initRoot(root string) error {
	for _, p := range []string{"staging", "store/components", "generations", "state/journal", "state/leases"} {
		if e := os.MkdirAll(filepath.Join(root, p), 0755); e != nil {
			return e
		}
	}
	if _, e := os.Stat(filepath.Join(root, "state", "desired.json")); os.IsNotExist(e) {
		writeJSON(filepath.Join(root, "state", "desired.json"), map[string]any{"schema_version": 1, "selected_flows": []string{"flow.normal_stems_fixture"}})
	}
	if _, e := os.Stat(filepath.Join(root, "state", "settings.json")); os.IsNotExist(e) {
		writeJSON(filepath.Join(root, "state", "settings.json"), map[string]any{"schema_version": 1, "backend": "fixture", "pins": map[string]string{}})
	}
	return nil
}
func dbSchema(root string) error {
	return sqlite(root, `CREATE TABLE IF NOT EXISTS inventory(component_id TEXT,version TEXT,receipt_hash TEXT,PRIMARY KEY(component_id,version));CREATE TABLE IF NOT EXISTS ownership(component_id TEXT,path TEXT);CREATE TABLE IF NOT EXISTS consumers(component_id TEXT,flow_id TEXT);CREATE TABLE IF NOT EXISTS generations(generation_id TEXT PRIMARY KEY,active INTEGER,previous_generation TEXT);CREATE TABLE IF NOT EXISTS operations(op_id TEXT PRIMARY KEY,status TEXT);`)
}
func argsValue(name, fallback string) string {
	for i := 2; i < len(os.Args)-1; i++ {
		if os.Args[i] == name {
			return os.Args[i+1]
		}
	}
	return fallback
}
func fixtureDir(catalog string) string { return filepath.Join(filepath.Dir(catalog), "artifacts") }
func planHash() string {
	h := sha256.Sum256([]byte("poa0-v1|flow.normal_stems_fixture|model.fixture@1.0.0|runtime.fixture@1.0.0"))
	return hex.EncodeToString(h[:])
}
func plan(op, root string) {
	event(op, "op_started")
	event(op, "plan_ready")
	emit(map[string]any{"schema_version": 1, "op_id": op, "flow": "flow.normal_stems_fixture", "components": []string{"model.fixture", "runtime.fixture"}, "download_size": 52, "installed_size": 52, "plan_hash": planHash()})
	emit(result{true, op, "", "plan ready", readActive(root), "", "unchanged", ""})
}
func lock(root string) (func(), error) {
	p := filepath.Join(root, "state", "mutation.lock")
	if e := os.Mkdir(p, 0755); e != nil {
		return nil, e
	}
	return func() { os.Remove(p) }, nil
}

func install(op, root, catalog string) error {
	if e := initRoot(root); e != nil {
		return e
	}
	unlock, e := lock(root)
	if e != nil {
		return fail(op, "MUTATION_LOCKED", "another mutation is active", readActive(root), "", "preserved", "")
	}
	defer unlock()
	previous := readActive(root)
	event(op, "op_started")
	event(op, "plan_ready")
	stage := filepath.Join(root, "staging", op)
	if e = os.MkdirAll(stage, 0755); e != nil {
		return e
	}
	event(op, "staging_started")
	if os.Getenv("POA_FAULT") == "kill_during_staging" {
		injectedKill()
	}
	for i, c := range components {
		src := filepath.Join(fixtureDir(catalog), c.Artifact)
		dst := filepath.Join(stage, c.Artifact)
		in, e := os.Open(src)
		if e != nil {
			return fail(op, "ARTIFACT_MISSING", e.Error(), previous, previous, "preserved", "")
		}
		out, e := os.Create(dst)
		if e == nil {
			_, e = io.Copy(out, in)
			out.Close()
		}
		in.Close()
		if e != nil {
			return e
		}
		actual, e := hashFile(dst)
		if e != nil || actual != c.SHA256 {
			return fail(op, "CHECKSUM_MISMATCH", "fixture sha256 mismatch", previous, previous, "preserved", "")
		}
		event(op, "artifact_verified")
		target := filepath.Join(root, "store", "components", c.ID, c.Version)
		receiptPath := filepath.Join(target, ".stemwerk-component.json")
		if _, e = os.Stat(receiptPath); os.IsNotExist(e) {
			if e = os.MkdirAll(target, 0755); e != nil {
				return e
			}
			if e = os.Rename(dst, filepath.Join(target, c.Artifact)); e != nil {
				return e
			}
			r := receipt{1, c.ID, c.Version, c.Artifact, c.SHA256, "poa0-v1", c.SHA256, runtime.GOOS, runtime.GOARCH, "fixture", time.Now().UTC().Format(time.RFC3339Nano), []string{c.Artifact}, op, "local-fixture", "fixture-only", managerVersion}
			if e = writeJSON(receiptPath, r); e != nil {
				return e
			}
			_ = os.Chmod(filepath.Join(target, c.Artifact), 0444)
			_ = os.Chmod(receiptPath, 0444)
			_ = os.Chmod(target, 0555)
			event(op, "receipt_written")
		}
		if os.Getenv("POA_FAULT") == "fail_after_receipt" && i == 0 {
			return fail(op, "INJECTED_FAILURE", "after receipt", previous, previous, "preserved", "")
		}
	}
	if os.Getenv("POA_CANCEL") == "during_staging" {
		event(op, "op_cancelled")
		emit(result{false, op, "CANCELLED", "cancelled during staging", previous, previous, "preserved", ""})
		return errors.New("cancelled")
	}
	if os.Getenv("POA_FAULT") == "fail_after_stage" {
		return fail(op, "INJECTED_FAILURE", "after stage", previous, previous, "preserved", "")
	}
	receiptHashes := map[string]string{}
	for _, c := range components {
		h, e := hashFile(filepath.Join(root, "store", "components", c.ID, c.Version, ".stemwerk-component.json"))
		if e != nil {
			return e
		}
		receiptHashes[c.ID] = h
	}
	id := fmt.Sprintf("gen-%d", time.Now().UnixNano())
	tmp := filepath.Join(root, "generations", id+".tmp")
	if e = os.Mkdir(tmp, 0755); e != nil {
		return e
	}
	g := generation{1, id, "poa0-v1", time.Now().UTC().Format(time.RFC3339Nano), []string{"flow.normal_stems_fixture"}, "fixture", []string{"model.fixture@1.0.0", "runtime.fixture@1.0.0"}, receiptHashes, previous, planHash()}
	if e = writeJSON(filepath.Join(tmp, "generation.json"), g); e != nil {
		return e
	}
	if e = os.Rename(tmp, filepath.Join(root, "generations", id)); e != nil {
		return e
	}
	event(op, "generation_built")
	if os.Getenv("POA_FAULT") == "fail_after_generation_build" || os.Getenv("POA_FAULT") == "fail_before_active_swap" {
		return fail(op, "INJECTED_FAILURE", "before activation", previous, previous, "preserved", "")
	}
	if e = activate(root, id); e != nil {
		return e
	}
	event(op, "generation_activated")
	if os.Getenv("POA_FAULT") == "kill_after_active_swap" {
		injectedKill()
	}
	if os.Getenv("POA_FAULT") == "fail_after_active_swap_before_db_commit" {
		return fail(op, "INJECTED_FAILURE", "after active swap", id, previous, "recovery_required", "")
	}
	if e := dbSchema(root); e != nil {
		return e
	}
	for _, c := range components {
		h := receiptHashes[c.ID]
		q := fmt.Sprintf("INSERT OR REPLACE INTO inventory VALUES('%s','%s','%s');INSERT INTO ownership VALUES('%s','%s');INSERT INTO consumers VALUES('%s','flow.normal_stems_fixture');", c.ID, c.Version, h, c.ID, c.Artifact, c.ID)
		if e = sqlite(root, q); e != nil {
			return e
		}
	}
	q := fmt.Sprintf("UPDATE generations SET active=0;INSERT OR REPLACE INTO generations VALUES('%s',1,'%s');INSERT OR REPLACE INTO operations VALUES('%s','completed');", id, previous, op)
	if e = sqlite(root, q); e != nil {
		return e
	}
	os.RemoveAll(stage)
	writeStatus(root)
	event(op, "op_completed")
	emit(result{true, op, "", "installed", id, previous, "committed", filepath.Join(root, "state", "journal", op+".json")})
	return nil
}

func writeStatus(root string) error {
	active := readActive(root)
	count := 0
	entries, _ := os.ReadDir(filepath.Join(root, "generations"))
	for _, e := range entries {
		if e.IsDir() && !strings.HasSuffix(e.Name(), ".tmp") {
			count++
		}
	}
	return writeJSON(filepath.Join(root, "state", "status.json"), map[string]any{"schema_version": 1, "active_generation": active, "desired_flows": []string{"flow.normal_stems_fixture"}, "backend": "fixture", "inventory_count": 2, "generation_count": count})
}
func verify(op, root string) error {
	event(op, "op_started")
	active := readActive(root)
	if active == "" {
		return fail(op, "NO_ACTIVE_GENERATION", "active missing", "", "", "invalid", "")
	}
	for _, c := range components {
		p := filepath.Join(root, "store", "components", c.ID, c.Version)
		h, e := hashFile(filepath.Join(p, c.Artifact))
		if e != nil || h != c.SHA256 {
			return fail(op, "ARTIFACT_DRIFT", "artifact invalid", active, "", "invalid", "")
		}
		var r receipt
		b, e := os.ReadFile(filepath.Join(p, ".stemwerk-component.json"))
		if e != nil || json.Unmarshal(b, &r) != nil || r.ArtifactSHA256 != c.SHA256 {
			return fail(op, "RECEIPT_DRIFT", "receipt invalid", active, "", "invalid", "")
		}
	}
	event(op, "op_completed")
	emit(result{true, op, "", "verified", active, "", "unchanged", ""})
	return nil
}
func rebuild(op, root string) error {
	event(op, "op_started")
	os.Remove(filepath.Join(root, "state", "state.db"))
	os.Remove(filepath.Join(root, "state", "state.db-wal"))
	os.Remove(filepath.Join(root, "state", "state.db-shm"))
	if e := dbSchema(root); e != nil {
		return e
	}
	active := readActive(root)
	for _, c := range components {
		h, e := hashFile(filepath.Join(root, "store", "components", c.ID, c.Version, ".stemwerk-component.json"))
		if e != nil {
			return fail(op, "RECEIPT_MISSING", "cannot rebuild", active, "", "invalid", "")
		}
		sqlite(root, fmt.Sprintf("INSERT INTO inventory VALUES('%s','%s','%s');INSERT INTO consumers VALUES('%s','flow.normal_stems_fixture');", c.ID, c.Version, h, c.ID))
	}
	sqlite(root, fmt.Sprintf("INSERT INTO generations VALUES('%s',1,'');", active))
	writeStatus(root)
	event(op, "state_rebuilt")
	event(op, "op_completed")
	emit(result{true, op, "", "state rebuilt", active, "", "rebuilt", ""})
	return nil
}
func rollback(op, root string) error {
	event(op, "op_started")
	event(op, "rollback_started")
	active := readActive(root)
	b, e := os.ReadFile(filepath.Join(root, "generations", active, "generation.json"))
	if e != nil {
		return fail(op, "GENERATION_MISSING", e.Error(), active, "", "preserved", "")
	}
	var g generation
	if json.Unmarshal(b, &g) != nil || g.PreviousGeneration == "" {
		return fail(op, "NO_PREVIOUS_GENERATION", "no previous generation", active, "", "preserved", "")
	}
	if _, e = os.Stat(filepath.Join(root, "generations", g.PreviousGeneration, "generation.json")); e != nil {
		return fail(op, "PREVIOUS_GENERATION_INVALID", e.Error(), active, g.PreviousGeneration, "preserved", "")
	}
	if e = activate(root, g.PreviousGeneration); e != nil {
		return e
	}
	event(op, "rollback_completed")
	event(op, "op_completed")
	emit(result{true, op, "", "rolled back", g.PreviousGeneration, active, "committed", ""})
	return nil
}
func status(op, root string) error {
	if _, e := os.Stat(filepath.Join(root, "state", "desired.json")); e != nil {
		return fail(op, "DESIRED_MISSING", "desired.json missing", readActive(root), "", "invalid", "")
	}
	writeStatus(root)
	b, e := os.ReadFile(filepath.Join(root, "state", "status.json"))
	if e != nil {
		return fail(op, "STATUS_UNAVAILABLE", e.Error(), "", "", "invalid", "")
	}
	fmt.Print(string(b))
	emit(result{true, op, "", "status", readActive(root), "", "unchanged", ""})
	return nil
}
func runPin(op, root string) error {
	active := readActive(root)
	if active == "" {
		return fail(op, "NO_ACTIVE_GENERATION", "cannot pin", "", "", "invalid", "")
	}
	runID := argsValue("--run-id", op)
	lease := filepath.Join(root, "state", "leases", fmt.Sprintf("%d-%s.json", os.Getpid(), runID))
	writeJSON(lease, map[string]any{"schema_version": 1, "pid": os.Getpid(), "run_id": runID, "generation_id": active, "created_at": time.Now().UTC().Format(time.RFC3339Nano)})
	defer os.Remove(lease)
	event(op, "op_started")
	emit(map[string]any{"schema_version": 1, "event": "run_stage", "op_id": op, "stage": 1, "generation_id": active})
	ms, _ := strconv.Atoi(argsValue("--duration-ms", "300"))
	time.Sleep(time.Duration(ms/2) * time.Millisecond)
	emit(map[string]any{"schema_version": 1, "event": "run_stage", "op_id": op, "stage": 2, "generation_id": active})
	time.Sleep(time.Duration(ms-ms/2) * time.Millisecond)
	event(op, "op_completed")
	emit(result{true, op, "", "run pinned", active, "", "unchanged", lease})
	return nil
}
func recoverOp(op, root string) error {
	active := readActive(root)
	if active == "" {
		return fail(op, "NO_ACTIVE_GENERATION", "nothing to recover", "", "", "invalid", "")
	}
	return rebuild(op, root)
}
func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "command required")
		os.Exit(2)
	}
	cmd := os.Args[1]
	root := argsValue("--root", "")
	journalRoot = root
	catalog := argsValue("--catalog", "")
	if root == "" {
		fmt.Fprintln(os.Stderr, "--root required")
		os.Exit(2)
	}
	op := fmt.Sprintf("%s-%d", cmd, time.Now().UnixNano())
	var e error
	switch cmd {
	case "plan":
		plan(op, root)
	case "install":
		e = install(op, root, catalog)
	case "verify":
		e = verify(op, root)
	case "state-rebuild":
		e = rebuild(op, root)
	case "status":
		e = status(op, root)
	case "rollback":
		e = rollback(op, root)
	case "run-pin":
		e = runPin(op, root)
	case "recover":
		e = recoverOp(op, root)
	default:
		fmt.Fprintln(os.Stderr, "unknown command")
		os.Exit(2)
	}
	if e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
}
