//! Software update trust is independent of the selected remote-control server profile.
use hbb_common::{
    anyhow::anyhow,
    bail,
    base64::{engine::general_purpose::STANDARD, Engine as _},
    ResultType,
};
use serde_derive::Deserialize;
use std::time::Duration;

pub(crate) const SIGNATURE_CONTEXT: &[u8] = b"BK Remote update metadata v1\n";
pub(crate) const PACKAGE_ID: &str = "bk-remote";
const LATEST_MAX_BYTES: usize = 16 * 1024;

pub(crate) struct Channel {
    pub check_url: String,
    pub repository: String,
    pub key_id: String,
    pub public_key: [u8; 32],
}

impl Channel {
    fn new(check_url: &str, repository: &str, key_id: &str, key: &str) -> ResultType<Self> {
        if check_url.is_empty() || repository.is_empty() || key_id.is_empty() || key.is_empty() {
            bail!("The software update channel is not configured");
        }
        let parsed = url::Url::parse(check_url)?;
        if parsed.scheme() != "https" || parsed.host_str().is_none()
            || !parsed.username().is_empty() || parsed.password().is_some()
            || parsed.query().is_some() || parsed.fragment().is_some()
        {
            bail!("The software update channel requires a trusted HTTPS address");
        }
        let segments: Vec<_> = repository.split('/').collect();
        if segments.len() != 2 || repository.eq_ignore_ascii_case("rustdesk/rustdesk")
            || segments.iter().any(|part| part.is_empty() || matches!(*part, "." | "..")
                || !part.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.')))
            || key_id.len() > 128
            || !key_id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
        {
            bail!("The software update trust configuration is invalid");
        }
        let decoded = STANDARD.decode(key)?;
        if decoded.len() != 32 || STANDARD.encode(&decoded) != key {
            bail!("The software update public key is invalid");
        }
        let mut public_key = [0u8; 32];
        public_key.copy_from_slice(&decoded);
        Ok(Self {
            check_url: parsed.to_string(), repository: repository.to_owned(),
            key_id: key_id.to_owned(), public_key,
        })
    }

    pub fn release_id(&self, raw: &str) -> ResultType<String> {
        let prefix = format!("https://github.com/{}/releases/tag/", self.repository);
        let release = raw.strip_prefix(&prefix)
            .ok_or_else(|| anyhow!("The update release is outside this product's repository"))?;
        let release = release.strip_suffix('/').unwrap_or(release);
        // This also rejects traversal, escaped path segments, credentials, ports,
        // queries, fragments, prerelease identifiers and invalid release versions.
        crate::common::display_version_from_release_id(release)?;
        if raw != format!("{prefix}{release}") && raw != format!("{prefix}{release}/") {
            bail!("The update release URL is invalid");
        }
        Ok(release.to_owned())
    }

    pub fn download_prefix(&self, release: &str) -> ResultType<String> {
        crate::common::display_version_from_release_id(release)?;
        Ok(format!("https://github.com/{}/releases/download/{release}/", self.repository))
    }
}

pub(crate) fn channel() -> ResultType<Channel> {
    Channel::new(
        option_env!("BK_REMOTE_UPDATE_CHECK_URL").unwrap_or(""),
        option_env!("BK_REMOTE_UPDATE_REPOSITORY").unwrap_or("beyondchenlin/rustdesk"),
        option_env!("BK_REMOTE_UPDATE_KEY_ID").unwrap_or("bk-remote-ed25519-main"),
        option_env!("BK_REMOTE_UPDATE_PUBLIC_KEY").unwrap_or(""),
    )
}

pub(crate) fn status() -> String {
    serde_json::json!({"configured": channel().is_ok()}).to_string()
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct LatestRelease {
    url: String,
}

pub(crate) async fn check() -> ResultType<String> {
    let channel = channel()?;
    let client = hbb_common::tokio::time::timeout(
        Duration::from_secs(30),
        crate::hbbs_http::create_http_client_async_with_url_strict(&channel.check_url),
    ).await??;
    let mut response = client.get(&channel.check_url)
        .timeout(Duration::from_secs(30)).send().await?;
    if !response.status().is_success() || response.url().as_str() != channel.check_url {
        bail!("The software update channel returned an invalid response");
    }
    if response.content_length().is_some_and(|n| n > LATEST_MAX_BYTES as u64) {
        bail!("The software update response is too large");
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        if bytes.len().saturating_add(chunk.len()) > LATEST_MAX_BYTES {
            bail!("The software update response is too large");
        }
        bytes.extend_from_slice(&chunk);
    }
    let latest: LatestRelease = serde_json::from_slice(&bytes)?;
    let release = channel.release_id(&latest.url)?;
    let version = crate::common::display_version_from_release_id(&release)?;
    if hbb_common::get_version_number(&version) > hbb_common::get_version_number(crate::VERSION) {
        Ok(latest.url)
    } else {
        Ok(String::new())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hbb_common::base64::Engine as _;

    fn fixture() -> Channel {
        Channel::new("https://updates.example.test/latest.json", "team/bk-remote",
            "test-key", &STANDARD.encode([7u8; 32])).expect("valid fixture")
    }

    #[test]
    fn channel_rejects_missing_untrusted_or_malformed_configuration() {
        let key = STANDARD.encode([7u8; 32]);
        for (url, repo, id, public) in [
            ("", "team/bk", "test", key.as_str()),
            ("http://updates.example.test/latest.json", "team/bk", "test", key.as_str()),
            ("https://user@updates.example.test/latest.json", "team/bk", "test", key.as_str()),
            ("https://updates.example.test/latest.json", "rustdesk/rustdesk", "test", key.as_str()),
            ("https://updates.example.test/latest.json", "team/../bk", "test", key.as_str()),
            ("https://updates.example.test/latest.json", "team/bk", "test", "bad-key"),
        ] {
            assert!(Channel::new(url, repo, id, public).is_err());
        }
    }

    #[test]
    fn channel_is_bound_to_its_product_repository() {
        let channel = fixture();
        assert_eq!(channel.release_id("https://github.com/team/bk-remote/releases/tag/v9.2.3")
            .expect("own release"), "v9.2.3");
        for url in [
            "https://github.com/rustdesk/rustdesk/releases/tag/9.2.3",
            "https://github.com/team/bk-remote/releases/tag/9.2.3?download=1",
            "https://github.com/team/bk-remote/releases/tag/9.2.3#other",
            "https://github.com/team/bk-remote/releases/tag/../9.2.3",
            "https://github.com/team/bk-remote/releases/tag/%39.2.3",
            "https://github.com/team/bk-remote/releases/tag/9.2.3//",
            "https://github.com:443/team/bk-remote/releases/tag/9.2.3",
        ] {
            assert!(channel.release_id(url).is_err(), "{url}");
        }
    }
}
