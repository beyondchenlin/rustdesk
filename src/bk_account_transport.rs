//! Account traffic uses the selected native proxy and strict certificate validation.
#[path = "bk_account_transport_core.rs"]
mod core;
#[path = "bk_account_route.rs"]
mod route;

use self::core::{AccountRequest, AccountResponse};
use hbb_common::{
    config::{LocalConfig, Socks5Server},
    tls::{get_cached_tls_accept_invalid_cert, get_cached_tls_type, TlsType},
};
use serde_json::json;
use std::sync::atomic::{AtomicUsize, Ordering};

static IN_FLIGHT: AtomicUsize = AtomicUsize::new(0);

struct Permit;
impl Drop for Permit {
    fn drop(&mut self) {
        IN_FLIGHT.fetch_sub(1, Ordering::AcqRel);
    }
}

fn session_is_current(request: &AccountRequest) -> bool {
    crate::bk_profiles::is_current()
        && LocalConfig::get_option("access_token") == request.token
        && crate::bk_service_settings::cached()
            .and_then(|snapshot| snapshot.account_origin())
            .as_deref()
            == Ok(request.audience.as_str())
}

fn native_client(
    audience: &str,
    conf: &Option<Socks5Server>,
) -> Result<reqwest::blocking::Client, &'static str> {
    let tls_url = crate::hbbs_http::get_url_for_tls(audience, &conf);
    let tls = if get_cached_tls_accept_invalid_cert(tls_url) == Some(false) {
        get_cached_tls_type(tls_url).unwrap_or(TlsType::Rustls)
    } else {
        TlsType::Rustls
    };
    let mut builder = reqwest::blocking::Client::builder();
    if matches!(tls, TlsType::NativeTls) {
        builder = builder.use_native_tls();
    } else {
        #[cfg(any(target_os = "android", target_os = "ios"))]
        {
            let verifier =
                hbb_common::verifier::client_config(false).map_err(|_| core::REQUEST_FAILED)?;
            builder = builder.use_preconfigured_tls(verifier);
        }
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        {
            builder = builder.use_rustls_tls();
        }
    }
    let proxy = conf
        .as_ref()
        .map(|conf| core::configured_proxy(&conf.proxy, &conf.username, &conf.password))
        .transpose()?;
    // Invalid proxy, TLS or client setup is an error. Never fall back to a direct client.
    core::finish_client(builder, proxy)
}

fn perform(request: AccountRequest) -> Result<AccountResponse, &'static str> {
    if !session_is_current(&request) {
        return Err(core::SESSION_CHANGED);
    }
    // This function is on our own OS thread, never inside an existing runtime.
    let runtime = hbb_common::tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|_| core::REQUEST_FAILED)?;
    let snapshot = runtime.block_on(crate::bk_service_settings::read())?;
    if snapshot.account_origin().as_deref() != Ok(request.audience.as_str()) {
        return Err(core::SESSION_CHANGED);
    }
    route::validate(&request.audience, snapshot.socks.is_some())?;
    let client = native_client(&request.audience, &snapshot.socks)?;
    let response = core::execute(&request, client, || session_is_current(&request))?;
    let current = runtime.block_on(crate::bk_service_settings::read())?;
    if !snapshot.same_route(&current) || !session_is_current(&request) {
        return Err(core::SESSION_CHANGED);
    }
    Ok(response)
}

/// Called only by main_get_common's asynchronous Flutter bridge. The dedicated OS
/// thread also prevents reqwest's blocking facade from nesting a Tokio runtime.
pub fn request(raw: &str) -> String {
    let result = (|| {
        let request = core::parse_request(raw)?;
        IN_FLIGHT
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |value| {
                (value < 4).then_some(value + 1)
            })
            .map_err(|_| core::REQUEST_FAILED)?;
        let permit = Permit;
        let worker = std::thread::Builder::new()
            .name("bk-account-http".to_owned())
            .spawn(move || {
                let _permit = permit;
                perform(request)
            })
            .map_err(|_| core::REQUEST_FAILED)?;
        worker.join().map_err(|_| core::REQUEST_FAILED)?
    })();
    match result {
        Ok(response) => json!({
            "ok": true,
            "data": {"status_code": response.status_code, "body": response.body}
        })
        .to_string(),
        Err(error) => json!({"ok": false, "error": error}).to_string(),
    }
}
