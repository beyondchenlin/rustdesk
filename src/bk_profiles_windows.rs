//! Protected machine-wide selection; only the elevated restart helper writes HKLM.
use super::{Phase, Profile, Selection, RUNTIME};
use serde_json::{json, Value};
use std::{
    ffi::OsStr,
    process::Command,
    thread,
    time::{Duration, Instant},
};
use windows_service::{
    service::{Service, ServiceAccess, ServiceState},
    service_manager::{ServiceManager, ServiceManagerAccess},
};
use winreg::{
    enums::{HKEY_LOCAL_MACHINE, KEY_READ, KEY_WOW64_64KEY, KEY_WRITE},
    RegKey,
};
const REGISTRY_KEY: &str = "SOFTWARE\\BK Remote";
const REGISTRY_VALUE: &str = "ServerProfileV1";

pub(super) fn read_selection() -> Result<Selection, &'static str> {
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let key = match hklm.open_subkey_with_flags(REGISTRY_KEY, KEY_READ | KEY_WOW64_64KEY) {
        Ok(key) => key,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Selection::default())
        }
        Err(_) => return Err("Cannot read the protected server profile selection"),
    };
    match key.get_value::<String, _>(REGISTRY_VALUE) {
        Ok(raw) => Selection::decode(&raw),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Selection::default()),
        Err(_) => Err("Cannot read the protected server profile selection"),
    }
}
fn write_selection(value: &Selection) -> Result<(), &'static str> {
    let (key, _) = RegKey::predef(HKEY_LOCAL_MACHINE)
        .create_subkey_with_flags(REGISTRY_KEY, KEY_READ | KEY_WRITE | KEY_WOW64_64KEY)
        .map_err(|_| "Administrator permission is required to change the server profile")?;
    let raw =
        serde_json::to_string(value).map_err(|_| "Cannot encode the server profile selection")?;
    key.set_value(REGISTRY_VALUE, &raw)
        .map_err(|_| "Cannot save the protected server profile selection")?;
    // winreg 0.11 has no flush wrapper. Retain the fixed dependency and use its raw handle.
    let result = unsafe { winapi::um::winreg::RegFlushKey(key.raw_handle()) };
    if result == 0 {
        Ok(())
    } else {
        Err("Cannot save the protected server profile selection")
    }
}
struct SwitchLock(winapi::shared::ntdef::HANDLE);
impl SwitchLock {
    fn acquire() -> Result<Self, &'static str> {
        use winapi::um::{
            handleapi::CloseHandle,
            synchapi::{CreateMutexW, WaitForSingleObject},
        };
        let name: Vec<u16> = "Global\\BKRemoteServerProfileSwitchV1\0"
            .encode_utf16()
            .collect();
        let handle = unsafe { CreateMutexW(std::ptr::null_mut(), 0, name.as_ptr()) };
        if handle.is_null() {
            return Err("Cannot acquire the server profile switch lock");
        }
        let result = unsafe { WaitForSingleObject(handle, 0) };
        if result != 0 && result != 0x80 {
            unsafe {
                CloseHandle(handle);
            }
            return Err("Another server profile switch is already running");
        }
        Ok(Self(handle))
    }
}
impl Drop for SwitchLock {
    fn drop(&mut self) {
        unsafe {
            winapi::um::synchapi::ReleaseMutex(self.0);
            winapi::um::handleapi::CloseHandle(self.0);
        }
    }
}
fn service() -> Result<Option<Service>, &'static str> {
    let manager = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)
        .map_err(|_| "Cannot open the service manager")?;
    match manager.open_service(
        crate::bk_remote::BRAND,
        ServiceAccess::QUERY_STATUS | ServiceAccess::STOP | ServiceAccess::START,
    ) {
        Ok(service) => Ok(Some(service)),
        Err(windows_service::Error::Winapi(error)) if error.raw_os_error() == Some(1060) => {
            Ok(None)
        }
        Err(_) => Err("Cannot control the BK Remote service"),
    }
}
fn wait_service(service: &Service, expected: ServiceState) -> Result<(), &'static str> {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if service
            .query_status()
            .map_err(|_| "Cannot query the BK Remote service")?
            .current_state
            == expected
        {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err("The BK Remote service did not reach the required state");
        }
        thread::sleep(Duration::from_millis(200));
    }
}
fn stop_service(service: &Service) -> Result<(), &'static str> {
    let state = service
        .query_status()
        .map_err(|_| "Cannot query the BK Remote service")?
        .current_state;
    if state == ServiceState::Stopped {
        return Ok(());
    }
    if state != ServiceState::StopPending {
        service
            .stop()
            .map_err(|_| "Cannot stop the BK Remote service")?;
    }
    wait_service(service, ServiceState::Stopped)
}
fn start_service(service: &Service) -> Result<(), &'static str> {
    service
        .start(&[] as &[&OsStr])
        .map_err(|_| "Cannot start the BK Remote service")?;
    wait_service(service, ServiceState::Running)
}
fn validate_process() -> Result<(), &'static str> {
    let status = Command::new(
        std::env::current_exe().map_err(|_| "Cannot locate the BK Remote executable")?,
    )
    .arg("--bk-profile-check")
    .status()
    .map_err(|_| "Cannot validate the new server profile")?;
    if status.success() {
        Ok(())
    } else {
        Err("The new server profile could not be opened")
    }
}
fn probe(selection: &Selection) -> bool {
    let Ok(runtime) = hbb_common::tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    else {
        return false;
    };
    runtime
        .block_on(crate::ipc::bk_profile_probe(
            selection.active.namespace(),
            selection.generation,
        ))
        .unwrap_or(false)
}
fn wait_probe(selection: &Selection) -> Result<(), &'static str> {
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        if probe(selection) {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(200));
    }
    Err("The new service did not confirm its server profile")
}
fn apply(target: Profile, expected_generation: u64, recover: bool) -> Result<(), &'static str> {
    let _lock = SwitchLock::acquire()?;
    let old = read_selection()?;
    if old.generation != expected_generation {
        return Err("Server profile selection changed; refresh and try again");
    }
    let pending = if recover {
        let mut value = old.rolled_back()?;
        value.phase = Phase::Testing;
        value.previous = Some(old.active);
        value.result = "pending".into();
        value
    } else {
        old.begin(target)?
    };
    let controlled_service = service()?;
    let was_running = if let Some(service) = controlled_service.as_ref() {
        let state = service
            .query_status()
            .map_err(|_| "Cannot query the BK Remote service")?
            .current_state;
        if state != ServiceState::Running && state != ServiceState::Stopped {
            return Err("The BK Remote service is changing state; try again after it finishes");
        }
        state == ServiceState::Running
    } else {
        false
    };
    // Verify protected store access before interrupting a running service.
    write_selection(&old)?;
    if was_running {
        if let Some(service) = controlled_service.as_ref() {
            stop_service(service)?;
        }
    }
    if let Err(error) = write_selection(&pending) {
        // A registry flush can fail after the value was replaced. Restore explicitly.
        let restored = pending.restore_after_failure(&old)?;
        write_selection(&restored)?;
        if was_running {
            if let Some(service) = controlled_service.as_ref() {
                start_service(service)?;
                wait_probe(&restored)?;
            }
        }
        return Err(error);
    }
    let result = (|| {
        validate_process()?;
        if was_running {
            if let Some(service) = controlled_service.as_ref() {
                start_service(service)?;
                wait_probe(&pending)?;
            }
        }
        write_selection(&pending.committed())
    })();
    if result.is_err() {
        if let Some(service) = controlled_service.as_ref() {
            let _ = stop_service(service);
        }
        let restored = pending.restore_after_failure(&old)?;
        write_selection(&restored)?;
        if was_running {
            if let Some(service) = controlled_service.as_ref() {
                start_service(service)?;
                wait_probe(&restored)?;
            }
        }
    }
    result
}
pub(super) fn request_switch(
    target: Profile,
    generation: u64,
    recover: bool,
) -> Result<Value, &'static str> {
    // Relaunch retains the user's session; the elevated transaction does not launch the GUI.
    let mut relaunch = Command::new(
        std::env::current_exe().map_err(|_| "Cannot locate the BK Remote executable")?,
    )
    .arg("--bk-profile-relaunch")
    .arg(generation.to_string())
    .arg(std::process::id().to_string())
    .spawn()
    .map_err(|_| "Cannot prepare the BK Remote restart")?;
    let operation = if recover {
        "--bk-profile-recover"
    } else {
        "--bk-profile-switch"
    };
    match crate::platform::windows::elevate(&format!("{operation} {} {generation}", target.id())) {
        Ok(true) => Ok(json!({"restart":"automatic"})),
        _ => {
            let _ = relaunch.kill();
            Err("Administrator approval was not completed")
        }
    }
}
pub(super) fn start_generation_watch() {
    let Some(runtime) = RUNTIME.get() else {
        return;
    };
    let generation = runtime.selection.generation;
    let profile = runtime.selection.active;
    if runtime.error.is_some() {
        return;
    }
    thread::spawn(move || loop {
        thread::sleep(Duration::from_millis(500));
        if let Ok(selection) = read_selection() {
            if selection.generation != generation || selection.active != profile {
                // Explicitly confirmed restart discards every upstream process-local cache together.
                std::process::exit(0);
            }
        }
    });
}
fn relaunch(generation: u64, old_pid: u32) -> Result<(), &'static str> {
    let deadline = Instant::now() + Duration::from_secs(90);
    loop {
        let selection = read_selection()?;
        if selection.generation != generation && selection.phase == Phase::Stable {
            break;
        }
        if Instant::now() >= deadline {
            return Err("The server profile switch was not completed");
        }
        thread::sleep(Duration::from_millis(250));
    }
    unsafe {
        let handle = winapi::um::processthreadsapi::OpenProcess(0x00100000, 0, old_pid);
        if !handle.is_null() {
            let result = winapi::um::synchapi::WaitForSingleObject(handle, 10_000);
            winapi::um::handleapi::CloseHandle(handle);
            if result != 0 {
                return Err("Close the old BK Remote window before reopening it");
            }
        }
    }
    Command::new(std::env::current_exe().map_err(|_| "Cannot locate the BK Remote executable")?)
        .spawn()
        .map_err(|_| "Cannot reopen BK Remote")?;
    Ok(())
}
pub(super) fn dispatch_control_args() -> bool {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(operation) = args.first() else {
        return false;
    };
    if !operation.starts_with("--bk-profile-") {
        return false;
    }
    let result = match operation.as_str() {
        "--bk-profile-switch" | "--bk-profile-recover" if args.len() == 3 => {
            match (Profile::parse(&args[1]), args[2].parse::<u64>()) {
                (Ok(target), Ok(generation)) => {
                    apply(target, generation, operation == "--bk-profile-recover")
                }
                _ => Err("Invalid server profile request"),
            }
        }
        "--bk-profile-relaunch" if args.len() == 3 => {
            match (args[1].parse::<u64>(), args[2].parse::<u32>()) {
                (Ok(generation), Ok(pid)) if pid > 0 => relaunch(generation, pid),
                _ => Err("Invalid server profile restart request"),
            }
        }
        "--bk-profile-check" if args.len() == 1 => {
            crate::common::init_sodium();
            crate::bk_remote::initialize_brand();
            let path = hbb_common::config::Config::path("");
            if path.as_os_str().is_empty() || std::fs::create_dir_all(path).is_err() {
                Err("Cannot open the new server profile directory")
            } else {
                let _ = hbb_common::config::Config::get_options();
                Ok(())
            }
        }
        _ => Err("Invalid server profile control operation"),
    };
    if let Err(error) = result {
        eprintln!("{error}");
        std::process::exit(1);
    }
    true
}
