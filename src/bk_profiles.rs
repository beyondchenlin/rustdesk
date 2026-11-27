//! Process-scoped server profiles. Never reload the upstream lazy configuration in place.
//! Only the non-secret selection record is shared. Each profile owns its native configuration,
//! keys, account tokens, peer credentials, address books and local UI cache.
use hbb_common::config::{self, Config};
use serde_derive::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    path::{Path, PathBuf},
    sync::OnceLock,
};

#[cfg(windows)]
#[path = "bk_profiles_windows.rs"]
mod windows;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Profile {
    Bk,
    Official,
    Manual,
}

impl Profile {
    pub fn id(self) -> &'static str {
        match self {
            Self::Bk => "bk",
            Self::Official => "official",
            Self::Manual => "manual",
        }
    }
    pub fn namespace(self) -> &'static str {
        // Preserve existing BK data in place. Never import the upstream RustDesk namespace.
        match self {
            Self::Bk => "BK Remote",
            Self::Official => "BK Remote Public",
            Self::Manual => "BK Remote Manual",
        }
    }
    fn parse(value: &str) -> Result<Self, &'static str> {
        match value {
            "bk" => Ok(Self::Bk),
            "official" => Ok(Self::Official),
            "manual" => Ok(Self::Manual),
            _ => Err("Invalid server profile"),
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum Phase {
    Stable,
    Testing,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct Selection {
    version: u8,
    active: Profile,
    previous: Option<Profile>,
    generation: u64,
    phase: Phase,
    attempted: bool,
    result: String,
}

impl Default for Selection {
    fn default() -> Self {
        Self {
            version: 1,
            active: Profile::Bk,
            previous: None,
            generation: 0,
            phase: Phase::Stable,
            attempted: false,
            result: "unchanged".into(),
        }
    }
}

impl Selection {
    fn decode(raw: &str) -> Result<Self, &'static str> {
        if raw.len() > 2048 {
            return Err("Server profile selection is invalid");
        }
        let value: Self =
            serde_json::from_str(raw).map_err(|_| "Server profile selection is invalid")?;
        if value.version != 1
            || (value.phase == Phase::Testing && value.previous.is_none())
            || !matches!(
                value.result.as_str(),
                "unchanged" | "pending" | "completed" | "rolled_back"
            )
            || (value.phase == Phase::Stable && value.attempted)
        {
            return Err("Server profile selection is invalid");
        }
        Ok(value)
    }
    fn begin(&self, target: Profile) -> Result<Self, &'static str> {
        if self.phase != Phase::Stable {
            return Err("A server profile switch requires recovery");
        }
        Ok(Self {
            version: 1,
            active: target,
            previous: Some(self.active),
            generation: self
                .generation
                .checked_add(1)
                .ok_or("Server profile generation is exhausted")?,
            phase: Phase::Testing,
            attempted: false,
            result: "pending".into(),
        })
    }
    fn restore_after_failure(&self, original: &Self) -> Result<Self, &'static str> {
        let mut restored = original.clone();
        restored.generation = self.generation.checked_add(1)
            .ok_or("Server profile generation is exhausted")?;
        restored.result = if original.phase == Phase::Stable { "rolled_back" } else { "pending" }.into();
        Ok(restored)
    }
    fn committed(&self) -> Self {
        let mut value = self.clone();
        value.phase = Phase::Stable;
        value.attempted = false;
        value.result = "completed".into();
        value
    }
    fn rolled_back(&self) -> Result<Self, &'static str> {
        Ok(Self {
            version: 1,
            active: self
                .previous
                .ok_or("No previous server profile is available")?,
            previous: None,
            generation: self
                .generation
                .checked_add(1)
                .ok_or("Server profile generation is exhausted")?,
            phase: Phase::Stable,
            attempted: false,
            result: "rolled_back".into(),
        })
    }
}

struct Runtime {
    selection: Selection,
    base: Option<PathBuf>,
    error: Option<&'static str>,
}
static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static PROFILE_INIT: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn set_runtime(selection: Selection, base: Option<PathBuf>, error: Option<&'static str>) {
    let namespace = selection.active.namespace().to_owned();
    let app_dir = base
        .as_ref()
        .map(|root| profile_dir(root, selection.active));
    if RUNTIME
        .set(Runtime {
            selection,
            base,
            error,
        })
        .is_ok()
    {
        *config::APP_NAME.write().unwrap() = namespace;
        if let Some(path) = app_dir {
            *config::APP_DIR.write().unwrap() = path.to_string_lossy().into_owned();
        }
        if error.is_none() {
            crate::bk_remote::apply_public_server_defaults(current());
        }
        if error.is_none() && current() != Profile::Bk && Config::get_id_or(String::new()).is_empty() {
            // Upstream desktop IDs derive from the MAC address. A fresh independent profile
            // must not replace another profile's device mapping on the same rendezvous server.
            use hbb_common::rand::{self, Rng};
            let range = if current() == Profile::Official {
                1_000_000_000_u32..1_500_000_000_u32
            } else {
                1_500_000_000_u32..2_000_000_000_u32
            };
            Config::set_id(&rand::thread_rng().gen_range(range).to_string());
        }
        #[cfg(windows)]
        windows::start_generation_watch();
    }
}

