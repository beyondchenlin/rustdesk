//! Authenticated native registration observations, independent of account heartbeats.
//! This signs a bounded response over ordinary framed TCP; it does not claim transport encryption.
use hbb_common::{
    anyhow::{anyhow, bail},
    rendezvous_proto::{OnlineRequest, RendezvousMessage},
    sodiumoxide::{crypto::sign, randombytes},
    ResultType,
};
use serde_derive::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

pub(crate) const REQUEST_PREFIX: &str = "bk-presence-v1:";
const RESPONSE_MAGIC: &[u8; 5] = b"BKRP1";
const SIGNATURE_DOMAIN: &[u8] = b"BK Remote native registration v1\n";
const MAX_PEERS: usize = 200;
const MAX_ID_BYTES: usize = 253;
const MAX_TOTAL_ID_BYTES: usize = 16 * 1024;
const MAX_REQUEST_BYTES: usize = 24 * 1024;
static QUERY_ACTIVE: AtomicBool = AtomicBool::new(false);

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct QueryRequest {
    context: String,
    ids: Vec<String>,
}

struct Context {
    fingerprint: String,
    origin: String,
    server: String,
    key: sign::PublicKey,
}

impl Context {
    fn from_snapshot(snapshot: &crate::bk_service_settings::Snapshot) -> ResultType<Self> {
        let origin = snapshot.account_origin().map_err(|e| anyhow!(e))?;
        let raw_server = snapshot.option("custom-rendezvous-server").trim();
        if raw_server.is_empty() || raw_server.len() > 1024
            || raw_server.bytes().any(|b| b.is_ascii_whitespace() || b.is_ascii_control())
            || raw_server.contains("://")
        {
            bail!("A native registration server must be explicitly configured");
        }
        let server = if raw_server.starts_with('[') && raw_server.ends_with(']') {
            format!("{raw_server}:21116")
        } else {
            hbb_common::socket_client::check_port(raw_server, 21116)
        };
        let address = url::Url::parse(&format!("tcp://{server}"))?;
        if address.host_str().is_none() || address.port().is_none()
            || address.port() == Some(0) || !address.username().is_empty()
            || address.password().is_some() || address.query().is_some()
            || address.fragment().is_some() || !matches!(address.path(), "" | "/")
        {
            bail!("Invalid native registration server");
        }
        let decoded = crate::decode64(snapshot.option("key").trim())?;
        let key = sign::PublicKey::from_slice(&decoded)
            .ok_or_else(|| anyhow!("A trusted native registration public key is required"))?;
        let fingerprint = fingerprint(&snapshot.profile, &server, &origin, &key);
        Ok(Self { fingerprint, origin, server, key })
    }
}

fn fingerprint(profile: &str, server: &str, origin: &str, key: &sign::PublicKey) -> String {
    let mut hash = Sha256::new();
    hash.update(b"BK Remote native registration context v1\0");
    for part in [profile.as_bytes(), server.as_bytes(), origin.as_bytes(), &key.0] {
        hash.update((part.len() as u32).to_be_bytes());
        hash.update(part);
    }
    format!("{:x}", hash.finalize())
}

/// No IPC or network. Desktop cached settings are only a UI fingerprint, never authority.
pub fn context_json() -> String {
    match crate::bk_service_settings::cached()
        .map_err(|e| anyhow!(e))
        .and_then(|snapshot| Context::from_snapshot(&snapshot))
    {
        Ok(context) => json!({"context":context.fingerprint,"origin":context.origin,"ready":true}).to_string(),
        Err(_) => json!({"context":"","origin":"","ready":false}).to_string(),
    }
}

/// Bounded asynchronous-bridge entry. The caller supplies the explicit runtime boundary.
/// The permit belongs to the actual worker, including runtime teardown after a timeout.
/// System DNS in the fixed proxy library cannot block the bridge or create extra workers.
pub fn at_async_bridge<F>(raw: &str, execute: F) -> String
where
    F: FnOnce(String) -> String + Send + 'static,
{
    bridge_with_budget(raw, execute, Duration::from_secs(12))
}

fn bridge_with_budget<F>(raw: &str, execute: F, budget: Duration) -> String
where
    F: FnOnce(String) -> String + Send + 'static,
{
    let fallback = unavailable_json(raw);
    if raw.len() > MAX_REQUEST_BYTES
        || QUERY_ACTIVE.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire).is_err()
    {
        return fallback;
    }
    let permit = ActiveQuery;
    let owned = raw.to_owned();
    let (send, receive) = std::sync::mpsc::sync_channel(1);
    if std::thread::Builder::new().name("bk-native-presence".to_owned()).spawn(move || {
        let _permit = permit;
        let response = execute(owned);
        let _ = send.send(response);
    }).is_err() {
        return fallback;
    }
    receive.recv_timeout(budget).unwrap_or(fallback)
}

