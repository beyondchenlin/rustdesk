use super::*;
use hbb_common::{base64::Engine as _, sodiumoxide::crypto::sign};
use serde_json::{json, Value};

const KEY_ID: &str = "bk-test-key";
const PREFIX: &str = "https://github.com/team/bk-remote/releases/download/9.2.3/";

fn metadata() -> Value {
    json!({
        "schema_version": 1, "app": "bk-remote", "package_id": "bk-remote",
        "version": "9.2.3", "release_id": "9.2.3", "published_at": "2026-11-27T00:00:00Z",
        "signature_key_id": KEY_ID,
        "artifacts": [{
            "platform": "windows", "arch": "x86_64", "format": "exe",
            "url": format!("{PREFIX}BK-Remote.exe"), "file_name": "BK-Remote.exe",
            "size": 1024, "sha256": "a".repeat(64)
        }]
    })
}

fn signed(value: &Value, context: &[u8]) -> (Vec<u8>, Vec<u8>, [u8; 32]) {
    sodiumoxide::init().expect("test crypto initialization");
    let (public, secret) = sign::gen_keypair();
    let metadata = serde_json::to_vec(value).expect("test metadata");
    let mut message = context.to_vec();
    message.extend_from_slice(&metadata);
    let signature = sign::sign_detached(&message, &secret);
    let envelope = json!({
        "schema_version": 1, "algorithm": "ed25519", "key_id": KEY_ID,
        "signature": STANDARD.encode(signature.to_bytes())
    });
    (metadata, serde_json::to_vec(&envelope).expect("signature envelope"), public.0)
}

fn verify(metadata: &[u8], signature: &[u8], key: [u8; 32]) -> ResultType<VerifiedUpdateArtifact> {
    verify_bk_update_metadata(metadata, signature, UpdateMetadataRequirements {
        expected_version: "9.2.3", expected_release_id: "9.2.3",
        expected_artifact_url_prefix: PREFIX,
        artifact: UpdateArtifactQuery { platform: "windows", arch: "x86_64", format: "exe" },
    }, KEY_ID, key)
}

#[test]
fn bk_update_requires_its_own_key_signature_context_and_exact_bytes() {
    let (bytes, signature, key) = signed(&metadata(), crate::bk_updates::SIGNATURE_CONTEXT);
    let valid = verify(&bytes, &signature, key).expect("trusted BK release");
    assert_eq!(valid.version, "9.2.3");
    assert_eq!(valid.sha256, "a".repeat(64));
    assert!(verify(&bytes, &signature, [0; 32]).is_err());
    let mut changed = bytes.clone();
    changed.push(b' ');
    assert!(verify(&changed, &signature, key).is_err());
    let (upstream_context, signature, key) = signed(&metadata(), UPDATE_METADATA_SIGNATURE_CONTEXT);
    assert!(verify(&upstream_context, &signature, key).is_err());
}

#[test]
fn bk_update_rejects_other_products_versions_repositories_and_duplicate_artifacts() {
    let valid = metadata();
    let mut cases = Vec::new();
    for (key, value) in [
        ("app", json!("rustdesk")), ("package_id", json!("rustdesk")),
        ("version", json!("9.2.2")), ("release_id", json!("9.2.2")),
        ("signature_key_id", json!("other-key")),
    ] {
        let mut item = valid.clone(); item[key] = value; cases.push(item);
    }
    let mut foreign = valid.clone();
    foreign["artifacts"][0]["url"] = json!(
        "https://github.com/rustdesk/rustdesk/releases/download/9.2.3/BK-Remote.exe");
    cases.push(foreign);
    let mut wrong_hash = valid.clone();
    wrong_hash["artifacts"][0]["sha256"] = json!("invalid"); cases.push(wrong_hash);
    let mut duplicate = valid.clone();
    duplicate["artifacts"].as_array_mut().expect("artifacts").push(valid["artifacts"][0].clone());
    cases.push(duplicate);
    for item in cases {
        let (bytes, signature, key) = signed(&item, crate::bk_updates::SIGNATURE_CONTEXT);
        assert!(verify(&bytes, &signature, key).is_err(), "{item}");
    }
}
