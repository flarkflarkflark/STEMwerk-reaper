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
#[cfg(windows)]
fn open_directory_for_sync(path: &Path) -> std::io::Result<File> {
    use std::os::windows::fs::OpenOptionsExt;

    const GENERIC_WRITE: u32 = 0x4000_0000;
    const FILE_SHARE_READ_WRITE_DELETE: u32 = 0x0000_0007;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;

    if !fs::metadata(path)?.is_dir() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "directory sync target is not a directory",
        ));
    }
    OpenOptions::new()
        .access_mode(GENERIC_WRITE)
        .share_mode(FILE_SHARE_READ_WRITE_DELETE)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
        .open(path)
}
#[cfg(windows)]
fn flush_directory_for_sync(directory: &File) -> std::io::Result<()> {
    use std::{ffi::c_void, os::windows::io::AsRawHandle};

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn FlushFileBuffers(handle: *mut c_void) -> i32;
        fn GetLastError() -> u32;
    }

    if unsafe { FlushFileBuffers(directory.as_raw_handle()) } != 0 {
        return Ok(());
    }
    let code = unsafe { GetLastError() };
    Err(std::io::Error::from_raw_os_error(code as i32))
}
#[cfg(not(windows))]
fn open_directory_for_sync(path: &Path) -> std::io::Result<File> {
    File::open(path)
}
#[cfg(not(windows))]
fn flush_directory_for_sync(directory: &File) -> std::io::Result<()> {
    directory.sync_all()
}
#[cfg(windows)]
const DIRECTORY_REQUESTED_ACCESS: &str = "GENERIC_WRITE";
#[cfg(not(windows))]
const DIRECTORY_REQUESTED_ACCESS: &str = "read";
#[cfg(windows)]
const DIRECTORY_SHARE_MODE: &str = "FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE";
#[cfg(not(windows))]
const DIRECTORY_SHARE_MODE: &str = "std-default";
#[cfg(windows)]
const DIRECTORY_FLUSH_PRIMITIVE: &str = "FlushFileBuffers";
#[cfg(not(windows))]
const DIRECTORY_FLUSH_PRIMITIVE: &str = "File::sync_all";
fn activation_diagnostic_enabled() -> bool {
    env::var("POA_ACTIVATION_DIAGNOSTIC").as_deref() == Ok("1")
}
#[cfg(windows)]
mod windows_durability_probe {
    use super::*;
    use std::{
        ffi::c_void,
        os::windows::{ffi::OsStrExt, fs::OpenOptionsExt, io::AsRawHandle},
    };

