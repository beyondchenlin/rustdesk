use hbb_common::{
    config::{self, Config, LocalConfig},
    sodiumoxide::crypto::sign,
};
use serde_derive::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::sync::{Mutex, Once};

pub const BRAND: &str = "BK Remote";
const OFFICIAL_CONFIG_KEY: &str = "5Qbwsde3unUcJBtrx9ZkvUmwFNoExHzpryHuPUdqlWM=";
const ENROLLMENT_PURPOSE: &str = "bk-remote-device-enrollment-v1";
static BRAND_INITIALIZED: Once = Once::new();
// All token/user-info writes in this process share this lock with conditional invalidation.
static ACCOUNT_SESSION_WRITE: Mutex<()> = Mutex::new(());

pub fn set_local_option(key: String, value: String) {
    if matches!(key.as_str(), "access_token" | "user_info") {
        let _guard = ACCOUNT_SESSION_WRITE.lock().unwrap();
        LocalConfig::set_option(key, value);
    } else {
        LocalConfig::set_option(key, value);
    }
}

pub fn set_account_session(token: String, user_info: String) {
    let _guard = ACCOUNT_SESSION_WRITE.lock().unwrap();
    LocalConfig::set_option("access_token".to_owned(), token);
    LocalConfig::set_option("user_info".to_owned(), user_info);
}

fn clear_session_if_current(token: &str, audience: &str) -> bool {
    let _guard = ACCOUNT_SESSION_WRITE.lock().unwrap();
    if token.is_empty()
        || !crate::bk_profiles::is_current()
        || LocalConfig::get_option("access_token") != token
        || crate::ui_interface::get_api_server().trim_end_matches('/') != audience
    {
        return false;
    }
    // Derive the cache key from this session's own user record. Other accounts and
    // other immutable profile namespaces are never enumerated or removed.
    if let Ok(user) = serde_json::from_str::<Value>(&LocalConfig::get_option("user_info")) {
        if let Some(name) = user.get("name").and_then(Value::as_str) {
            let raw = format!("{audience}\0{name}");
            let suffix = crate::encode64(raw.as_bytes()).replace('+', "-").replace('/', "_");
            LocalConfig::set_option(format!("bk-remote-device-cache:{suffix}"), String::new());
        }
    }
    config::Ab::remove();
    config::Group::remove();
    LocalConfig::set_option("user_info".to_owned(), String::new());
    LocalConfig::set_option("access_token".to_owned(), String::new());
    true
}

pub fn initialize_brand() {
    BRAND_INITIALIZED.call_once(|| {
        let mut defaults = config::DEFAULT_SETTINGS.write().unwrap();
        for (key, value) in [
            ("approve-mode", "password"),
            ("verification-method", "use-permanent-password"),
            ("enable-keyboard", "Y"),
            ("enable-file-transfer", "Y"),
        ] {
            defaults
                .entry(key.to_owned())
                .or_insert_with(|| value.to_owned());
        }
    });
    crate::bk_profiles::initialize_desktop();
}

/// These are public deployment values, not credentials or a configuration-signing secret.
/// This is called only after the immutable process profile and storage namespace are selected.
pub fn apply_public_server_defaults(profile: crate::bk_profiles::Profile) {
    let mut defaults = config::DEFAULT_SETTINGS.write().unwrap();
    insert_public_server_defaults(&mut defaults, profile, [
        option_env!("BK_REMOTE_ID_SERVER"),
        option_env!("BK_REMOTE_SERVER_KEY"),
        option_env!("BK_REMOTE_API_SERVER"),
    ]);
}

fn insert_public_server_defaults(
    defaults: &mut std::collections::HashMap<String, String>,
    profile: crate::bk_profiles::Profile,
    values: [Option<&str>; 3],
) {
    if profile != crate::bk_profiles::Profile::Bk { return; }
    for (key, value) in ["custom-rendezvous-server", "key", "api-server"].into_iter().zip(values) {
        if let Some(value) = value.map(str::trim).filter(|value| !value.is_empty()) {
            defaults.entry(key.to_owned()).or_insert_with(|| value.to_owned());
        }
    }
    defaults.entry("relay-server".to_owned()).or_insert_with(String::new);
}

pub fn verify_custom_config(data: &[u8]) -> Result<Vec<u8>, &'static str> {
    verify_config_with_key(data, option_env!("BK_REMOTE_CONFIG_PUBLIC_KEY"))
}