fn unavailable_json(raw: &str) -> String {
    let request = if raw.len() <= MAX_REQUEST_BYTES {
        serde_json::from_str::<QueryRequest>(raw).ok()
    } else {
        None
    };
    let mut states = serde_json::Map::new();
    let mut context = String::new();
    if let Some(request) = request {
        context = request.context;
        if validate_peers(&request.ids).is_ok() {
            for id in request.ids {
                states.insert(id, json!("unknown"));
            }
        }
    }
    json!({"context":context,"queried_at_ms":now_ms(),"confirmed_at_ms":null,"states":states}).to_string()
}

/// Awaited by at_async_bridge's caller-supplied executor; no hidden or nested runtime.
pub async fn query_json(raw: &str) -> String {
    let attempted = now_ms();
    let request = if raw.len() <= MAX_REQUEST_BYTES {
        serde_json::from_str::<QueryRequest>(raw).ok()
    } else {
        None
    };
    let Some(request) = request else {
        return json!({"context":"","queried_at_ms":attempted,"confirmed_at_ms":null,"states":{}}).to_string();
    };
    let mut states: serde_json::Map<String, serde_json::Value> = serde_json::Map::new();
    if validate_peers(&request.ids).is_err()
        || request.context.len() != 64
        || !request.context.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return json!({"context":request.context,"queried_at_ms":attempted,"confirmed_at_ms":null,"states":states}).to_string();
    }
    for id in &request.ids {
        states.insert(id.clone(), json!("unknown"));
    }
    let mut confirmed = None;
    if let Ok(Ok((values, observed))) = hbb_common::tokio::time::timeout(
        Duration::from_secs(12), query_bound(&request),
    ).await {
        confirmed = Some(observed);
        for (id, online) in request.ids.iter().zip(values) {
            states.insert(id.clone(), json!(if online { "online" } else { "offline" }));
        }
    }
    json!({
        "context":request.context,
        "queried_at_ms":attempted,
        "confirmed_at_ms":confirmed,
        "states":states,
    }).to_string()
}

struct ActiveQuery;
impl Drop for ActiveQuery {
    fn drop(&mut self) {
        QUERY_ACTIVE.store(false, Ordering::Release);
    }
}

async fn query_bound(request: &QueryRequest) -> ResultType<(Vec<bool>, u64)> {
    let before = crate::bk_service_settings::read().await.map_err(|e| anyhow!(e))?;
    let context = Context::from_snapshot(&before)?;
    ensure_current_context(&request.context, &context)?;
    if hbb_common::sodiumoxide::init().is_err() {
        bail!("Native registration cryptography is unavailable");
    }
    let mut nonce = [0u8; 32];
    randombytes::randombytes_into(&mut nonce);
    let message = make_request(&request.ids, &nonce)?;
    let response = crate::client::peer_online::query_signed_registration(
        &context.server, before.socks.as_ref(), &message,
    ).await?;
    let values = verify_response(&request.ids, &nonce, &response, &context.key)?;
    // This is local receipt/verification time, never a server-provided last-online time.
    let observed = now_ms();
    let after = crate::bk_service_settings::read().await.map_err(|e| anyhow!(e))?;
    if !before.same_route(&after) {
        bail!("Native registration settings changed");
    }
    let after_context = Context::from_snapshot(&after)?;
    ensure_current_context(&request.context, &after_context)?;
    Ok((values, observed))
}

fn ensure_current_context(expected: &str, actual: &Context) -> ResultType<()> {
    let cached = crate::bk_service_settings::cached().map_err(|e| anyhow!(e))?;
    let cached = Context::from_snapshot(&cached)?;
    if !crate::bk_profiles::is_current()
        || actual.fingerprint != expected
        || cached.fingerprint != expected
    {
        bail!("Native registration profile or server changed");
    }
    Ok(())
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64).unwrap_or_default()
}

fn make_request(ids: &[String], nonce: &[u8; 32]) -> ResultType<RendezvousMessage> {
    validate_peers(ids)?;
    let challenge = nonce.iter().map(|value| format!("{value:02x}")).collect::<String>();
    let mut request = RendezvousMessage::new();
    request.set_online_request(OnlineRequest {
        id: format!("{REQUEST_PREFIX}{challenge}"),
        peers: ids.to_vec(),
        ..Default::default()
    });
    Ok(request)
}

