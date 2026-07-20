// EXPERIMENTAL_DISPOSABLE_POA_ONLY
use sha2::{Digest, Sha256};
use std::{
    env,
    fs::{self, File, OpenOptions},
    io::{BufReader, Read, Write},
    path::{Path, PathBuf},
    process::{self, Command, Stdio},
    sync::OnceLock,
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const RUNTIME_SHA: &str = "a159ce98c9da7498ff385b4b799e4bac64313de699878e793654929a95e1bab5";
const MODEL_SHA: &str = "d76c207e3cb3217db5350a9c8f58daeac9ff845f5a368d3583df2e05d2f36fcf";
const PLAN_HASH: &str = "e2795dc557c15e943cbb0dad76bca6aa53e64a4e7f8a32f3e4278f3605587df3";
#[derive(Clone, Copy)]
struct Component {
    id: &'static str,
    artifact: &'static str,
    sha: &'static str,
}
const COMPONENTS: [Component; 2] = [
    Component {
        id: "runtime.fixture",
        artifact: "runtime-fixture.txt",
        sha: RUNTIME_SHA,
    },
    Component {
        id: "model.fixture",
        artifact: "model-fixture.txt",
        sha: MODEL_SHA,
    },
];
static JOURNAL_ROOT: OnceLock<PathBuf> = OnceLock::new();

fn now() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos()
}
fn esc(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
}
fn emit(s: &str) {
    println!("{s}");
    if let Some(root) = JOURNAL_ROOT.get() {
        let dir = root.join("state/journal");
        if dir.is_dir()
            && let Ok(mut file) = OpenOptions::new()
                .create(true)
                .append(true)
                .open(dir.join("operations.jsonl"))
        {
            let _ = writeln!(file, "{s}");
        }
    }
}
fn event(op: &str, name: &str) {
    emit(&format!(
        r#"{{"schema_version":1,"event":"{}","op_id":"{}"}}"#,
        name, op
    ))
}
#[allow(clippy::too_many_arguments)]
fn result(
    ok: bool,
    op: &str,
    code: &str,
    msg: &str,
    active: &str,
    previous: &str,
    state: &str,
    log: &str,
) {
    emit(&format!(
        r#"{{"ok":{},"op_id":"{}","error_code":"{}","message":"{}","active_generation":"{}","previous_generation":"{}","state":"{}","log_path":"{}"}}"#,
        ok,
        esc(op),
        esc(code),
        esc(msg),
        esc(active),
        esc(previous),
        esc(state),
        esc(log)
    ))
}
fn fail(
    op: &str,
    code: &str,
    msg: &str,
    active: &str,
    previous: &str,
    state: &str,
) -> Result<(), String> {
    event(op, "op_failed");
    result(false, op, code, msg, active, previous, state, "");
    Err(msg.into())
}
fn arg(name: &str, default: &str) -> String {
    let a: Vec<String> = env::args().collect();
    for i in 2..a.len().saturating_sub(1) {
        if a[i] == name {
            return a[i + 1].clone();
        }
    }
    default.into()
}
fn mkdirs(root: &Path) -> Result<(), String> {
    for p in [
        "staging",
        "store/components",
        "generations",
        "state/journal",
        "state/leases",
    ] {
        fs::create_dir_all(root.join(p)).map_err(|e| e.to_string())?
    }
    let desired = root.join("state/desired.json");
    if !desired.exists() {
        write_sync(
            &desired,
            "{\"schema_version\":1,\"selected_flows\":[\"flow.normal_stems_fixture\"]}\n",
        )?
    }
    let settings = root.join("state/settings.json");
    if !settings.exists() {
        write_sync(
            &settings,
            "{\"schema_version\":1,\"backend\":\"fixture\",\"pins\":{}}\n",
        )?
    }
    Ok(())
}
fn write_sync(path: &Path, data: &str) -> Result<(), String> {
    let mut f = File::create(path).map_err(|e| e.to_string())?;
    f.write_all(data.as_bytes()).map_err(|e| e.to_string())?;
    f.sync_all().map_err(|e| e.to_string())
}
fn active(root: &Path) -> String {
    let Ok(s) = fs::read_to_string(root.join("state/active")) else {
        return String::new();
    };
    extract(&s, "generation_id")
}
fn extract(s: &str, key: &str) -> String {
    let needle = format!("\"{key}\":\"");
    let Some(start) = s.find(&needle) else {
        return String::new();
    };
    let rest = &s[start + needle.len()..];
    rest.split('"').next().unwrap_or("").into()
}
#[derive(Debug)]
enum HashError {
    Open {
        path: PathBuf,
        cause: String,
    },
    Read {
        path: PathBuf,
        cause: String,
    },
    Mismatch {
        path: PathBuf,
        expected: String,
        actual: String,
    },
}
impl HashError {
    fn code(&self) -> &'static str {
        match self {
            Self::Open { .. } => "HASH_OPEN_FAILED",
            Self::Read { .. } => "HASH_READ_FAILED",
            // Preserve the frozen POA error-code contract.
            Self::Mismatch { .. } => "CHECKSUM_MISMATCH",
        }
    }
    fn message(&self) -> String {
        match self {
            Self::Open { path, cause } => {
                format!("cannot open hash input {}: {cause}", path.display())
            }
            Self::Read { path, cause } => {
                format!("cannot read hash input {}: {cause}", path.display())
            }
            Self::Mismatch {
                path,
                expected,
                actual,
            } => format!(
                "sha256 mismatch for {}: expected {expected}, actual {actual}",
                path.display()
            ),
        }
    }
}
fn sha256_reader<R: Read>(reader: R, path: &Path) -> Result<String, HashError> {
    let mut reader = BufReader::new(reader);
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 16 * 1024];
    loop {
        let count = reader.read(&mut buffer).map_err(|error| HashError::Read {
            path: path.to_path_buf(),
            cause: error.to_string(),
        })?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    let digest = hasher.finalize();
    let mut output = String::with_capacity(64);
    for byte in digest {
        output.push_str(&format!("{byte:02x}"));
    }
    Ok(output)
}
fn sha256_file(path: &Path) -> Result<String, HashError> {
    let file = File::open(path).map_err(|error| HashError::Open {
        path: path.to_path_buf(),
        cause: error.to_string(),
    })?;
    sha256_reader(file, path)
}
fn verified_sha256_file(path: &Path, expected: &str) -> Result<String, HashError> {
    let actual = sha256_file(path)?;
    if actual == expected {
        Ok(actual)
    } else {
        Err(HashError::Mismatch {
            path: path.to_path_buf(),
            expected: expected.to_string(),
            actual,
        })
    }
}
fn operation_hash(
    op: &str,
    path: &Path,
    expected: Option<&str>,
    active: &str,
    previous: &str,
    state: &str,
) -> Result<String, String> {
    let hash = match expected {
        Some(expected) => verified_sha256_file(path, expected),
        None => sha256_file(path),
    };
    match hash {
        Ok(value) => Ok(value),
        Err(error) => {
            let message = error.message();
            match fail(op, error.code(), &message, active, previous, state) {
                Err(error) => Err(error),
                Ok(()) => Err(message),
            }
        }
    }
}
fn activate(root: &Path, id: &str) -> Result<(), String> {
    let state = root.join("state");
    let tmp = state.join("active.tmp");
    write_sync(
        &tmp,
        &format!("{{\"schema_version\":1,\"generation_id\":\"{id}\"}}\n"),
    )?;
    fs::rename(&tmp, state.join("active")).map_err(|e| e.to_string())?;
    File::open(state)
        .and_then(|f| f.sync_all())
        .map_err(|e| e.to_string())
}
fn sqlite(root: &Path, sql: &str) -> Result<(), String> {
    let mut child = Command::new("sqlite3")
        .arg(root.join("state/state.db"))
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|e| e.to_string())?;
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(format!("PRAGMA journal_mode=WAL;{sql}").as_bytes())
        .map_err(|e| e.to_string())?;
    if child.wait().map_err(|e| e.to_string())?.success() {
        Ok(())
    } else {
        Err("sqlite3 failed".into())
    }
}
fn schema(root: &Path) -> Result<(), String> {
    sqlite(
        root,
        "CREATE TABLE IF NOT EXISTS inventory(component_id TEXT,version TEXT,receipt_hash TEXT,PRIMARY KEY(component_id,version));CREATE TABLE IF NOT EXISTS ownership(component_id TEXT,path TEXT);CREATE TABLE IF NOT EXISTS consumers(component_id TEXT,flow_id TEXT);CREATE TABLE IF NOT EXISTS generations(generation_id TEXT PRIMARY KEY,active INTEGER,previous_generation TEXT);CREATE TABLE IF NOT EXISTS operations(op_id TEXT PRIMARY KEY,status TEXT);",
    )
}
fn plan(op: &str, root: &Path) {
    event(op, "op_started");
    event(op, "plan_ready");
    emit(&format!(
        r#"{{"schema_version":1,"op_id":"{op}","flow":"flow.normal_stems_fixture","components":["model.fixture","runtime.fixture"],"download_size":52,"installed_size":52,"plan_hash":"{PLAN_HASH}"}}"#
    ));
    result(
        true,
        op,
        "",
        "plan ready",
        &active(root),
        "",
        "unchanged",
        "",
    )
}
struct Lock(PathBuf);
impl Drop for Lock {
    fn drop(&mut self) {
        let _ = fs::remove_dir(&self.0);
    }
}
fn lock(root: &Path) -> Result<Lock, String> {
    let p = root.join("state/mutation.lock");
    fs::create_dir(&p).map_err(|_| "another mutation is active".to_string())?;
    Ok(Lock(p))
}
fn receipt(c: Component, op: &str) -> String {
    format!(
        r#"{{"schema_version":1,"component_id":"{}","component_version":"1.0.0","artifact_id":"{}","artifact_sha256":"{}","catalog_version":"poa0-v1","catalog_entry_hash":"{}","platform":"{}","architecture":"{}","backend":"fixture","install_timestamp":"{}","installed_files_manifest":["{}"],"transaction_id":"{}","source_type":"local-fixture","provenance_status":"fixture-only","manager_version":"poa0-rust"}}
"#,
        c.id,
        c.artifact,
        c.sha,
        c.sha,
        env::consts::OS,
        env::consts::ARCH,
        now(),
        c.artifact,
        op
    )
}
fn install(op: &str, root: &Path, catalog: &Path) -> Result<(), String> {
    mkdirs(root)?;
    let _guard = match lock(root) {
        Ok(v) => v,
        Err(_) => {
            return fail(
                op,
                "MUTATION_LOCKED",
                "another mutation is active",
                &active(root),
                "",
                "preserved",
            );
        }
    };
    let previous = active(root);
    event(op, "op_started");
    event(op, "plan_ready");
    let stage = root.join("staging").join(op);
    fs::create_dir_all(&stage).map_err(|e| e.to_string())?;
    event(op, "staging_started");
    if env::var("POA_FAULT").unwrap_or_default() == "kill_during_staging" {
        process::abort()
    }
    let fixtures = catalog.parent().unwrap().join("artifacts");
    for (i, c) in COMPONENTS.iter().enumerate() {
        let staged = stage.join(c.artifact);
        fs::copy(fixtures.join(c.artifact), &staged).map_err(|e| e.to_string())?;
        operation_hash(op, &staged, Some(c.sha), &previous, &previous, "preserved")?;
        event(op, "artifact_verified");
        let target = root.join("store/components").join(c.id).join("1.0.0");
        let rp = target.join(".stemwerk-component.json");
        if !rp.exists() {
            fs::create_dir_all(&target).map_err(|e| e.to_string())?;
            fs::rename(&staged, target.join(c.artifact)).map_err(|e| e.to_string())?;
            write_sync(&rp, &receipt(*c, op))?;
            let mut artifact_permissions = fs::metadata(target.join(c.artifact))
                .map_err(|e| e.to_string())?
                .permissions();
            artifact_permissions.set_readonly(true);
            fs::set_permissions(target.join(c.artifact), artifact_permissions)
                .map_err(|e| e.to_string())?;
            let mut receipt_permissions =
                fs::metadata(&rp).map_err(|e| e.to_string())?.permissions();
            receipt_permissions.set_readonly(true);
            fs::set_permissions(&rp, receipt_permissions).map_err(|e| e.to_string())?;
            let mut directory_permissions = fs::metadata(&target)
                .map_err(|e| e.to_string())?
                .permissions();
            directory_permissions.set_readonly(true);
            fs::set_permissions(&target, directory_permissions).map_err(|e| e.to_string())?;
            event(op, "receipt_written")
        }
        if env::var("POA_FAULT").unwrap_or_default() == "fail_after_receipt" && i == 0 {
            return fail(
                op,
                "INJECTED_FAILURE",
                "after receipt",
                &previous,
                &previous,
                "preserved",
            );
        }
    }
    if env::var("POA_CANCEL").unwrap_or_default() == "during_staging" {
        event(op, "op_cancelled");
        result(
            false,
            op,
            "CANCELLED",
            "cancelled during staging",
            &previous,
            &previous,
            "preserved",
            "",
        );
        return Err("cancelled".into());
    }
    if env::var("POA_FAULT").unwrap_or_default() == "fail_after_stage" {
        return fail(
            op,
            "INJECTED_FAILURE",
            "after stage",
            &previous,
            &previous,
            "preserved",
        );
    }
    let mut rhs = Vec::new();
    for c in COMPONENTS {
        rhs.push((
            c.id,
            operation_hash(
                op,
                &root
                    .join("store/components")
                    .join(c.id)
                    .join("1.0.0/.stemwerk-component.json"),
                None,
                &previous,
                &previous,
                "preserved",
            )?,
        ))
    }
    let id = format!("gen-{}", now());
    let tmp = root.join("generations").join(format!("{id}.tmp"));
    fs::create_dir(&tmp).map_err(|e| e.to_string())?;
    let manifest = format!(
        r#"{{"schema_version":1,"generation_id":"{id}","catalog_version":"poa0-v1","created_at":"{}","selected_flows":["flow.normal_stems_fixture"],"backend":"fixture","components":["model.fixture@1.0.0","runtime.fixture@1.0.0"],"component_receipt_hashes":{{"{}":"{}","{}":"{}"}},"previous_generation":"{}","plan_hash":"{PLAN_HASH}"}}
"#,
        now(),
        rhs[0].0,
        rhs[0].1,
        rhs[1].0,
        rhs[1].1,
        previous
    );
    write_sync(&tmp.join("generation.json"), &manifest)?;
    fs::rename(&tmp, root.join("generations").join(&id)).map_err(|e| e.to_string())?;
    event(op, "generation_built");
    let fault = env::var("POA_FAULT").unwrap_or_default();
    if fault == "fail_after_generation_build" || fault == "fail_before_active_swap" {
        return fail(
            op,
            "INJECTED_FAILURE",
            "before activation",
            &previous,
            &previous,
            "preserved",
        );
    }
    activate(root, &id)?;
    event(op, "generation_activated");
    if fault == "kill_after_active_swap" {
        process::abort()
    }
    if fault == "fail_after_active_swap_before_db_commit" {
        return fail(
            op,
            "INJECTED_FAILURE",
            "after active swap",
            &id,
            &previous,
            "recovery_required",
        );
    }
    schema(root)?;
    for c in COMPONENTS {
        let rh = operation_hash(
            op,
            &root
                .join("store/components")
                .join(c.id)
                .join("1.0.0/.stemwerk-component.json"),
            None,
            &id,
            &previous,
            "recovery_required",
        )?;
        sqlite(
            root,
            &format!(
                "INSERT OR REPLACE INTO inventory VALUES('{}','1.0.0','{}');INSERT INTO ownership VALUES('{}','{}');INSERT INTO consumers VALUES('{}','flow.normal_stems_fixture');",
                c.id, rh, c.id, c.artifact, c.id
            ),
        )?
    }
    sqlite(
        root,
        &format!(
            "UPDATE generations SET active=0;INSERT OR REPLACE INTO generations VALUES('{id}',1,'{previous}');INSERT OR REPLACE INTO operations VALUES('{op}','completed');"
        ),
    )?;
    let _ = fs::remove_dir_all(stage);
    write_status(root)?;
    event(op, "op_completed");
    result(
        true,
        op,
        "",
        "installed",
        &id,
        &previous,
        "committed",
        &root
            .join("state/journal")
            .join(format!("{op}.json"))
            .display()
            .to_string(),
    );
    Ok(())
}
fn generation_count(root: &Path) -> usize {
    fs::read_dir(root.join("generations"))
        .map(|it| {
            it.filter_map(Result::ok)
                .filter(|e| e.path().is_dir() && !e.file_name().to_string_lossy().ends_with(".tmp"))
                .count()
        })
        .unwrap_or(0)
}
fn write_status(root: &Path) -> Result<(), String> {
    write_sync(
        &root.join("state/status.json"),
        &format!(
            r#"{{"schema_version":1,"active_generation":"{}","desired_flows":["flow.normal_stems_fixture"],"backend":"fixture","inventory_count":2,"generation_count":{}}}
"#,
            active(root),
            generation_count(root)
        ),
    )
}
fn verify(op: &str, root: &Path) -> Result<(), String> {
    event(op, "op_started");
    let a = active(root);
    if a.is_empty() {
        return fail(
            op,
            "NO_ACTIVE_GENERATION",
            "active missing",
            "",
            "",
            "invalid",
        );
    }
    for c in COMPONENTS {
        let base = root.join("store/components").join(c.id).join("1.0.0");
        let artifact = base.join(c.artifact);
        let actual = operation_hash(op, &artifact, None, &a, "", "invalid")?;
        if actual != c.sha {
            return fail(op, "ARTIFACT_DRIFT", "artifact invalid", &a, "", "invalid");
        }
        let Ok(r) = fs::read_to_string(base.join(".stemwerk-component.json")) else {
            return fail(op, "RECEIPT_DRIFT", "receipt missing", &a, "", "invalid");
        };
        if extract(&r, "artifact_sha256") != c.sha {
            return fail(op, "RECEIPT_DRIFT", "receipt invalid", &a, "", "invalid");
        }
    }
    event(op, "op_completed");
    result(true, op, "", "verified", &a, "", "unchanged", "");
    Ok(())
}
fn rebuild(op: &str, root: &Path) -> Result<(), String> {
    event(op, "op_started");
    for p in ["state.db", "state.db-wal", "state.db-shm"] {
        let _ = fs::remove_file(root.join("state").join(p));
    }
    schema(root)?;
    let a = active(root);
    for c in COMPONENTS {
        let rp = root
            .join("store/components")
            .join(c.id)
            .join("1.0.0/.stemwerk-component.json");
        if !rp.exists() {
            return fail(op, "RECEIPT_MISSING", "cannot rebuild", &a, "", "invalid");
        }
        sqlite(
            root,
            &format!(
                "INSERT INTO inventory VALUES('{}','1.0.0','{}');INSERT INTO consumers VALUES('{}','flow.normal_stems_fixture');",
                c.id,
                operation_hash(op, &rp, None, &a, "", "invalid")?,
                c.id
            ),
        )?
    }
    sqlite(
        root,
        &format!("INSERT INTO generations VALUES('{a}',1,'');"),
    )?;
    write_status(root)?;
    event(op, "state_rebuilt");
    event(op, "op_completed");
    result(true, op, "", "state rebuilt", &a, "", "rebuilt", "");
    Ok(())
}
fn rollback(op: &str, root: &Path) -> Result<(), String> {
    event(op, "op_started");
    event(op, "rollback_started");
    let a = active(root);
    let s = fs::read_to_string(root.join("generations").join(&a).join("generation.json"))
        .map_err(|e| e.to_string())?;
    let previous = extract(&s, "previous_generation");
    if previous.is_empty() {
        return fail(
            op,
            "NO_PREVIOUS_GENERATION",
            "no previous generation",
            &a,
            "",
            "preserved",
        );
    }
    if !root
        .join("generations")
        .join(&previous)
        .join("generation.json")
        .exists()
    {
        return fail(
            op,
            "PREVIOUS_GENERATION_INVALID",
            "previous missing",
            &a,
            &previous,
            "preserved",
        );
    }
    activate(root, &previous)?;
    event(op, "rollback_completed");
    event(op, "op_completed");
    result(true, op, "", "rolled back", &previous, &a, "committed", "");
    Ok(())
}
fn status(op: &str, root: &Path) -> Result<(), String> {
    if !root.join("state/desired.json").exists() {
        return fail(
            op,
            "DESIRED_MISSING",
            "desired.json missing",
            &active(root),
            "",
            "invalid",
        );
    }
    write_status(root)?;
    emit(
        fs::read_to_string(root.join("state/status.json"))
            .map_err(|e| e.to_string())?
            .trim(),
    );
    result(true, op, "", "status", &active(root), "", "unchanged", "");
    Ok(())
}
fn run_pin(op: &str, root: &Path) -> Result<(), String> {
    let a = active(root);
    if a.is_empty() {
        return fail(op, "NO_ACTIVE_GENERATION", "cannot pin", "", "", "invalid");
    }
    let run = arg("--run-id", op);
    let lease = root
        .join("state/leases")
        .join(format!("{}-{run}.json", process::id()));
    write_sync(
        &lease,
        &format!(
            r#"{{"schema_version":1,"pid":{},"run_id":"{run}","generation_id":"{a}","created_at":"{}"}}
"#,
            process::id(),
            now()
        ),
    )?;
    event(op, "op_started");
    emit(&format!(
        r#"{{"schema_version":1,"event":"run_stage","op_id":"{op}","stage":1,"generation_id":"{a}"}}"#
    ));
    let ms: u64 = arg("--duration-ms", "300").parse().unwrap_or(300);
    thread::sleep(Duration::from_millis(ms / 2));
    emit(&format!(
        r#"{{"schema_version":1,"event":"run_stage","op_id":"{op}","stage":2,"generation_id":"{a}"}}"#
    ));
    thread::sleep(Duration::from_millis(ms - ms / 2));
    let _ = fs::remove_file(&lease);
    event(op, "op_completed");
    result(
        true,
        op,
        "",
        "run pinned",
        &a,
        "",
        "unchanged",
        &lease.display().to_string(),
    );
    Ok(())
}
fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("command required");
        process::exit(2)
    }
    let command = &args[1];
    let root = PathBuf::from(arg("--root", ""));
    let _ = JOURNAL_ROOT.set(root.clone());
    let catalog = PathBuf::from(arg("--catalog", ""));
    if root.as_os_str().is_empty() {
        eprintln!("--root required");
        process::exit(2)
    }
    let op = format!("{}-{}", command, now());
    let r = match command.as_str() {
        "plan" => {
            plan(&op, &root);
            Ok(())
        }
        "install" => install(&op, &root, &catalog),
        "verify" => verify(&op, &root),
        "state-rebuild" => rebuild(&op, &root),
        "status" => status(&op, &root),
        "rollback" => rollback(&op, &root),
        "run-pin" => run_pin(&op, &root),
        "recover" => rebuild(&op, &root),
        _ => Err("unknown command".into()),
    };
    if let Err(e) = r {
        eprintln!("{e}");
        process::exit(1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{self, Cursor};

    struct TestDir(PathBuf);
    impl TestDir {
        fn new(label: &str) -> Self {
            let path =
                env::temp_dir().join(format!("poa0-sha-{label}-{}-{}", process::id(), now()));
            fs::create_dir(&path).expect("create test directory");
            Self(path)
        }
        fn file(&self, name: &str, bytes: &[u8]) -> PathBuf {
            let path = self.0.join(name);
            fs::write(&path, bytes).expect("write test file");
            path
        }
    }
    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn hashes_known_small_fixture() {
        let dir = TestDir::new("known");
        let path = dir.file("abc.txt", b"abc");
        assert_eq!(
            sha256_file(&path).expect("hash"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
    #[test]
    fn hashes_empty_file() {
        let dir = TestDir::new("empty");
        let path = dir.file("empty", b"");
        assert_eq!(
            sha256_file(&path).expect("hash"),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }
    #[test]
    fn hashes_binary_bytes() {
        let dir = TestDir::new("binary");
        let path = dir.file("bytes.bin", &[0, 255, 1, 128, 10, 0]);
        assert_eq!(
            sha256_file(&path).expect("hash"),
            "dbc6023624fd4186398804a32cbd629f935787dec7443a8b84dfb4b9da4b7d98"
        );
    }
    #[test]
    fn hashes_path_with_space() {
        let dir = TestDir::new("space");
        let path = dir.file("with space.txt", b"abc");
        assert!(sha256_file(&path).is_ok());
    }
    #[test]
    fn hashes_unicode_path() {
        let dir = TestDir::new("unicode");
        let path = dir.file("hash-é-日.txt", b"abc");
        assert!(sha256_file(&path).is_ok());
    }
    #[test]
    fn missing_file_is_structured_open_error() {
        let dir = TestDir::new("missing");
        let error = sha256_file(&dir.0.join("missing")).expect_err("must fail");
        assert_eq!(error.code(), "HASH_OPEN_FAILED");
        assert!(error.message().contains("missing"));
    }
    #[test]
    fn directory_input_is_structured() {
        let dir = TestDir::new("directory");
        let error = sha256_file(&dir.0).expect_err("must fail");
        assert!(matches!(
            error,
            HashError::Open { .. } | HashError::Read { .. }
        ));
    }
    #[test]
    fn output_is_lowercase_64_character_hex() {
        let digest = sha256_reader(Cursor::new(b"format"), Path::new("format")).expect("hash");
        assert_eq!(digest.len(), 64);
        assert!(
            digest
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        );
    }
    #[test]
    fn known_digest_verification_matches() {
        let dir = TestDir::new("match");
        let path = dir.file("abc", b"abc");
        assert!(
            verified_sha256_file(
                &path,
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            )
            .is_ok()
        );
    }
    #[test]
    fn mismatch_fails_closed_with_existing_contract_code() {
        let dir = TestDir::new("mismatch");
        let path = dir.file("abc", b"abc");
        let error = verified_sha256_file(&path, &"0".repeat(64)).expect_err("must fail");
        assert_eq!(error.code(), "CHECKSUM_MISMATCH");
        assert!(error.message().contains("expected"));
        assert!(error.message().contains("actual"));
    }
    struct FailingReader;
    impl Read for FailingReader {
        fn read(&mut self, _buffer: &mut [u8]) -> io::Result<usize> {
            Err(io::Error::other("injected partial read failure"))
        }
    }
    #[test]
    fn partial_read_failure_is_structured() {
        let error = sha256_reader(FailingReader, Path::new("partial.bin")).expect_err("must fail");
        assert_eq!(error.code(), "HASH_READ_FAILED");
        assert!(error.message().contains("injected partial read failure"));
    }
    #[test]
    fn streams_file_larger_than_buffer() {
        let dir = TestDir::new("large");
        let bytes = vec![0x5a; 16 * 1024 + 37];
        let path = dir.file("large.bin", &bytes);
        assert_eq!(
            sha256_file(&path).expect("hash"),
            "a3b518bdf526ab7b48e5747db7c912d2a2fe39cb23ff9e1264af20ffc46a301e"
        );
    }
    #[test]
    fn hash_route_has_no_subprocess_or_powershell() {
        let source = include_str!("main.rs");
        assert!(!source.contains(&["Get", "-FileHash"].concat()));
        assert!(!source.contains(&["Command::new(\"power", "shell\")"].concat()));
        assert!(!source.contains(&["Command::new(\"sha", "256sum\")"].concat()));
        assert!(!source.contains(&["Command::new(\"sha", "sum\")"].concat()));
    }
}