fn verify_config_with_key(
    data: &[u8],
    additional_key: Option<&str>,
) -> Result<Vec<u8>, &'static str> {
    for key in [Some(OFFICIAL_CONFIG_KEY), additional_key]
        .into_iter()
        .flatten()
    {
        let Ok(bytes) = crate::decode64(key) else {
            continue;
        };
        let Some(public_key) = sign::PublicKey::from_slice(&bytes) else {
            continue;
        };
        if let Ok(verified) = sign::verify(data, &public_key) {
            return Ok(verified);
        }
    }
    Err("Invalid custom client signature")
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Request {
    Profiles,
    SwitchProfile {
        target: String,
        generation: u64,
        #[serde(default)]
        recover: bool,
    },
    AbortProfileSwitch,
    ProfileReady,
    ClearSession {
        token: String,
        audience: String,
    },
    Identity,
    SignEnrollment {
        deployment_token: String,
        user_id: u64,
        recover_device_id: String,
        challenge_id: String,
        signing_payload: String,
    },
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct EnrollmentPayload {
    purpose: String,
    audience: String,
    user_id: u64,
    session_hash: String,
    token_hash: String,
    id: String,
    uuid: String,
    pk: String,
    recover_device_id: String,
    challenge_id: String,
    nonce: String,
    expires_at: u64,
}

struct EnrollmentContext<'a> {
    audience: &'a str,
    user_id: u64,
    session: &'a str,
    session_hash_override: Option<&'a str>,
    deployment_token: &'a str,
    id: &'a str,
    uuid: &'a str,
    pk: &'a str,
    recover_device_id: &'a str,
    challenge_id: &'a str,
    now: u64,
}

fn hash_hex(value: &str) -> String {
    format!("{:x}", Sha256::digest(value.as_bytes()))
}

pub fn account_origin() -> Result<String, &'static str> {
    validate_account_origin(
        Config::get_option("api-server"),
        Config::get_option("custom-rendezvous-server"),
    )
}

pub fn validate_account_origin(api: String, rendezvous: String) -> Result<String, &'static str> {
    if api.trim().is_empty() {
        return Err("Configure the account server first");
    }
    let origin = crate::get_api_server(api, rendezvous);
    let origin = origin.trim_end_matches('/');
    let url = url::Url::parse(origin).map_err(|_| "Configure the account server first")?;
    let loopback = matches!(
        url.host_str(),
        Some("localhost" | "127.0.0.1" | "[::1]" | "::1")
    );
    if (url.scheme() != "https" && !(url.scheme() == "http" && loopback))
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || crate::is_public(origin)
    {
        return Err("The account server requires a private HTTPS endpoint");
    }
    Ok(origin.to_owned())
}

fn validate_enrollment(
    raw: &[u8],
    context: &EnrollmentContext<'_>,
) -> Result<EnrollmentPayload, &'static str> {
    if raw.len() > 8192
        || context.deployment_token.is_empty()
        || (context.session.is_empty() && context.session_hash_override.is_none())
    {
        return Err("Invalid enrollment challenge");
    }
    let payload: EnrollmentPayload =
        serde_json::from_slice(raw).map_err(|_| "Invalid enrollment challenge")?;
    if payload.purpose != ENROLLMENT_PURPOSE
        || payload.audience != context.audience
        || payload.user_id == 0
        || payload.user_id != context.user_id
        || payload.session_hash
            != context
                .session_hash_override
                .map(str::to_owned)
                .unwrap_or_else(|| hash_hex(context.session))
        || payload.token_hash != hash_hex(context.deployment_token)
        || payload.id != context.id
        || payload.uuid != context.uuid
        || payload.pk != context.pk
        || payload.recover_device_id != context.recover_device_id
        || payload.challenge_id != context.challenge_id
        || payload.challenge_id.len() != 64
        || !payload.challenge_id.bytes().all(|c| c.is_ascii_hexdigit())
        || payload.expires_at <= context.now
        || payload.expires_at.saturating_sub(context.now) > 185
        || crate::decode64(&payload.nonce).map_or(true, |bytes| bytes.len() != 32)
    {
        return Err("Enrollment challenge does not match this device or login");
    }
    Ok(payload)
}

// This reserved local bridge never persists the request or exposes the private key.
pub fn native_request(request: &str) -> String {
    #[cfg(windows)]
    if request.len() <= 16384
        && matches!(
            serde_json::from_str::<Request>(request),
            Ok(Request::Identity | Request::SignEnrollment { .. })
        )
    {
        let session = LocalConfig::get_option("access_token");
        let digest = if session.is_empty() {
            String::new()
        } else {
            hash_hex(&session)
        };
        let response = (|| -> hbb_common::ResultType<String> {
            let runtime = hbb_common::tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()?;
            runtime.block_on(crate::ipc::bk_enrollment_request(request, &digest))
        })();
        return response.unwrap_or_else(|_| {
            json!({"ok":false,
            "error":"The native service identity is unavailable; start the service and try again"})
            .to_string()
        });
    }
    native_request_local(request, None)
}

