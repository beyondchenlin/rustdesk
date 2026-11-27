//! A private broker is identified by both its fixed name and its canonical path.
//! Never terminate a process selected only by its image name or process ID.
use std::{
    ffi::{c_void, OsString},
    io,
    mem::size_of,
    os::windows::ffi::{OsStrExt, OsStringExt},
    path::{Path, PathBuf},
};

pub(crate) const PRIVATE_HOST_EXE: &str = "RuntimeBroker_BKRemote.exe";
type Handle = *mut c_void;
const QUERY_LIMITED: u32 = 0x1000;
const TERMINATE: u32 = 0x0001;
const SYNCHRONIZE: u32 = 0x0010_0000;
const CSTR_EQUAL: i32 = 2;
const INVALID_HANDLE: Handle = -1isize as Handle;

#[repr(C)]
struct ProcessEntry {
    size: u32,
    usage: u32,
    pid: u32,
    default_heap: usize,
    module: u32,
    threads: u32,
    parent_pid: u32,
    priority: i32,
    flags: u32,
    exe: [u16; 260],
}

#[link(name = "kernel32")]
extern "system" {
    fn OpenProcess(access: u32, inherit: i32, pid: u32) -> Handle;
    fn CloseHandle(handle: Handle) -> i32;
    fn QueryFullProcessImageNameW(
        handle: Handle,
        flags: u32,
        name: *mut u16,
        size: *mut u32,
    ) -> i32;
    fn CompareStringOrdinal(
        a: *const u16,
        alen: i32,
        b: *const u16,
        blen: i32,
        ignore_case: i32,
    ) -> i32;
    fn TerminateProcess(handle: Handle, exit_code: u32) -> i32;
    fn WaitForSingleObject(handle: Handle, milliseconds: u32) -> u32;
    fn CreateToolhelp32Snapshot(flags: u32, pid: u32) -> Handle;
    fn Process32FirstW(snapshot: Handle, entry: *mut ProcessEntry) -> i32;
    fn Process32NextW(snapshot: Handle, entry: *mut ProcessEntry) -> i32;
}

struct OwnedHandle(Handle);
impl OwnedHandle {
    fn new(raw: Handle) -> io::Result<Self> {
        if raw.is_null() || raw == INVALID_HANDLE {
            Err(io::Error::last_os_error())
        } else {
            Ok(Self(raw))
        }
    }
}
impl Drop for OwnedHandle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}

fn path_eq(a: &Path, b: &Path) -> bool {
    let a: Vec<u16> = a.as_os_str().encode_wide().collect();
    let b: Vec<u16> = b.as_os_str().encode_wide().collect();
    unsafe {
        CompareStringOrdinal(a.as_ptr(), a.len() as i32, b.as_ptr(), b.len() as i32, 1)
            == CSTR_EQUAL
    }
}

fn canonical_expected(expected: &Path) -> io::Result<PathBuf> {
    if expected.file_name().and_then(|x| x.to_str()) != Some(PRIVATE_HOST_EXE) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Unexpected private broker name",
        ));
    }
    let parent = expected
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "Missing broker directory"))?;
    let parent = std::fs::canonicalize(parent)?;
    let path = std::fs::canonicalize(expected)?;
    // A file symlink must not turn the private broker into another program,
    // whether it is outside the product directory or under a different name.
    if path.parent().is_none_or(|p| !path_eq(p, &parent))
        || path
            .file_name()
            .and_then(|name| name.to_str())
            .is_none_or(|name| !name.eq_ignore_ascii_case(PRIVATE_HOST_EXE))
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Broker resolved outside its product directory",
        ));
    }
    Ok(path)
}

pub(crate) fn private_host_path() -> io::Result<PathBuf> {
    let exe = std::env::current_exe()?;
    let parent = exe
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "Missing product directory"))?;
    Ok(parent.join(PRIVATE_HOST_EXE))
}

fn matches_open_process(process: &OwnedHandle, expected: &Path) -> io::Result<bool> {
    let mut text = vec![0u16; 32768];
    let mut length = text.len() as u32;
    if unsafe { QueryFullProcessImageNameW(process.0, 0, text.as_mut_ptr(), &mut length) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let actual = PathBuf::from(OsString::from_wide(&text[..length as usize]));
    let actual = std::fs::canonicalize(actual)?;
    Ok(path_eq(&actual, expected))
}

pub(crate) fn process_matches_path(pid: u32, expected: &Path) -> io::Result<bool> {
    let expected = canonical_expected(expected)?;
    let process = OwnedHandle::new(unsafe { OpenProcess(QUERY_LIMITED, 0, pid) })?;
    matches_open_process(&process, &expected)
}

fn stop_if_matches(pid: u32, expected: &Path) -> io::Result<bool> {
    // Query and termination use this same handle, so PID recycling cannot replace
    // the process after verification.
    let process =
        OwnedHandle::new(unsafe { OpenProcess(QUERY_LIMITED | TERMINATE | SYNCHRONIZE, 0, pid) })?;
    if !matches_open_process(&process, expected)? {
        return Ok(false);
    }
    if unsafe { TerminateProcess(process.0, 0) } == 0 {
        return Err(io::Error::last_os_error());
    }
    match unsafe { WaitForSingleObject(process.0, 5000) } {
        0 => Ok(true),
        258 => Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "Private broker did not exit",
        )),
        _ => Err(io::Error::last_os_error()),
    }
}