fn validate_peers(ids: &[String]) -> ResultType<()> {
    if ids.is_empty() || ids.len() > MAX_PEERS {
        bail!("Invalid native registration query size");
    }
    let mut total = 0usize;
    let mut seen = HashSet::with_capacity(ids.len());
    for id in ids {
        if id.is_empty() || id.len() > MAX_ID_BYTES
            || !id.as_bytes()[0].is_ascii_alphanumeric()
            || !id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b':' | b'-'))
            || !seen.insert(id.as_str())
        {
            bail!("Invalid or duplicate native device identifier");
        }
        total = total.saturating_add(id.len());
        if total > MAX_TOTAL_ID_BYTES {
            bail!("Native registration identifiers exceed the byte limit");
        }
    }
    Ok(())
}

fn transcript(ids: &[String], nonce: &[u8; 32], bitmap: &[u8]) -> Vec<u8> {
    let mut payload = Vec::with_capacity(SIGNATURE_DOMAIN.len() + 34 + MAX_TOTAL_ID_BYTES + 400 + bitmap.len());
    payload.extend_from_slice(SIGNATURE_DOMAIN);
    payload.extend_from_slice(nonce);
    payload.extend_from_slice(&(ids.len() as u16).to_be_bytes());
    for id in ids {
        payload.extend_from_slice(&(id.len() as u16).to_be_bytes());
        payload.extend_from_slice(id.as_bytes());
    }
    payload.extend_from_slice(bitmap);
    payload
}