#[cfg(windows)]
pub fn native_request_for_host(request: &str, session_hash: &str) -> String {
    if request.len() > 16384
        || !matches!(
            serde_json::from_str::<Request>(request),
            Ok(Request::Identity | Request::SignEnrollment { .. })
        )
        || (!session_hash.is_empty()
            && (session_hash.len() != 64
                || !session_hash
                    .bytes()
                    .all(|x| x.is_ascii_digit() || (b'a'..=b'f').contains(&x))))
    {
        return json!({"ok":false,"error":"Invalid enrollment request"}).to_string();
    }
    if session_hash.is_empty()
        && matches!(
            serde_json::from_str::<Request>(request),
            Ok(Request::SignEnrollment { .. })
        )
    {
        return json!({"ok":false,"error":"Sign in again to manage team devices"}).to_string();
    }
    native_request_local(
        request,
        if session_hash.is_empty() {
            None
        } else {
            Some(session_hash)
        },
    )
}

fn native_request_local(request: &str, session_hash: Option<&str>) -> String {
    let result = (|| -> Result<Value, &'static str> {
        if request.len() > 16384 {
            return Err("Invalid enrollment request");
        }
        let request: Request =
            serde_json::from_str(request).map_err(|_| "Invalid enrollment request")?;
        match &request {
            Request::Profiles => return Ok(crate::bk_profiles::status()),
            Request::SwitchProfile {
                target,
                generation,
                recover,
            } => return crate::bk_profiles::request_switch(target, *generation, *recover),
            Request::AbortProfileSwitch => return crate::bk_profiles::abort_mobile_switch(),
            Request::ProfileReady => return crate::bk_profiles::confirm_mobile_startup(),
            Request::ClearSession { token, audience } => {
                return Ok(json!({"cleared": clear_session_if_current(token, audience)}));
            }
            _ => {}
        }
        if !crate::bk_profiles::is_current() {
            return Err("Restart is required to activate the server profile");
        }
        let audience = account_origin()?;
        let id = Config::get_id();
        if id.is_empty() {
            return Err("Wait for the device identity to be ready");
        }
        let public = if let Some(public) = Config::get_cached_pk() {
            public
        } else if let Some((mut secret, public)) = Config::get_existing_key_pair() {
            secret.fill(0);
            public
        } else {
            return Err("Wait for the device identity to be ready");
        };
        let pk = crate::encode64(&public);
        let uuid = crate::ui_interface::get_uuid();
        match request {
            Request::Profiles
            | Request::SwitchProfile { .. }
            | Request::AbortProfileSwitch
            | Request::ProfileReady
            | Request::ClearSession { .. } => Err("Invalid server profile request"),
            Request::Identity => Ok(json!({
                "id": id, "uuid": uuid, "pk": pk, "audience": audience
            })),
            Request::SignEnrollment {
                deployment_token,
                user_id,
                recover_device_id,
                challenge_id,
                signing_payload,
            } => {
                let raw =
                    crate::decode64(signing_payload).map_err(|_| "Invalid enrollment challenge")?;
                let session = LocalConfig::get_option("access_token");
                let context = EnrollmentContext {
                    audience: &audience,
                    user_id,
                    session: &session,
                    session_hash_override: session_hash,
                    deployment_token: &deployment_token,
                    id: &id,
                    uuid: &uuid,
                    pk: &pk,
                    recover_device_id: &recover_device_id,
                    challenge_id: &challenge_id,
                    now: (hbb_common::get_time() / 1000) as u64,
                };
                validate_enrollment(&raw, &context)?;
                let Some((mut secret, current_public)) = Config::get_existing_key_pair() else {
                    return Err("The local device identity is invalid");
                };
                let secret_key = sign::SecretKey::from_slice(&secret);
                secret.fill(0);
                let secret_key = secret_key.ok_or("The local device identity is invalid")?;
                if current_public != public {
                    return Err("The local device identity changed");
                }
                let signature = sign::sign_detached(&raw, &secret_key);
                Ok(json!({"signature": crate::encode64(signature.to_bytes())}))
            }
        }
    })();
    match result {
        Ok(value) => json!({"ok": true, "data": value}).to_string(),
        Err(message) => json!({"ok": false, "error": message}).to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn public_defaults_are_bk_only_and_preserve_existing_values() {
        use crate::bk_profiles::Profile;
        let values = [Some("id.example.test"), Some("public-key"), Some("https://api.example.test")];
        for profile in [Profile::Official, Profile::Manual] {
            let mut defaults = std::collections::HashMap::new();
            insert_public_server_defaults(&mut defaults, profile, values);
            assert!(defaults.is_empty());
        }
        let mut defaults = std::collections::HashMap::new();
        defaults.insert("custom-rendezvous-server".to_owned(), "existing.example.test".to_owned());
        insert_public_server_defaults(&mut defaults, Profile::Bk, values);
        assert_eq!(defaults["custom-rendezvous-server"], "existing.example.test");
        assert_eq!(defaults["key"], "public-key");
        assert_eq!(defaults["api-server"], "https://api.example.test");
        assert_eq!(defaults["relay-server"], "");
        let mut empty = std::collections::HashMap::new();
        insert_public_server_defaults(&mut empty, Profile::Bk, [None, Some(" "), None]);
        assert!(!empty.contains_key("custom-rendezvous-server"));
        assert!(!empty.contains_key("key"));
        assert!(!empty.contains_key("api-server"));
    }

    fn context() -> EnrollmentContext<'static> {
        EnrollmentContext {
            audience: "https://accounts.example.test",
            user_id: 7,
            session: "test-session",
            session_hash_override: None,
            deployment_token: "test-deployment-token",
            id: "123456789",
            uuid: "dGVzdC11dWlk",
            pk: "test-public-key",
            recover_device_id: "",
            challenge_id: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            now: 1_800_000_000,
        }
    }

    fn payload(context: &EnrollmentContext<'_>) -> Value {
        json!({
            "purpose": ENROLLMENT_PURPOSE,
            "audience": context.audience,
            "user_id": context.user_id,
            "session_hash": hash_hex(context.session),
            "token_hash": hash_hex(context.deployment_token),
            "id": context.id,
            "uuid": context.uuid,
            "pk": context.pk,
            "recover_device_id": context.recover_device_id,
            "challenge_id": context.challenge_id,
            "nonce": crate::encode64([9u8; 32]),
            "expires_at": context.now + 180,
        })
    }

    #[test]
    fn enrollment_challenge_binds_device_account_and_deployment() {
        let context = context();
        let value = payload(&context);
        assert!(validate_enrollment(value.to_string().as_bytes(), &context).is_ok());
        for field in [
            "purpose",
            "audience",
            "session_hash",
            "token_hash",
            "id",
            "uuid",
            "pk",
            "recover_device_id",
            "challenge_id",
            "nonce",
        ] {
            let mut changed = value.clone();
            changed[field] = json!("wrong");
            assert!(validate_enrollment(changed.to_string().as_bytes(), &context).is_err());
        }
        let mut changed = value.clone();
        changed["user_id"] = json!(8);
        assert!(validate_enrollment(changed.to_string().as_bytes(), &context).is_err());
        for expiry in [context.now, context.now - 1, context.now + 186] {
            let mut changed = value.clone();
            changed["expires_at"] = json!(expiry);
            assert!(validate_enrollment(changed.to_string().as_bytes(), &context).is_err());
        }
    }

    #[test]
    fn enrollment_challenge_rejects_duplicate_or_unknown_fields() {
        let context = context();
        let valid = payload(&context).to_string();
        let duplicate = valid.replacen('{', "{\"purpose\":\"other\",", 1);
        assert!(validate_enrollment(duplicate.as_bytes(), &context).is_err());
        let unknown = valid.replacen('{', "{\"extra\":true,", 1);
        assert!(validate_enrollment(unknown.as_bytes(), &context).is_err());
    }

    #[test]
    fn custom_config_requires_trusted_key_and_rejects_tampering() {
        crate::common::init_sodium();
        let (public, secret) = sign::gen_keypair();
        let signed = sign::sign(b"{\"app-name\":\"BK Remote\"}", &secret);
        let key = crate::encode64(public.0);
        assert!(verify_config_with_key(&signed, Some(&key)).is_ok());
        assert!(verify_config_with_key(&signed, None).is_err());
        let mut tampered = signed.clone();
        let last = tampered.len() - 1;
        tampered[last] ^= 1;
        assert!(verify_config_with_key(&tampered, Some(&key)).is_err());
        assert!(verify_config_with_key(&signed, Some("invalid")).is_err());
    }
}