    type Handle = *mut c_void;
    const GENERIC_WRITE: u32 = 0x4000_0000;
    const FILE_SHARE_READ_WRITE_DELETE: u32 = 0x0000_0007;
    const OPEN_EXISTING: u32 = 3;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
    const MOVEFILE_REPLACE_EXISTING: u32 = 0x0000_0001;
    const MOVEFILE_WRITE_THROUGH: u32 = 0x0000_0008;
    const FILE_ATTRIBUTE_READONLY: u32 = 0x0000_0001;
    const INVALID_HANDLE_VALUE: Handle = -1_isize as Handle;

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn CreateFileW(
            name: *const u16,
            access: u32,
            share: u32,
            security: *mut c_void,
            creation: u32,
            flags: u32,
            template: Handle,
        ) -> Handle;
        fn CloseHandle(handle: Handle) -> i32;
        fn FlushFileBuffers(handle: Handle) -> i32;
        fn GetLastError() -> u32;
        fn MoveFileExW(source: *const u16, target: *const u16, flags: u32) -> i32;
        fn ReplaceFileW(
            replaced: *const u16,
            replacement: *const u16,
            backup: *const u16,
            flags: u32,
            exclude: *mut c_void,
            reserved: *mut c_void,
        ) -> i32;
        fn SetFileAttributesW(path: *const u16, attributes: u32) -> i32;
    }

    fn wide(path: &Path) -> Vec<u16> {
        path.as_os_str().encode_wide().chain(Some(0)).collect()
    }
    #[allow(clippy::too_many_arguments)]
    fn json_record(
        id: u8,
        api: &str,
        flags: &str,
        source: &Path,
        target: &Path,
        ok: bool,
        code: u32,
        observation: &str,
    ) {
        let event_name = match id {
            1 | 2 => "diag_selector_file_flush",
            4 | 5 | 11..=15 => "diag_movefileex",
            6 => "diag_replacefile",
            7..=10 => "diag_directory_flush",
            16..=18 => "diag_crash_probe_result",
            _ => "diag_durability_candidate_result",
        };
        emit(&format!(
            r#"{{"schema_version":1,"event":"{}","record_type":"diag_durability_candidate_result","candidate_id":{},"api":"{}","flags":"{}","source":"{}","target":"{}","handle_access":"diagnostic-specific","handle_share":"diagnostic-specific","return":{},"win32_code":{},"pre_state":"captured","post_state":"source_exists={},target_exists={}","selector_bytes":"{}","claim_level":"observed","observation":"{}"}}"#,
            event_name,
            id,
            api,
            flags,
            esc(&source.display().to_string()),
            esc(&target.display().to_string()),
            ok,
            code,
            source.exists(),
            target.exists(),
            esc(&fs::read_to_string(target).unwrap_or_default()),
            esc(observation),
        ));
    }
    fn native_result(value: i32) -> (bool, u32) {
        if value != 0 {
            (true, 0)
        } else {
            // SAFETY: GetLastError has no arguments and is read immediately after failure.
            (false, unsafe { GetLastError() })
        }
    }
    fn move_file(source: &Path, target: &Path, flags: u32) -> (bool, u32) {
        let source = wide(source);
        let target = wide(target);
        // SAFETY: both strings are NUL-terminated and remain alive for the call.
        native_result(unsafe { MoveFileExW(source.as_ptr(), target.as_ptr(), flags) })
    }
    fn replace_file(source: &Path, target: &Path) -> (bool, u32) {
        let source = wide(source);
        let target = wide(target);
        // SAFETY: both strings are NUL-terminated; optional pointers are null.
        native_result(unsafe {
            ReplaceFileW(
                target.as_ptr(),
                source.as_ptr(),
                std::ptr::null(),
                0,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        })
    }
    fn native_flush(file: &File) -> (bool, u32) {
        // SAFETY: AsRawHandle returns a valid handle for the lifetime of file.
        native_result(unsafe { FlushFileBuffers(file.as_raw_handle() as Handle) })
    }
    fn flush_directory_with_write(path: &Path) -> (bool, u32) {
        let path = wide(path);
        // SAFETY: path is NUL-terminated and all optional pointers are null.
        let handle = unsafe {
            CreateFileW(
                path.as_ptr(),
                GENERIC_WRITE,
                FILE_SHARE_READ_WRITE_DELETE,
                std::ptr::null_mut(),
                OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS,
                std::ptr::null_mut(),
            )
        };
        if handle == INVALID_HANDLE_VALUE {
            // SAFETY: called immediately after CreateFileW failure.
            return (false, unsafe { GetLastError() });
        }
        // SAFETY: handle is valid and closed exactly once after the flush attempt.
        let result = native_result(unsafe { FlushFileBuffers(handle) });
        unsafe { CloseHandle(handle) };
        result
    }
    fn prepare(root: &Path, name: &str, old: &str, new: &str) -> (PathBuf, PathBuf) {
        let target = root.join(format!("{name}.active"));
        let source = root.join(format!("{name}.tmp"));
        fs::write(&target, old).expect("probe target");
        fs::write(&source, new).expect("probe source");
        (source, target)
    }
    pub fn crash_child(root: &Path, phase: &str) -> Result<(), String> {
        fs::create_dir_all(root).map_err(|e| e.to_string())?;
        let source = root.join("crash.active.tmp");
        let target = root.join("crash.active");
        fs::write(&target, "old").map_err(|e| e.to_string())?;
        let mut file = File::create(&source).map_err(|e| e.to_string())?;
        file.write_all(b"new").map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        drop(file);
        if phase == "after_replace" {
            let (ok, code) = move_file(&source, &target, MOVEFILE_REPLACE_EXISTING);
            if !ok {
                return Err(format!("MoveFileExW failed: {code}"));
            }
        }
        process::abort()
    }
    pub fn run(root: &Path) -> Result<(), String> {
        fs::create_dir_all(root).map_err(|e| e.to_string())?;
        let source = root.join("selector-file.tmp");
        let target = root.join("selector-file.active");
        let mut file = File::create(&source).map_err(|e| e.to_string())?;
        file.write_all(b"new").map_err(|e| e.to_string())?;
        let r = file.sync_all();
        json_record(
            1,
            "File::sync_all",
            "file",
            &source,
            &target,
            r.is_ok(),
            r.as_ref()
                .err()
                .and_then(std::io::Error::raw_os_error)
                .unwrap_or(0) as u32,
            "selector temp file sync",
        );
        let (ok, code) = native_flush(&file);
        json_record(
            2,
            "FlushFileBuffers",
            "file handle GENERIC_WRITE",
            &source,
            &target,
            ok,
            code,
            "native selector temp flush",
        );
        drop(file);

        let (s, t) = prepare(root, "ordinary", "old", "new");
        let r = fs::rename(&s, &t);
        json_record(
            3,
            "std::fs::rename",
            "replace existing",
            &s,
            &t,
            r.is_ok(),
            r.as_ref()
                .err()
                .and_then(std::io::Error::raw_os_error)
                .unwrap_or(0) as u32,
            "ordinary replace",
        );

        let (s, t) = prepare(root, "move-replace", "old", "new");
        let (ok, code) = move_file(&s, &t, MOVEFILE_REPLACE_EXISTING);
        json_record(
            4,
            "MoveFileExW",
            "MOVEFILE_REPLACE_EXISTING",
            &s,
            &t,
            ok,
            code,
            "same-volume replacement",
        );

        let (s, t) = prepare(root, "move-through", "old", "new");
        let (ok, code) = move_file(&s, &t, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
        json_record(
            5,
            "MoveFileExW",
            "MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH",
            &s,
            &t,
            ok,
            code,
            "same-volume write-through replacement",
        );

        let (s, t) = prepare(root, "replace-file", "old", "new");
        let (ok, code) = replace_file(&s, &t);
        json_record(
            6,
            "ReplaceFileW",
            "flags=0",
            &s,
            &t,
            ok,
            code,
            "replace preserving target metadata",
        );

        let directory = open_directory_for_sync(root).map_err(|e| e.to_string())?;
        let r = directory.sync_all();
        json_record(
            7,
            "File::sync_all",
            "directory read+backup-semantics",
            root,
            root,
            r.is_ok(),
            r.as_ref()
                .err()
                .and_then(std::io::Error::raw_os_error)
                .unwrap_or(0) as u32,
            "Rust directory sync",
        );
        let (ok, code) = native_flush(&directory);
        json_record(
            8,
            "FlushFileBuffers",
            "directory read+backup-semantics",
            root,
            root,
            ok,
            code,
            "native flush on same read handle",
        );
        drop(directory);
        let (ok, code) = flush_directory_with_write(root);
        json_record(
            9,
            "CreateFileW+FlushFileBuffers",
            "GENERIC_WRITE|BACKUP_SEMANTICS",
            root,
            root,
            ok,
            code,
            "directory alternate access",
        );

        let (s, t) = prepare(root, "parent-flush", "old", "new");
        let moved = move_file(&s, &t, MOVEFILE_REPLACE_EXISTING).0;
        let (ok, code) = flush_directory_with_write(root);
        json_record(
            10,
            "MoveFileExW+FlushFileBuffers",
            "replace then parent GENERIC_WRITE",
            &s,
            &t,
            moved && ok,
            code,
            "parent flush after replace",
        );

        let (s, t) = prepare(root, "open-read", "old", "new");
        let open = File::open(&t).map_err(|e| e.to_string())?;
        let (ok, code) = move_file(&s, &t, MOVEFILE_REPLACE_EXISTING);
        json_record(
            11,
            "MoveFileExW",
            "target open read",
            &s,
            &t,
            ok,
            code,
            "replace with read handle",
        );
        drop(open);

        let (s, t) = prepare(root, "deny-share", "old", "new");
        let deny = OpenOptions::new()
            .read(true)
            .share_mode(0)
            .open(&t)
            .map_err(|e| e.to_string())?;
        let (ok, code) = move_file(&s, &t, MOVEFILE_REPLACE_EXISTING);
        json_record(
            12,
            "MoveFileExW",
            "target share=0",
            &s,
            &t,
            ok,
            code,
            "replace with deny-share handle",
        );
        drop(deny);

        let (s, t) = prepare(root, "readonly", "old", "new");
        let wt = wide(&t);
        // SAFETY: path is NUL-terminated.
        unsafe { SetFileAttributesW(wt.as_ptr(), FILE_ATTRIBUTE_READONLY) };
        let (ok, code) = move_file(&s, &t, MOVEFILE_REPLACE_EXISTING);
        json_record(
            13,
            "MoveFileExW",
            "readonly target",
            &s,
            &t,
            ok,
            code,
            "readonly replacement",
        );
        unsafe { SetFileAttributesW(wt.as_ptr(), 0x80) };

        let s = root.join("new-target.tmp");
        let t = root.join("new-target.active");
        fs::write(&s, "new").map_err(|e| e.to_string())?;
        let (ok, code) = move_file(&s, &t, 0);
        json_record(
            14,
            "MoveFileExW",
            "flags=0 new target",
            &s,
            &t,
            ok,
            code,
            "new target rename",
        );

        let mut loop_ok = true;
        let mut loop_code = 0;
        let t = root.join("loop.active");
        fs::write(&t, "0").map_err(|e| e.to_string())?;
        for n in 1..=32 {
            let s = root.join("loop.tmp");
            fs::write(&s, n.to_string()).map_err(|e| e.to_string())?;
            let r = move_file(&s, &t, MOVEFILE_REPLACE_EXISTING);
            if !r.0 {
                loop_ok = false;
                loop_code = r.1;
                break;
            }
        }
        json_record(
            15,
            "MoveFileExW",
            "32 repeated replacements",
            &root.join("loop.tmp"),
            &t,
            loop_ok,
            loop_code,
            "repeated replace loop",
        );

        let exe = env::current_exe().map_err(|e| e.to_string())?;
        for (id, phase) in [(16_u8, "after_flush"), (17_u8, "after_replace")] {
            let child_root = root.join(phase);
            let status = Command::new(&exe)
                .args([
                    "diagnose-crash-child",
                    "--root",
                    &child_root.display().to_string(),
                    "--phase",
                    phase,
                ])
                .status()
                .map_err(|e| e.to_string())?;
            let expected = if phase == "after_flush" { "old" } else { "new" };
            let bytes = fs::read_to_string(child_root.join("crash.active")).unwrap_or_default();
            json_record(
                id,
                "process::abort",
                phase,
                &child_root.join("crash.active.tmp"),
                &child_root.join("crash.active"),
                !status.success() && bytes == expected,
                0,
                "child terminated after requested boundary",
            );
        }
        let after_flush =
            fs::read_to_string(root.join("after_flush/crash.active")).unwrap_or_default();
        let after_replace =
            fs::read_to_string(root.join("after_replace/crash.active")).unwrap_or_default();
        json_record(
            18,
            "selector byte verification",
            "after child termination",
            &root.join("after_flush/crash.active"),
            &root.join("after_replace/crash.active"),
            after_flush == "old" && after_replace == "new",
            0,
            "selector bytes verified after crash children",
        );
        Ok(())
    }
}
fn path_type(path: &Path) -> &'static str {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_file() => "file",
        Ok(metadata) if metadata.file_type().is_dir() => "directory",
        Ok(metadata) if metadata.file_type().is_symlink() => "symlink",
        Ok(_) => "other",
        Err(_) => "missing",
    }
}
#[allow(clippy::too_many_arguments)]
fn diagnostic_step(
    op: &str,
    event_name: &str,
    step: &str,
    operation: &str,
    source: &Path,
    target: &Path,
    status: &str,
    error: Option<&std::io::Error>,
) {
    if !activation_diagnostic_enabled() {
        return;
    }
    let raw = error.and_then(std::io::Error::raw_os_error);
    let message = error.map(ToString::to_string).unwrap_or_default();
    let cwd = env::current_dir().unwrap_or_default();
    let target_metadata = fs::metadata(target).ok();
    emit(&format!(
        r#"{{"schema_version":1,"event":"{}","op_id":"{}","step_id":"{}","function":"activate","operation":"{}","source":"{}","target":"{}","native_source":"{}","native_target":"{}","object_type":"{}","source_exists":{},"target_exists":{},"parent_exists":{},"target_readonly":{},"target_size":{},"handle_open":false,"handle_closed":true,"requested_access":"{}","share_mode":"{}","rename_replace_flags":"std-fs-rename","flush_sync_primitive":"{}","status":"{}","raw_os_error":{},"win32_code":{},"error_text":"{}","cwd":"{}","last_successful_activation_step":"{}"}}"#,
        event_name,
        esc(op),
        step,
        operation,
        esc(&source.display().to_string()),
        esc(&target.display().to_string()),
        esc(&source.display().to_string()),
        esc(&target.display().to_string()),
        path_type(target),
        source.exists(),
        target.exists(),
        target.parent().is_some_and(Path::exists),
        target_metadata
            .as_ref()
            .is_some_and(|m| m.permissions().readonly()),
        target_metadata.as_ref().map_or(0, fs::Metadata::len),
        DIRECTORY_REQUESTED_ACCESS,
        DIRECTORY_SHARE_MODE,
        DIRECTORY_FLUSH_PRIMITIVE,
        status,
        raw.map_or("null".into(), |v| v.to_string()),
        raw.map_or("null".into(), |v| v.to_string()),
        esc(&message),
        esc(&cwd.display().to_string()),
        match step {
            "selector_temp_write" => "generation_built",
            "selector_replace" => "selector_temp_flushed",
            _ => "selector_replace",
        }
    ));
}
fn diagnose_directory_open(op: &str, root: &Path) -> Result<(), String> {
    diagnostic_step(
        op,
        "diag_handle_open",
        "probe_directory_open",
        "File::open",
        root,
        root,
        "begin",
        None,
    );
    match open_directory_for_sync(root) {
        Ok(handle) => {
            diagnostic_step(
                op,
                "diag_handle_open",
                "probe_directory_open",
                "File::open",
                root,
                root,
                "ok",
                None,
            );
            diagnostic_step(
                op,
                "diag_flush_begin",
                "probe_directory_sync",
                DIRECTORY_FLUSH_PRIMITIVE,
                root,
                root,
                "begin",
                None,
            );
            flush_directory_for_sync(&handle).map_err(|error| {
                diagnostic_step(
                    op,
                    "diag_flush_result",
                    "probe_directory_sync",
                    DIRECTORY_FLUSH_PRIMITIVE,
                    root,
                    root,
                    "error",
                    Some(&error),
                );
                format!(
                    "directory sync probe failed: raw_os_error={:?}; {error}",
                    error.raw_os_error()
                )
            })?;
            diagnostic_step(
                op,
                "diag_flush_result",
                "probe_directory_sync",
                DIRECTORY_FLUSH_PRIMITIVE,
                root,
                root,
                "ok",
                None,
            );
            Ok(())
        }
        Err(error) => {
            diagnostic_step(
                op,
                "diag_failure_context",
                "probe_directory_open",
                "File::open",
                root,
                root,
                "error",
                Some(&error),
            );
            Err(format!(
                "directory open probe failed: object_type={}; raw_os_error={:?}; {error}",
                path_type(root),
                error.raw_os_error()
            ))
        }
    }
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
fn activate(op: &str, root: &Path, id: &str) -> Result<(), String> {
    let state = root.join("state");
    let tmp = state.join("active.tmp");
    let active_path = state.join("active");
    diagnostic_step(
        op,
        "diag_activation_step_begin",
        "selector_temp_write",
        "write_and_flush_file",
        &tmp,
        &tmp,
        "begin",
        None,
    );
    write_sync(
        &tmp,
        &format!("{{\"schema_version\":1,\"generation_id\":\"{id}\"}}\n"),
    )
    .map_err(|error| format!("activation step selector_temp_write failed: {error}"))?;
    diagnostic_step(
        op,
        "diag_activation_step_result",
        "selector_temp_write",
        "write_and_flush_file",
        &tmp,
        &tmp,
        "ok",
        None,
    );
    diagnostic_step(
        op,
        "diag_replace_begin",
        "selector_replace",
        "std::fs::rename",
        &tmp,
        &active_path,
        "begin",
        None,
    );
    fs::rename(&tmp, &active_path).map_err(|error| {
        diagnostic_step(
            op,
            "diag_replace_result",
            "selector_replace",
            "std::fs::rename",
            &tmp,
            &active_path,
            "error",
            Some(&error),
        );
        format!(
            "activation step selector_replace failed: {error}; raw_os_error={:?}",
            error.raw_os_error()
        )
    })?;
    diagnostic_step(
        op,
        "diag_replace_result",
        "selector_replace",
        "std::fs::rename",
        &tmp,
        &active_path,
        "ok",
        None,
    );
    diagnostic_step(
        op,
        "diag_handle_open",
        "parent_directory_open",
        "File::open",
        &state,
        &state,
        "begin",
        None,
    );
    let directory = open_directory_for_sync(&state).map_err(|error| {
        diagnostic_step(op, "diag_failure_context", "parent_directory_open", "File::open", &state, &state, "error", Some(&error));
        format!("activation step parent_directory_open failed: source={}; target={}; object_type={}; raw_os_error={:?}; error={error}", state.display(), state.display(), path_type(&state), error.raw_os_error())
    })?;
    diagnostic_step(
        op,
        "diag_handle_open",
        "parent_directory_open",
        "File::open",
        &state,
        &state,
        "ok",
        None,
    );
    diagnostic_step(
        op,
        "diag_flush_begin",
        "parent_directory_sync",
        DIRECTORY_FLUSH_PRIMITIVE,
        &state,
        &state,
        "begin",
        None,
    );
    flush_directory_for_sync(&directory).map_err(|error| {
        diagnostic_step(op, "diag_flush_result", "parent_directory_sync", DIRECTORY_FLUSH_PRIMITIVE, &state, &state, "error", Some(&error));
        format!("activation step parent_directory_sync failed: source={}; target={}; object_type={}; raw_os_error={:?}; error={error}", state.display(), state.display(), path_type(&state), error.raw_os_error())
    })?;
    diagnostic_step(
        op,
        "diag_flush_result",
        "parent_directory_sync",
        DIRECTORY_FLUSH_PRIMITIVE,
        &state,
        &state,
        "ok",
        None,
    );
    diagnostic_step(
        op,
        "diag_handle_close",
        "parent_directory_close",
        "drop(File)",
        &state,
        &state,
        "ok",
        None,
    );
    Ok(())
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
    if let Err(error) = activate(op, root, &id) {
        if activation_diagnostic_enabled() {
            return fail(
                op,
                "ACTIVATION_IO_ERROR",
                &error,
                &active(root),
                &previous,
                "recovery_required",
            );
        }
        return Err(error);
    }
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
    activate(op, root, &previous)?;
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
        "diagnose-directory-open" => diagnose_directory_open(&op, &root),
        #[cfg(windows)]
        "diagnose-selector-durability" => windows_durability_probe::run(&root),
        #[cfg(windows)]
        "diagnose-crash-child" => windows_durability_probe::crash_child(&root, &arg("--phase", "")),
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
    fn directory_sync_helper_opens_existing_directory() {
        let dir = TestDir::new("directory-sync-open");
        assert!(open_directory_for_sync(&dir.0).is_ok());
    }

    #[test]
    fn directory_sync_helper_reaches_sync_all() {
        let dir = TestDir::new("directory-sync-flush");
        let handle = open_directory_for_sync(&dir.0).expect("open directory for sync");
        handle.sync_all().expect("sync directory");
    }

    #[test]
    fn directory_sync_helper_rejects_missing_directory() {
        let dir = TestDir::new("directory-sync-missing");
        assert!(open_directory_for_sync(&dir.0.join("missing")).is_err());
    }

    #[test]
    fn directory_sync_helper_file_behavior_is_platform_explicit() {
        let dir = TestDir::new("directory-sync-file");
        let file = dir.file("not-a-directory", b"fixture");
        #[cfg(windows)]
        assert_eq!(
            open_directory_for_sync(&file)
                .expect_err("Windows helper rejects files")
                .kind(),
            io::ErrorKind::InvalidInput
        );
        #[cfg(not(windows))]
        assert!(open_directory_for_sync(&file).is_ok());
    }

    #[test]
    fn directory_sync_helper_reports_readonly_directory_behavior() {
        let dir = TestDir::new("directory-sync-readonly");
        let mut permissions = fs::metadata(&dir.0).expect("metadata").permissions();
        permissions.set_readonly(true);
        fs::set_permissions(&dir.0, permissions).expect("set readonly");
        let result = open_directory_for_sync(&dir.0);
        let mut restore = fs::metadata(&dir.0).expect("metadata").permissions();
        restore.set_readonly(false);
        fs::set_permissions(&dir.0, restore).expect("restore permissions");
        assert!(result.is_ok());
    }

    #[test]
    fn windows_directory_sync_helper_uses_write_access_and_backup_semantics() {
        let source = include_str!("main.rs");
        let start = source.find("fn open_directory_for_sync").expect("helper");
        let end = source[start..]
            .find("fn activation_diagnostic_enabled")
            .expect("helper end")
            + start;
        let helper = &source[start..end];
        assert!(helper.contains("GENERIC_WRITE"));
        assert!(helper.contains("FILE_FLAG_BACKUP_SEMANTICS"));
        assert!(helper.contains("FILE_SHARE_READ_WRITE_DELETE"));
        assert!(helper.contains("FlushFileBuffers"));
        assert!(helper.contains("GetLastError"));
        assert!(!helper.contains(".read(true)"));
    }

    #[test]
    fn directory_sync_helper_uses_no_subprocess_or_dependency() {
        let source = include_str!("main.rs");
        let start = source.find("fn open_directory_for_sync").expect("helper");
        let end = source[start..]
            .find("fn activation_diagnostic_enabled")
            .expect("helper end")
            + start;
        let helper = &source[start..end];
        assert!(!helper.contains("Command::new"));
        assert!(!helper.to_ascii_lowercase().contains("powershell"));
        assert!(!helper.contains("retry"));
    }

    #[test]
    fn non_windows_directory_sync_route_remains_file_open() {
        let source = include_str!("main.rs");
        assert!(source.contains("#[cfg(not(windows))]\nfn open_directory_for_sync(path: &Path) -> std::io::Result<File> {\n    File::open(path)\n}"));
    }

    #[test]
    fn selector_replace_still_precedes_directory_sync() {
        let source = include_str!("main.rs");
        let activate = source.find("fn activate(").expect("activate");
        let replace = source[activate..]
            .find("fs::rename(&tmp, &active_path)")
            .expect("replace")
            + activate;
        let directory_open = source[activate..]
            .find("open_directory_for_sync(&state)")
            .expect("directory open")
            + activate;
        let sync = source[activate..]
            .find("flush_directory_for_sync(&directory)")
            .expect("directory flush")
            + activate;
        assert!(replace < directory_open && directory_open < sync);
    }

    #[test]
    fn directory_open_and_sync_remain_fail_closed() {
        let source = include_str!("main.rs");
        let activate = source.find("fn activate(").expect("activate");
        let body = &source
            [activate..source[activate..].find("fn sqlite(").expect("activate end") + activate];
        assert!(body.contains("open_directory_for_sync(&state).map_err"));
        assert!(body.contains("flush_directory_for_sync(&directory).map_err"));
    }

    #[test]
    fn activation_success_follows_parent_directory_flush() {
        let source = include_str!("main.rs");
        let activate = source.find("fn activate(").expect("activate");
        let body = &source
            [activate..source[activate..].find("fn sqlite(").expect("activate end") + activate];
        let flush = body
            .find("flush_directory_for_sync(&directory)")
            .expect("parent flush");
        let success = body.rfind("Ok(())").expect("activation success");
        assert!(flush < success);
        assert!(!body.contains("unwrap()"));
        assert!(!body.contains("expect("));
        assert!(!body.contains("retry"));
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