fn verify_response(ids: &[String], nonce: &[u8; 32], response: &[u8], key: &sign::PublicKey) -> ResultType<Vec<bool>> {
    validate_peers(ids)?;
    let bitmap_len = ids.len().div_ceil(8);
    if response.len() != 5 + 32 + 2 + bitmap_len + 64
        || &response[..5] != RESPONSE_MAGIC || &response[5..37] != nonce
        || &response[37..39] != (ids.len() as u16).to_be_bytes().as_slice()
    {
        bail!("Invalid native registration response envelope");
    }
    let bitmap = &response[39..39 + bitmap_len];
    let used = ids.len() % 8;
    if used != 0 && bitmap[bitmap_len - 1] & ((1u8 << (8 - used)) - 1) != 0 {
        bail!("Invalid native registration bitmap padding");
    }
    let signature = sign::Signature::from_bytes(&response[39 + bitmap_len..])
        .map_err(|_| anyhow!("Invalid native registration signature encoding"))?;
    if !sign::verify_detached(&signature, &transcript(ids, nonce, bitmap), key) {
        bail!("Native registration response signature is invalid");
    }
    Ok((0..ids.len()).map(|i| bitmap[i / 8] & (1 << (7 - i % 8)) != 0).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(ids: &[String], nonce: &[u8; 32], bitmap: &[u8]) -> (sign::PublicKey, Vec<u8>) {
        hbb_common::sodiumoxide::init().unwrap();
        let (key, secret) = sign::keypair_from_seed(&sign::Seed([7; 32]));
        let mut response = Vec::from(RESPONSE_MAGIC.as_slice());
        response.extend_from_slice(nonce);
        response.extend_from_slice(&(ids.len() as u16).to_be_bytes());
        response.extend_from_slice(bitmap);
        response.extend_from_slice(&sign::sign_detached(&transcript(ids, nonce, bitmap), &secret).to_bytes());
        (key, response)
    }

    #[test]
    fn authenticates_original_native_bit_order_and_exact_envelope() {
        let ids = vec!["101".into(), "202".into(), "303".into()];
        let nonce = std::array::from_fn(|i| i as u8);
        let (key, response) = fixture(&ids, &nonce, &[0xa0]);
        // Independently produced by OpenSSL in the real-server interoperability run.
        // Seed [7; 32] is public synthetic fixture material, never a deployment key.
        assert_eq!(key.0, [0xea, 0x4a, 0x6c, 0x63, 0xe2, 0x9c, 0x52, 0x0a, 0xbe, 0xf5, 0x50, 0x7b, 0x13, 0x2e, 0xc5, 0xf9, 0x95, 0x47, 0x76, 0xae, 0xbe, 0xbe, 0x7b, 0x92, 0x42, 0x1e, 0xea, 0x69, 0x14, 0x46, 0xd2, 0x2c]);
        assert_eq!(response, vec![0x42, 0x4b, 0x52, 0x50, 0x31, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x00, 0x03, 0xa0, 0x7b, 0x50, 0xdf, 0xaf, 0x2b, 0xcd, 0x00, 0x4a, 0x0a, 0xc9, 0x3a, 0x3a, 0x2e, 0x77, 0x0b, 0x50, 0xd3, 0x58, 0xe0, 0x04, 0xa0, 0x13, 0x65, 0xe1, 0x17, 0xbe, 0x16, 0x3f, 0x05, 0x78, 0xc3, 0x8f, 0xb5, 0x11, 0xbf, 0x9d, 0x9c, 0x48, 0x82, 0xfc, 0x52, 0x0a, 0x4e, 0x89, 0x8c, 0x24, 0xed, 0x46, 0x87, 0xaf, 0xea, 0x57, 0xa9, 0x53, 0x4a, 0xf5, 0xfa, 0x52, 0x8b, 0xee, 0x04, 0x02, 0xa7, 0x02]);
        assert_eq!(response.len(), 104);
        assert_eq!(&response[37..40], &[0, 3, 0xa0]);
        assert_eq!(verify_response(&ids, &nonce, &response, &key).unwrap(), vec![true, false, true]);
        for length in 0..response.len() {
            assert!(verify_response(&ids, &nonce, &response[..length], &key).is_err());
        }
        let mut extended = response.clone();
        extended.push(0);
        assert!(verify_response(&ids, &nonce, &extended, &key).is_err());
    }

    #[test]
    fn rejects_wrong_key_tamper_replay_order_and_padding() {
        let ids = vec!["101".into(), "202".into(), "303".into()];
        let nonce = [1; 32];
        let (key, response) = fixture(&ids, &nonce, &[0xa0]);
        let wrong = sign::keypair_from_seed(&sign::Seed([8; 32])).0;
        assert!(verify_response(&ids, &nonce, &response, &wrong).is_err());
        assert!(verify_response(&ids, &[2; 32], &response, &key).is_err());
        let mut reordered = ids.clone();
        reordered.swap(0, 1);
        assert!(verify_response(&reordered, &nonce, &response, &key).is_err());
        for index in [0, 5, 37, 39, 40, 103] {
            let mut changed = response.clone();
            changed[index] ^= 1;
            assert!(verify_response(&ids, &nonce, &changed, &key).is_err());
        }
        let (key, invalid_padding) = fixture(&ids, &nonce, &[0xa1]);
        assert!(verify_response(&ids, &nonce, &invalid_padding, &key).is_err());
        // Legacy auxiliary-port bitmap is never accepted as an authenticated observation.
        assert!(verify_response(&ids, &nonce, &[0xa0], &key).is_err());
    }

    #[test]
    fn rejects_duplicates_invalid_ids_and_request_limits() {
        let invalid = [
            vec![], vec!["101".into(), "101".into()], vec!["x\n".into()],
            vec!["../101".into()], vec!["x".repeat(254)],
            (0..201).map(|n| n.to_string()).collect(),
            (0..70).map(|n| format!("{n:03}{}", "x".repeat(250))).collect(),
        ];
        for ids in invalid {
            assert!(make_request(&ids, &[0; 32]).is_err());
        }
        let ids = (0..200).map(|n| n.to_string()).collect::<Vec<_>>();
        assert!(make_request(&ids, &[0; 32]).is_ok());
    }

    #[test]
    fn bridge_deadline_keeps_single_permit_until_blocked_worker_really_exits() {
        let raw = json!({"context":"a".repeat(64),"ids":["101"]}).to_string();
        let (release, blocked) = std::sync::mpsc::sync_channel(1);
        let result = bridge_with_budget(&raw, move |_| {
            blocked.recv().unwrap();
            "late-worker-result".to_owned()
        }, Duration::from_millis(20));
        let value: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(value["states"]["101"], "unknown");
        assert!(value["confirmed_at_ms"].is_null());
        assert!(QUERY_ACTIVE.load(Ordering::Acquire));
        let refused = bridge_with_budget(&raw, |_| panic!("A timed-out worker must retain its permit"), Duration::from_millis(20));
        assert_eq!(serde_json::from_str::<serde_json::Value>(&refused).unwrap()["states"]["101"], "unknown");
        release.send(()).unwrap();
        for _ in 0..100 {
            if !QUERY_ACTIVE.load(Ordering::Acquire) { return; }
            std::thread::sleep(Duration::from_millis(5));
        }
        panic!("Completed native query did not release its permit");
    }

    #[test]
    fn context_binds_profile_generation_server_account_and_trusted_key() {
        let key = sign::PublicKey([1; 32]);
        let value = fingerprint("bk:7", "id.example:21116", "https://account.example", &key);
        for other in [
            fingerprint("bk:8", "id.example:21116", "https://account.example", &key),
            fingerprint("manual:7", "id.example:21116", "https://account.example", &key),
            fingerprint("bk:7", "other.example:21116", "https://account.example", &key),
            fingerprint("bk:7", "id.example:21116", "https://other.example", &key),
            fingerprint("bk:7", "id.example:21116", "https://account.example", &sign::PublicKey([2; 32])),
        ] {
            assert_ne!(value, other);
        }
    }
}
