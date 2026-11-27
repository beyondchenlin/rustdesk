//! Production policy for explicit proxies and local development account endpoints.
pub fn validate(audience: &str, has_proxy: bool) -> Result<(), &'static str> {
    let url = url::Url::parse(audience).map_err(|_| "Invalid team device request")?;
    if url.scheme() == "http" && has_proxy {
        // A proxy would change localhost's meaning and receive the cleartext bearer.
        return Err("A local plaintext account server cannot be used through a proxy");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn local_plaintext_with_any_configured_proxy_is_refused() {
        for origin in [
            "http://localhost:8080",
            "http://127.0.0.1:8080",
            "http://[::1]:8080",
        ] {
            assert!(validate(origin, true).is_err());
            assert!(validate(origin, false).is_ok());
        }
    }
    #[test]
    fn encrypted_account_requests_preserve_explicit_proxy_support() {
        assert!(validate("https://accounts.example.test", true).is_ok());
        assert!(validate("https://accounts.example.test", false).is_ok());
    }
}