fn profile_dir(base: &Path, profile: Profile) -> PathBuf {
    // BK's existing directory is retained; the other two profiles start empty.
    match profile {
        Profile::Bk => base.to_owned(),
        _ => base.join("bk-profiles").join(profile.id()),
    }
}

pub fn initialize_desktop() {
    let _guard = PROFILE_INIT.lock().unwrap();
    #[cfg(windows)]
    if RUNTIME.get().is_none() {
        match windows::read_selection() {
            Ok(selection) => set_runtime(selection, None, None),
            Err(error) => set_runtime(Selection::default(), None, Some(error)),
        }
    }
    #[cfg(not(any(windows, target_os = "android", target_os = "ios")))]
    if RUNTIME.get().is_none() {
        set_runtime(Selection::default(), None, None);
    }
}

#[cfg(any(target_os = "android", target_os = "ios"))]
fn read_mobile_selection(base: &Path) -> Result<Selection, &'static str> {
    match std::fs::read_to_string(base.join("bk-profile-selection.json")) {
        Ok(raw) => Selection::decode(&raw),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Selection::default()),
        Err(_) => Err("Cannot read the server profile selection"),
    }
}

#[cfg(any(target_os = "android", target_os = "ios"))]
fn write_mobile_selection(base: &Path, value: &Selection) -> Result<(), &'static str> {
    use std::io::Write;
    std::fs::create_dir_all(base).map_err(|_| "Cannot create the server profile directory")?;
    let path = base.join("bk-profile-selection.json");
    let pending = base.join(format!(".bk-profile-{}.tmp", uuid::Uuid::new_v4()));
    let bytes =
        serde_json::to_vec(value).map_err(|_| "Cannot encode the server profile selection")?;
    let result = (|| {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&pending)
            .map_err(|_| "Cannot save the server profile selection")?;
        file.write_all(&bytes)
            .and_then(|_| file.sync_all())
            .map_err(|_| "Cannot save the server profile selection")?;
        std::fs::rename(&pending, &path)
            .map_err(|_| "Cannot replace the server profile selection")?;
        if let Ok(directory) = std::fs::File::open(base) {
            let _ = directory.sync_all();
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&pending);
    }
    result
}

#[cfg(any(target_os = "android", target_os = "ios"))]
pub fn initialize_mobile(app_dir: &str) {
    let _guard = PROFILE_INIT.lock().unwrap();
    if RUNTIME.get().is_some() {
        return;
    }
    let base = PathBuf::from(app_dir);
    if !base.is_absolute() {
        set_runtime(
            Selection::default(),
            Some(base),
            Some("Invalid server profile directory"),
        );
        return;
    }
    let selected = (|| {
        let mut selection = read_mobile_selection(&base)?;
        if selection.phase == Phase::Testing {
            if selection.attempted {
                // A previous new-process startup never reached the readiness acknowledgement.
                selection = selection.rolled_back()?;
            } else {
                selection.attempted = true;
            }
            write_mobile_selection(&base, &selection)?;
        }
        if std::fs::create_dir_all(profile_dir(&base, selection.active)).is_err() {
            if selection.phase == Phase::Testing {
                selection = selection.rolled_back()?;
                write_mobile_selection(&base, &selection)?;
            } else {
                return Err("Cannot open the server profile directory");
            }
        }
        Ok(selection)
    })();
    match selected {
        Ok(selection) => set_runtime(selection, Some(base), None),
        Err(error) => set_runtime(Selection::default(), Some(base), Some(error)),
    }
}

fn stored_selection() -> Result<Selection, &'static str> {
    #[cfg(windows)]
    {
        return windows::read_selection();
    }
    #[cfg(any(target_os = "android", target_os = "ios"))]
    {
        let base = RUNTIME
            .get()
            .and_then(|x| x.base.as_ref())
            .ok_or("Server profile is not initialized")?;
        return read_mobile_selection(base);
    }
    #[cfg(not(any(windows, target_os = "android", target_os = "ios")))]
    {
        Ok(RUNTIME
            .get()
            .map(|x| x.selection.clone())
            .unwrap_or_default())
    }
}