pub(crate) fn stop_matching_processes(expected: &Path) -> io::Result<usize> {
    let expected = canonical_expected(expected)?;
    let snapshot = OwnedHandle::new(unsafe { CreateToolhelp32Snapshot(2, 0) })?;
    let mut entry: ProcessEntry = unsafe { std::mem::zeroed() };
    entry.size = size_of::<ProcessEntry>() as u32;
    let mut found = unsafe { Process32FirstW(snapshot.0, &mut entry) };
    let mut stopped = 0;
    while found != 0 {
        let len = entry
            .exe
            .iter()
            .position(|x| *x == 0)
            .unwrap_or(entry.exe.len());
        if String::from_utf16_lossy(&entry.exe[..len]).eq_ignore_ascii_case(PRIVATE_HOST_EXE) {
            // Read/access failures never authorize termination or a success-like
            // uninstall. A process that exited after enumeration is already gone.
            match stop_if_matches(entry.pid, &expected) {
                Ok(true) => stopped += 1,
                Ok(false) => {}
                Err(error) if error.raw_os_error() == Some(87) => {}
                Err(error) => return Err(error),
            }
        }
        found = unsafe { Process32NextW(snapshot.0, &mut entry) };
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() != Some(18) {
        // ERROR_NO_MORE_FILES
        return Err(error);
    }
    Ok(stopped)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        process::{Child, Command, Stdio},
        thread,
        time::{Duration, Instant, SystemTime, UNIX_EPOCH},
    };

    #[test]
    fn bk_remote_private_host_child_wait() {
        let Some(ready) = std::env::var_os("BK_REMOTE_PRIVATE_HOST_TEST_READY") else {
            return;
        };
        std::fs::write(ready, b"ready").expect("write child ready marker");
        let mut input = String::new();
        let _ = std::io::stdin().read_line(&mut input);
    }

    struct ChildGuard(Child);
    impl Drop for ChildGuard {
        fn drop(&mut self) {
            if self.0.try_wait().ok().flatten().is_none() {
                let _ = self.0.kill();
            }
            let _ = self.0.wait();
        }
    }

    fn child(exe: &Path, marker: &Path) -> ChildGuard {
        let child = Command::new(exe)
            .args([
                "bk_remote_private_host_child_wait",
                "--nocapture",
                "--test-threads=1",
            ])
            .env("BK_REMOTE_PRIVATE_HOST_TEST_READY", marker)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("start private test child");
        let mut child = ChildGuard(child);
        let start = Instant::now();
        while !marker.exists() {
            assert!(
                child.0.try_wait().expect("query child").is_none(),
                "child exited before ready"
            );
            assert!(
                start.elapsed() < Duration::from_secs(10),
                "test child readiness timeout"
            );
            thread::sleep(Duration::from_millis(20));
        }
        child
    }

    #[test]
    fn private_host_requires_canonical_directory_and_live_process() {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let base = std::env::temp_dir().join(format!(
            "bk-remote-private-host-{}-{stamp}",
            std::process::id()
        ));
        let own = base.join("product").join(PRIVATE_HOST_EXE);
        let foreign = base.join("other-product").join(PRIVATE_HOST_EXE);
        for path in [&own, &foreign] {
            std::fs::create_dir_all(path.parent().expect("parent")).expect("create test directory");
            std::fs::copy(std::env::current_exe().expect("test executable"), path)
                .expect("copy helper");
        }
        {
            let mut own_child = child(&own, &base.join("own.ready"));
            let mut foreign_child = child(&foreign, &base.join("foreign.ready"));
            assert!(process_matches_path(own_child.0.id(), &own).expect("own path query"));
            let canonical_alias = base
                .join("product")
                .join("..")
                .join("product")
                .join(PRIVATE_HOST_EXE);
            assert!(process_matches_path(own_child.0.id(), &canonical_alias)
                .expect("canonical alias query"));
            assert!(!process_matches_path(foreign_child.0.id(), &own).expect("foreign path query"));
            assert!(!process_matches_path(own_child.0.id(), &foreign).expect("reverse path query"));
            let own_canonical = canonical_expected(&own).expect("canonical broker");
            assert!(!stop_if_matches(foreign_child.0.id(), &own_canonical)
                .expect("reject same name in another directory"));
            assert!(foreign_child.0.try_wait().expect("foreign alive").is_none());
            assert!(process_matches_path(
                own_child.0.id(),
                &base.join("missing").join(PRIVATE_HOST_EXE)
            )
            .is_err());
            assert_eq!(
                stop_matching_processes(&own).expect("stop verified owned child"),
                1
            );
            own_child.0.wait().expect("owned child stopped");
            assert!(foreign_child
                .0
                .try_wait()
                .expect("foreign still alive")
                .is_none());
            assert!(process_matches_path(0, &own).is_err());
            assert_eq!(
                stop_matching_processes(&own).expect("no remaining owned child"),
                0
            );
        }
        std::fs::remove_dir_all(base).expect("remove only this test's temporary directory");
    }

    #[test]
    fn private_host_rejects_arbitrary_executable_names() {
        let expected = private_host_path().expect("current product host path");
        assert_eq!(
            expected.file_name().and_then(|name| name.to_str()),
            Some(PRIVATE_HOST_EXE)
        );
        assert!(canonical_expected(Path::new("C:\\Windows\\System32\\RuntimeBroker.exe")).is_err());
        assert!(
            canonical_expected(Path::new("C:\\Windows\\System32\\not-the-private-host.exe"))
                .is_err()
        );
    }
}
