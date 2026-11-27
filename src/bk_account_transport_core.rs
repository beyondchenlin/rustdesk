//! Bounded transport shared by the application and the isolated loopback regressions.
use reqwest::blocking::{Client, ClientBuilder};
use serde_derive::Deserialize;
use std::{collections::HashSet, io::Read, time::Duration};

pub const MAX_BRIDGE_BYTES: usize = 64 * 1024;
pub const MAX_REQUEST_BYTES: usize = 16 * 1024;
pub const MAX_RESPONSE_BYTES: usize = 1024 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
pub const INVALID_REQUEST: &str = "Invalid team device request";
pub const INVALID_RESPONSE: &str = "Invalid account server response";
pub const REQUEST_FAILED: &str = "The team device request failed";
pub const SESSION_CHANGED: &str = "The account or server changed";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AccountRequest {
    pub audience: String,
    pub token: String,
    pub method: String,
    pub path: String,
    pub body: Option<String>,
}

pub struct AccountResponse {
    pub status_code: u16,
    pub body: String,
}

pub fn parse_request(raw: &str) -> Result<AccountRequest, &'static str> {
    if raw.len() > MAX_BRIDGE_BYTES {
        return Err(INVALID_REQUEST);
    }
    let request: AccountRequest = serde_json::from_str(raw).map_err(|_| INVALID_REQUEST)?;
    request_url(&request)?;
    Ok(request)
}

fn request_url(request: &AccountRequest) -> Result<url::Url, &'static str> {
    if request.audience.len() > 2048
        || request.token.is_empty()
        || request.token.len() > 8192
        || request.token.bytes().any(|byte| byte <= 32 || byte == 127)
        || request.path.len() > 2048
    {
        return Err(INVALID_REQUEST);
    }
    let origin = url::Url::parse(&request.audience).map_err(|_| INVALID_REQUEST)?;
    let loopback = matches!(
        origin.host_str(),
        Some("localhost" | "127.0.0.1" | "[::1]" | "::1")
    );
    if !origin.has_host()
        || !(origin.scheme() == "https" || (origin.scheme() == "http" && loopback))
        || !origin.username().is_empty()
        || origin.password().is_some()
        || origin.query().is_some()
        || origin.fragment().is_some()
        || request.audience.ends_with('/')
    {
        return Err(INVALID_REQUEST);
    }
    let (path, query) = request
        .path
        .split_once('?')
        .map_or((request.path.as_str(), None), |(path, query)| {
            (path, Some(query))
        });
    let method = request.method.as_str();
    match method {
        "GET" if path == "/api/bk/devices" && request.body.is_none() => {
            if let Some(query) = query {
                let mut names = HashSet::new();
                for (key, value) in url::form_urlencoded::parse(query.as_bytes()) {
                    if !names.insert(key.to_string())
                        || !matches!(key.as_ref(), "page" | "pageSize")
                        || value.is_empty()
                        || !value.bytes().all(|byte| byte.is_ascii_digit())
                    {
                        return Err(INVALID_REQUEST);
                    }
                    let number: u32 = value.parse().map_err(|_| INVALID_REQUEST)?;
                    let maximum = if key == "page" { 100_000 } else { 200 };
                    if number == 0 || number > maximum {
                        return Err(INVALID_REQUEST);
                    }
                }
            }
        }
        "POST"
            if query.is_none()
                && matches!(
                    path,
                    "/api/bk/devices/enrollment-tokens"
                        | "/api/bk/devices/challenges"
                        | "/api/bk/devices/enroll"
                        | "/api/bk/devices/revoke-token"
                        | "/api/bk/devices/revoke"
                        | "/api/bk/devices/release"
                        | "/api/bk/devices/presence"
                        | "/api/bk/devices/grants"
                ) =>
        {
            let body = request.body.as_deref().ok_or(INVALID_REQUEST)?;
            if body.len() > MAX_REQUEST_BYTES {
                return Err(INVALID_REQUEST);
            }
            if !serde_json::from_str::<serde_json::Value>(body)
                .map_err(|_| INVALID_REQUEST)?
                .is_object()
            {
                return Err(INVALID_REQUEST);
            }
        }
        _ => return Err(INVALID_REQUEST),
    }
    url::Url::parse(&format!("{}{}", request.audience, request.path)).map_err(|_| INVALID_REQUEST)
}

/// Parse the existing configured proxy without synchronous DNS outside the timeout.
pub fn configured_proxy(
    address: &str,
    username: &str,
    password: &str,
) -> Result<reqwest::Proxy, &'static str> {
    if address.is_empty() || address.len() > 8192 {
        return Err(INVALID_REQUEST);
    }
    let address = if address.contains("://") {
        address.to_owned()
    } else {
        format!("socks5://{address}")
    };
    let mut url = url::Url::parse(&address).map_err(|_| INVALID_REQUEST)?;
    if !url.has_host()
        || !matches!(url.scheme(), "http" | "https" | "socks5" | "socks5h")
        || !matches!(url.path(), "" | "/")
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(INVALID_REQUEST);
    }
    if matches!(url.scheme(), "socks5" | "socks5h") {
        if url.port().is_none() {
            url.set_port(Some(1080)).map_err(|_| INVALID_REQUEST)?;
        }
        url.set_scheme("socks5h").map_err(|_| INVALID_REQUEST)?;
    }
    let mut proxy = reqwest::Proxy::all(url).map_err(|_| INVALID_REQUEST)?;
    if !username.is_empty() || !password.is_empty() {
        proxy = proxy.basic_auth(username, password);
    }
    Ok(proxy)
}

/// Always retain these restrictions even when the platform selects a TLS verifier.
pub fn finish_client(
    builder: ClientBuilder,
    proxy: Option<reqwest::Proxy>,
) -> Result<Client, &'static str> {
    let mut builder = builder
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .timeout(REQUEST_TIMEOUT);
    if let Some(proxy) = proxy {
        builder = builder.proxy(proxy);
    }
    builder.build().map_err(|_| REQUEST_FAILED)
}

pub fn execute(
    request: &AccountRequest,
    client: Client,
    still_current: impl Fn() -> bool,
) -> Result<AccountResponse, &'static str> {
    let url = request_url(request)?;
    if !still_current() {
        return Err(SESSION_CHANGED);
    }
    let method =
        reqwest::Method::from_bytes(request.method.as_bytes()).map_err(|_| INVALID_REQUEST)?;
    let mut outgoing = client
        .request(method, url)
        .timeout(REQUEST_TIMEOUT)
        .bearer_auth(&request.token)
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .header(reqwest::header::ACCEPT, "application/json");
    if let Some(body) = &request.body {
        outgoing = outgoing.body(body.clone());
    }
    // No retry and no URL-keyed response slot: each call owns its request and reply.
    let response = outgoing.send().map_err(|_| REQUEST_FAILED)?;
    let status_code = response.status().as_u16();
    if response
        .content_length()
        .is_some_and(|length| length > MAX_RESPONSE_BYTES as u64)
    {
        return Err(INVALID_RESPONSE);
    }
    let mut bytes = Vec::new();
    response
        .take((MAX_RESPONSE_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| REQUEST_FAILED)?;
    if bytes.len() > MAX_RESPONSE_BYTES {
        return Err(INVALID_RESPONSE);
    }
    if !still_current() {
        return Err(SESSION_CHANGED);
    }
    let body = String::from_utf8(bytes).map_err(|_| INVALID_RESPONSE)?;
    Ok(AccountResponse { status_code, body })
}

#[cfg(test)]
#[path = "bk_account_transport_core_tests.rs"]
mod tests;