pub fn current() -> Profile {
    RUNTIME
        .get()
        .map(|x| x.selection.active)
        .unwrap_or(Profile::Bk)
}

pub fn is_current() -> bool {
    let Some(runtime) = RUNTIME.get() else {
        return false;
    };
    if runtime.error.is_some() {
        return false;
    }
    stored_selection()
        .map(|value| {
            value.active == runtime.selection.active
                && value.generation == runtime.selection.generation
                && value.phase == Phase::Stable
        })
        .unwrap_or(false)
}

pub fn uuid() -> Vec<u8> {
    let original = hbb_common::get_uuid();
    if original.is_empty() || current() == Profile::Bk {
        return original;
    }
    scoped_uuid(&original, current())
}

fn scoped_uuid(original: &[u8], profile: Profile) -> Vec<u8> {
    let mut digest = Sha256::new();
    digest.update(b"bk-remote-profile-identity-v1\0");
    digest.update(profile.id().as_bytes());
    digest.update([0]);
    digest.update(original);
    digest.finalize().to_vec()
}

pub fn ready() -> bool {
    if !is_current() {
        return false;
    }
    match current() {
        Profile::Official => true,
        Profile::Manual => !Config::get_option("custom-rendezvous-server")
            .trim()
            .is_empty(),
        Profile::Bk => {
            !Config::get_option("custom-rendezvous-server")
                .trim()
                .is_empty()
                && crate::decode64(Config::get_option("key"))
                    .map(|x| x.len() == 32)
                    .unwrap_or(false)
        }
    }
}

pub fn rendezvous_servers() -> Vec<String> {
    if ready() {
        Config::get_rendezvous_servers()
    } else {
        Vec::new()
    }
}
pub fn rendezvous_server() -> String {
    if ready() {
        Config::get_rendezvous_server()
    } else {
        String::new()
    }
}

pub fn probe_identity() -> String {
    let generation = RUNTIME.get().map(|x| x.selection.generation).unwrap_or(0);
    format!("{}:{}", current().namespace(), generation)
}

pub fn status() -> Value {
    let stored = stored_selection();
    let runtime = RUNTIME.get();
    let error = runtime
        .and_then(|x| x.error)
        .or_else(|| stored.as_ref().err().copied());
    let selection = stored.as_ref().ok();
    json!({
        "profile": current().id(), "namespace": current().namespace(),
        "stored_profile": selection.map(|x| x.active.id()),
        "generation": selection.map(|x| x.generation),
        "phase": selection.map(|x| if x.phase == Phase::Stable { "stable" } else { "testing" }),
        "result": selection.map(|x| x.result.as_str()),
        "ready": ready(), "error": error,
        "can_switch": cfg!(any(windows, target_os = "android")),
        "rollback_available": selection.map(|x| x.previous.is_some()).unwrap_or(false),
        "rendezvous": Config::get_option("custom-rendezvous-server"),
        "api": Config::get_option("api-server"),
        "key_configured": !Config::get_option("key").is_empty(),
        "restart_required": !is_current(),
    })
}

pub fn request_switch(
    target: &str,
    expected_generation: u64,
    recover: bool,
) -> Result<Value, &'static str> {
    let target = Profile::parse(target)?;
    let stored = stored_selection()?;
    if stored.generation != expected_generation {
        return Err("Server profile selection changed; refresh and try again");
    }
    if !recover && stored.phase == Phase::Stable && stored.active == target {
        return Ok(json!({"restart":"none"}));
    }
    #[cfg(windows)]
    {
        return windows::request_switch(target, expected_generation, recover);
    }
    #[cfg(target_os = "android")]
    {
        let runtime = RUNTIME.get().ok_or("Server profile is not initialized")?;
        let base = runtime
            .base
            .as_ref()
            .ok_or("Server profile is not initialized")?;
        let pending = if recover {
            stored.rolled_back()?
        } else {
            stored.begin(target)?
        };
        std::fs::create_dir_all(profile_dir(base, pending.active))
            .map_err(|_| "Cannot create the server profile directory")?;
        write_mobile_selection(base, &pending)?;
        return Ok(json!({"restart":"android"}));
    }
    #[cfg(not(any(windows, target_os = "android")))]
    {
        let _ = (target, recover);
        Err("Server profile switching is unavailable on this platform")
    }
}

