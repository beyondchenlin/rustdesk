//! Strict, current-profile service settings for credential-bearing network calls.
use hbb_common::config::{Config, Socks5Server};
use std::collections::HashMap;

const CHANGED: &str = "The account or server changed";
const UNAVAILABLE: &str = "The current service settings are unavailable";

#[derive(Clone, PartialEq)]
pub struct Snapshot {
    pub profile: String,
    pub options: HashMap<String, String>,
    pub socks: Option<Socks5Server>,
}

impl Snapshot {
    pub fn option(&self, name: &str) -> &str {
        self.options.get(name).map(String::as_str).unwrap_or("")
    }

    pub fn same_route(&self, other: &Self) -> bool {
        self.profile == other.profile
            && self.socks == other.socks
            && [
                "api-server",
                "custom-rendezvous-server",
                "key",
                "allow-websocket",
            ]
            .iter()
            .all(|key| self.option(key) == other.option(key))
    }

    pub fn account_origin(&self) -> Result<String, &'static str> {
        crate::bk_remote::validate_account_origin(
            self.option("api-server").to_owned(),
            self.option("custom-rendezvous-server").to_owned(),
        )
    }
}

/// UI fingerprint only. Desktop caches are not proof of current service settings.
pub fn cached() -> Result<Snapshot, &'static str> {
    if !crate::bk_profiles::is_current() {
        return Err(CHANGED);
    }
    Ok(Snapshot {
        profile: crate::bk_profiles::probe_identity(),
        options: [
            "api-server",
            "custom-rendezvous-server",
            "key",
            "allow-websocket",
        ]
        .iter()
        .map(|name| ((*name).to_owned(), crate::ui_interface::get_option(name)))
        .collect(),
        socks: Config::get_socks(),
    })
}

/// No nested runtime and no local fallback. The caller owns the async boundary.
pub async fn read() -> Result<Snapshot, &'static str> {
    if !crate::bk_profiles::is_current() {
        return Err(CHANGED);
    }
    let profile = crate::bk_profiles::probe_identity();
    #[cfg(any(target_os = "android", target_os = "ios"))]
    let snapshot = Snapshot {
        profile: profile.clone(),
        options: Config::get_options(),
        socks: Config::get_socks(),
    };
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    let snapshot = hbb_common::tokio::time::timeout(std::time::Duration::from_secs(3), async {
        use crate::ipc::{connect, Data};
        let mut stream = connect(750, "").await.map_err(|_| UNAVAILABLE)?;
        stream
            .send(&Data::Config(("bk-profile".into(), None)))
            .await
            .map_err(|_| UNAVAILABLE)?;
        match stream.next_timeout(750).await.map_err(|_| UNAVAILABLE)? {
            Some(Data::Config((name, Some(value)))) if name == "bk-profile" && value == profile => {
            }
            _ => return Err(CHANGED),
        }
        stream
            .send(&Data::Options(None))
            .await
            .map_err(|_| UNAVAILABLE)?;
        let options = match stream.next_timeout(750).await.map_err(|_| UNAVAILABLE)? {
            Some(Data::Options(Some(value))) => value,
            _ => return Err(UNAVAILABLE),
        };
        stream
            .send(&Data::Socks(None))
            .await
            .map_err(|_| UNAVAILABLE)?;
        let socks = match stream.next_timeout(750).await.map_err(|_| UNAVAILABLE)? {
            Some(Data::Socks(value)) => value,
            _ => return Err(UNAVAILABLE),
        };
        stream
            .send(&Data::Config(("bk-profile".into(), None)))
            .await
            .map_err(|_| UNAVAILABLE)?;
        match stream.next_timeout(750).await.map_err(|_| UNAVAILABLE)? {
            Some(Data::Config((name, Some(value)))) if name == "bk-profile" && value == profile => {
            }
            _ => return Err(CHANGED),
        }
        Ok(Snapshot {
            profile: profile.clone(),
            options,
            socks,
        })
    })
    .await
    .map_err(|_| UNAVAILABLE)??;
    if !crate::bk_profiles::is_current() || crate::bk_profiles::probe_identity() != profile {
        return Err(CHANGED);
    }
    Ok(snapshot)
}