pub fn abort_mobile_switch() -> Result<Value, &'static str> {
    #[cfg(target_os = "android")]
    {
        let runtime = RUNTIME.get().ok_or("Server profile is not initialized")?;
        let base = runtime
            .base
            .as_ref()
            .ok_or("Server profile is not initialized")?;
        // The original process is still alive: restore its exact generation, without touching data.
        write_mobile_selection(base, &runtime.selection.committed())?;
        return Ok(json!({"restored":true}));
    }
    #[cfg(not(target_os = "android"))]
    {
        Err("No mobile server profile switch is pending")
    }
}

pub fn confirm_mobile_startup() -> Result<Value, &'static str> {
    #[cfg(any(target_os = "android", target_os = "ios"))]
    {
        let runtime = RUNTIME.get().ok_or("Server profile is not initialized")?;
        if let Some(error) = runtime.error {
            return Err(error);
        }
        let base = runtime
            .base
            .as_ref()
            .ok_or("Server profile is not initialized")?;
        let stored = read_mobile_selection(base)?;
        if stored.active != runtime.selection.active
            || stored.generation != runtime.selection.generation
        {
            return Err("Restart is required to activate the server profile");
        }
        if stored.phase == Phase::Testing {
            // Force the fixed upstream lazy caches to load before acknowledging a new process.
            let _ = Config::get_options();
            let _ = config::LocalConfig::get_option("access_token");
            write_mobile_selection(base, &stored.committed())?;
        }
    }
    Ok(json!({"ready":true}))
}

pub fn dispatch_control_args() -> bool {
    #[cfg(windows)]
    {
        return windows::dispatch_control_args();
    }
    #[cfg(not(windows))]
    {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn profile_names_paths_and_device_identifiers_are_disjoint_and_stable() {
        let root = PathBuf::from("/private/bk");
        assert_eq!(profile_dir(&root, Profile::Bk), root);
        assert_ne!(
            profile_dir(&root, Profile::Manual),
            profile_dir(&root, Profile::Official)
        );
        assert_ne!(Profile::Bk.namespace(), Profile::Official.namespace());
        assert_ne!(
            scoped_uuid(b"machine", Profile::Official),
            scoped_uuid(b"machine", Profile::Manual)
        );
        assert_eq!(
            scoped_uuid(b"machine", Profile::Official),
            scoped_uuid(b"machine", Profile::Official)
        );
    }
    #[test]
    fn transaction_rolls_back_without_reusing_a_generation() {
        let old = Selection::default();
        let pending = old.begin(Profile::Official).unwrap();
        assert_eq!(pending.phase, Phase::Testing);
        assert!(pending.begin(Profile::Manual).is_err());
        let failed = pending.rolled_back().unwrap();
        assert_eq!(failed.active, old.active);
        assert_eq!(failed.phase, Phase::Stable);
        assert!(failed.generation > pending.generation);
        assert_eq!(pending.committed().active, Profile::Official);
        assert_eq!(pending.committed().generation, pending.generation);
    }
    #[test]
    fn failed_recovery_never_promotes_an_interrupted_candidate() {
        let initial = Selection::default();
        let interrupted = initial.begin(Profile::Official).unwrap();
        let mut recovery = interrupted.rolled_back().unwrap();
        recovery.phase = Phase::Testing;
        recovery.previous = Some(interrupted.active);
        let restored = recovery.restore_after_failure(&interrupted).unwrap();
        assert_eq!(restored.active, Profile::Official);
        assert_eq!(restored.phase, Phase::Testing);
        assert_eq!(restored.previous, Some(Profile::Bk));
        assert!(restored.generation > recovery.generation);
        // The same failure handler also preserves a previously stable profile.
        let stable = interrupted.committed();
        let candidate = stable.begin(Profile::Manual).unwrap();
        let restored = candidate.restore_after_failure(&stable).unwrap();
        assert_eq!(restored.phase, Phase::Stable);
        assert_eq!(restored.active, Profile::Official);
        assert_eq!(restored.previous, stable.previous);
    }
    #[test]
    fn malformed_unknown_and_incomplete_selection_records_fail_closed() {
        assert!(Selection::decode("{}").is_err());
        let mut value = serde_json::to_value(Selection::default()).unwrap();
        value["active"] = json!("untrusted");
        assert!(Selection::decode(&value.to_string()).is_err());
        value["active"] = json!("bk");
        value["phase"] = json!("testing");
        assert!(Selection::decode(&value.to_string()).is_err());
        value["phase"] = json!("stable");
        value["unexpected"] = json!("field");
        assert!(Selection::decode(&value.to_string()).is_err());
    }
}
