use super::*;
use std::{
    io::{Read, Write},
    net::{SocketAddr, TcpListener, TcpStream},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    },
    thread,
    time::Instant,
};

fn request(audience: String) -> AccountRequest {
    AccountRequest {
        audience,
        token: "fixture-login".to_owned(),
        method: "GET".to_owned(),
        path: "/api/bk/devices?page=1&pageSize=200".to_owned(),
        body: None,
    }
}

fn read_request(stream: &mut TcpStream) -> String {
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let mut bytes = Vec::new();
    let mut buffer = [0_u8; 2048];
    loop {
        let count = stream.read(&mut buffer).unwrap();
        assert_ne!(count, 0);
        bytes.extend_from_slice(&buffer[..count]);
        if let Some(end) = bytes.windows(4).position(|part| part == b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&bytes[..end]);
            let length = head
                .lines()
                .find_map(|line| {
                    line.to_ascii_lowercase()
                        .strip_prefix("content-length:")
                        .map(|value| value.trim().parse::<usize>().unwrap())
                })
                .unwrap_or_default();
            if bytes.len() >= end + 4 + length {
                return String::from_utf8(bytes).unwrap();
            }
        }
        assert!(bytes.len() < MAX_REQUEST_BYTES + 8192);
    }
}

fn reply(stream: &mut TcpStream, status: u16, extra: &str, body: &str) {
    let head = format!(
        "HTTP/1.1 {status} Fixture\r\nContent-Length: {}\r\nConnection: close\r\n{extra}\r\n",
        body.len()
    );
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(body.as_bytes());
}

fn fixture(
    handler: impl FnOnce(&mut TcpStream, &str) + Send + 'static,
) -> (SocketAddr, mpsc::Receiver<String>, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let address = listener.local_addr().unwrap();
    let (tx, rx) = mpsc::channel();
    let worker = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut stream = loop {
            match listener.accept() {
                Ok((stream, _)) => break stream,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(Instant::now() < deadline, "fixture received no request");
                    thread::sleep(Duration::from_millis(5));
                }
                Err(error) => panic!("{error}"),
            }
        };
        let raw = read_request(&mut stream);
        let _ = tx.send(raw.clone());
        handler(&mut stream, &raw);
    });
    (address, rx, worker)
}

fn direct_client() -> Client {
    finish_client(Client::builder().use_rustls_tls(), None).unwrap()
}

#[test]
fn real_loopback_request_preserves_status_body_and_fixed_authorization() {
    let (address, received, worker) = fixture(|stream, _| reply(stream, 201, "", "{\"ok\":true}"));
    let mut request = request(format!("http://{address}"));
    request.method = "POST".to_owned();
    request.path = "/api/bk/devices/enrollment-tokens".to_owned();
    request.body = Some("{\"id\":\"123456789\"}".to_owned());
    let response = execute(&request, direct_client(), || true).unwrap();
    assert_eq!(response.status_code, 201);
    assert_eq!(response.body, "{\"ok\":true}");
    let raw = received.recv().unwrap();
    assert!(raw.starts_with("POST /api/bk/devices/enrollment-tokens HTTP/1.1"));
    assert!(raw
        .to_ascii_lowercase()
        .contains("authorization: bearer fixture-login"));
    assert!(raw.ends_with(request.body.as_deref().unwrap()));
    worker.join().unwrap();
}

#[test]
fn redirects_are_returned_without_contacting_the_destination() {
    let canary = TcpListener::bind("127.0.0.1:0").unwrap();
    canary.set_nonblocking(true).unwrap();
    let location = format!(
        "Location: http://{}/api/bk/devices\r\n",
        canary.local_addr().unwrap()
    );
    let (address, _, worker) = fixture(move |stream, _| reply(stream, 302, &location, "{}"));
    let response = execute(
        &request(format!("http://{address}")),
        direct_client(),
        || true,
    )
    .unwrap();
    assert_eq!(response.status_code, 302);
    assert_eq!(
        canary.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    worker.join().unwrap();
}

#[test]
fn real_http_proxy_is_used_and_the_origin_is_not_contacted_directly() {
    let origin = TcpListener::bind("127.0.0.1:0").unwrap();
    origin.set_nonblocking(true).unwrap();
    let (proxy_address, received, worker) =
        fixture(|stream, _| reply(stream, 200, "", "{\"via\":\"proxy\"}"));
    let proxy = configured_proxy(
        &format!("http://{proxy_address}"),
        "fixture-user",
        "fixture-password",
    )
    .unwrap();
    let client = finish_client(Client::builder(), Some(proxy)).unwrap();
    let request = request(format!("http://{}", origin.local_addr().unwrap()));
    let response = execute(&request, client, || true).unwrap();
    assert_eq!(response.body, "{\"via\":\"proxy\"}");
    let raw = received.recv().unwrap();
    assert!(raw.starts_with(&format!("GET {}{}", request.audience, request.path)));
    assert!(raw
        .to_ascii_lowercase()
        .contains("proxy-authorization: basic "));
    assert_eq!(
        origin.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    worker.join().unwrap();
}

#[test]
fn real_socks_proxy_carries_the_request_without_a_direct_origin_connection() {
    let origin = TcpListener::bind("127.0.0.1:0").unwrap();
    origin.set_nonblocking(true).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let proxy_address = listener.local_addr().unwrap();
    let (tx, rx) = mpsc::channel();
    let worker = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let mut greeting = [0_u8; 2];
        stream.read_exact(&mut greeting).unwrap();
        assert_eq!(greeting[0], 5);
        let mut methods = vec![0; greeting[1] as usize];
        stream.read_exact(&mut methods).unwrap();
        assert!(methods.contains(&0));
        stream.write_all(&[5, 0]).unwrap();
        let mut connect = [0_u8; 4];
        stream.read_exact(&mut connect).unwrap();
        assert_eq!(&connect[..3], &[5, 1, 0]);
        let length = match connect[3] {
            1 => 4,
            4 => 16,
            3 => {
                let mut length = [0];
                stream.read_exact(&mut length).unwrap();
                length[0] as usize
            }
            _ => panic!("invalid SOCKS address"),
        };
        let mut address = vec![0; length + 2];
        stream.read_exact(&mut address).unwrap();
        stream.write_all(&[5, 0, 0, 1, 127, 0, 0, 1, 0, 0]).unwrap();
        let raw = read_request(&mut stream);
        tx.send(raw).unwrap();
        reply(&mut stream, 200, "", "{\"via\":\"socks\"}");
    });
    let proxy = configured_proxy(&proxy_address.to_string(), "", "").unwrap();
    let client = finish_client(Client::builder(), Some(proxy)).unwrap();
    let result = execute(
        &request(format!("http://{}", origin.local_addr().unwrap())),
        client,
        || true,
    )
    .unwrap();
    assert_eq!(result.body, "{\"via\":\"socks\"}");
    assert!(rx.recv().unwrap().starts_with("GET /api/bk/devices?"));
    assert_eq!(
        origin.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    worker.join().unwrap();
}

#[test]
fn an_unavailable_proxy_does_not_fall_back_to_a_direct_request() {
    let origin = TcpListener::bind("127.0.0.1:0").unwrap();
    origin.set_nonblocking(true).unwrap();
    let closed = TcpListener::bind("127.0.0.1:0").unwrap();
    let proxy_address = closed.local_addr().unwrap();
    drop(closed);
    let proxy = configured_proxy(&format!("http://{proxy_address}"), "", "").unwrap();
    let client = finish_client(Client::builder(), Some(proxy)).unwrap();
    assert!(execute(
        &request(format!("http://{}", origin.local_addr().unwrap())),
        client,
        || true
    )
    .is_err());
    assert_eq!(
        origin.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
}

#[test]
fn methods_paths_plaintext_and_request_sizes_fail_before_network() {
    let valid = request("https://accounts.example.test".to_owned());
    for (method, path, body) in [
        ("DELETE", "/api/bk/devices", None),
        ("POST", "/api/login", Some("{}".to_owned())),
        ("GET", "/api/bk/devices/../admin", None),
        ("GET", "/api/bk/devices?page=1&page=2", None),
        ("GET", "/api/bk/devices?pageSize=201", None),
        ("GET", "//untrusted.example.test/api/bk/devices", None),
        (
            "POST",
            "/api/bk/devices/enroll",
            Some("x".repeat(MAX_REQUEST_BYTES + 1)),
        ),
    ] {
        let input = AccountRequest {
            audience: valid.audience.clone(),
            token: valid.token.clone(),
            method: method.to_owned(),
            path: path.to_owned(),
            body,
        };
        assert_eq!(request_url(&input).unwrap_err(), INVALID_REQUEST);
    }
    for origin in [
        "http://accounts.example.test",
        "https://user:pass@accounts.example.test",
        "https://accounts.example.test?key=x",
        "https://accounts.example.test/#x",
    ] {
        assert_eq!(
            request_url(&request(origin.to_owned())).unwrap_err(),
            INVALID_REQUEST
        );
    }
}

#[test]
fn session_changes_prevent_sending_and_discard_in_flight_responses() {
    let canary = TcpListener::bind("127.0.0.1:0").unwrap();
    canary.set_nonblocking(true).unwrap();
    let result = execute(
        &request(format!("http://{}", canary.local_addr().unwrap())),
        direct_client(),
        || false,
    );
    assert!(matches!(result, Err(SESSION_CHANGED)));
    assert_eq!(
        canary.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    let current = Arc::new(AtomicBool::new(true));
    let changed = current.clone();
    let (address, _, worker) = fixture(move |stream, _| {
        changed.store(false, Ordering::Release);
        reply(stream, 401, "", "{\"error\":\"expired\"}");
    });
    let result = execute(
        &request(format!("http://{address}")),
        direct_client(),
        || current.load(Ordering::Acquire),
    );
    assert!(matches!(result, Err(SESSION_CHANGED)));
    worker.join().unwrap();
}

#[test]
fn oversized_fixed_and_chunked_responses_are_bounded() {
    for chunked in [false, true] {
        let (address, _, worker) = fixture(move |stream, _| {
            let body = "x".repeat(MAX_RESPONSE_BYTES + 1);
            if chunked {
                let head = format!("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n{:x}\r\n", body.len());
                let _ = stream.write_all(head.as_bytes());
                let _ = stream.write_all(body.as_bytes());
                let _ = stream.write_all(b"\r\n0\r\n\r\n");
            } else {
                reply(stream, 200, "", &body);
            }
        });
        let result = execute(
            &request(format!("http://{address}")),
            direct_client(),
            || true,
        );
        assert!(matches!(result, Err(INVALID_RESPONSE)));
        worker.join().unwrap();
    }
}

#[test]
fn a_nonresponding_server_cannot_hold_the_request_beyond_the_native_timeout() {
    let (address, _, worker) = fixture(|_, _| thread::sleep(Duration::from_secs(22)));
    let started = Instant::now();
    let result = execute(
        &request(format!("http://{address}")),
        direct_client(),
        || true,
    );
    assert!(matches!(result, Err(REQUEST_FAILED)));
    assert!(started.elapsed() >= Duration::from_secs(18));
    assert!(started.elapsed() < Duration::from_secs(22));
    worker.join().unwrap();
}

#[test]
fn proxy_parsing_does_not_resolve_names_and_rejects_invalid_configuration() {
    assert!(configured_proxy("unresolvable-proxy.invalid:1080", "", "").is_ok());
    assert!(configured_proxy("https://proxy.invalid:443", "user", "password").is_ok());
    for address in [
        "",
        "ftp://proxy.invalid",
        "http://proxy.invalid/path",
        "http://proxy.invalid/?q=1",
    ] {
        assert!(configured_proxy(address, "", "").is_err());
    }
}

#[test]
fn proxy_authentication_refusal_never_retries_the_origin_directly() {
    let origin = TcpListener::bind("127.0.0.1:0").unwrap();
    origin.set_nonblocking(true).unwrap();
    let (proxy_address, _, worker) = fixture(|stream, _| {
        reply(
            stream,
            407,
            "Proxy-Authenticate: Basic realm=\"fixture\"\r\n",
            "{}",
        )
    });
    let proxy = configured_proxy(
        &format!("http://{proxy_address}"),
        "bad-user",
        "bad-password",
    )
    .unwrap();
    let client = finish_client(Client::builder(), Some(proxy)).unwrap();
    let response = execute(
        &request(format!("http://{}", origin.local_addr().unwrap())),
        client,
        || true,
    )
    .unwrap();
    assert_eq!(response.status_code, 407);
    assert_eq!(
        origin.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    worker.join().unwrap();
}

#[test]
fn socks_authentication_refusal_does_not_send_http_or_fall_back_directly() {
    let origin = TcpListener::bind("127.0.0.1:0").unwrap();
    origin.set_nonblocking(true).unwrap();
    let proxy = TcpListener::bind("127.0.0.1:0").unwrap();
    let proxy_address = proxy.local_addr().unwrap();
    let worker = thread::spawn(move || {
        let (mut stream, _) = proxy.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let mut header = [0_u8; 2];
        stream.read_exact(&mut header).unwrap();
        assert_eq!(header[0], 5);
        let mut methods = vec![0_u8; header[1] as usize];
        stream.read_exact(&mut methods).unwrap();
        assert!(methods.contains(&2));
        stream.write_all(&[5, 2]).unwrap();
        stream.read_exact(&mut header).unwrap();
        assert_eq!(header[0], 1);
        let mut username = vec![0_u8; header[1] as usize];
        stream.read_exact(&mut username).unwrap();
        assert_eq!(username, b"bad-user");
        let mut length = [0_u8; 1];
        stream.read_exact(&mut length).unwrap();
        let mut password = vec![0_u8; length[0] as usize];
        stream.read_exact(&mut password).unwrap();
        assert_eq!(password, b"bad-password");
        stream.write_all(&[1, 1]).unwrap();
        let mut unexpected = [0_u8; 1];
        assert_eq!(stream.read(&mut unexpected).unwrap_or(0), 0);
    });
    let proxy = configured_proxy(
        &format!("socks5://{proxy_address}"),
        "bad-user",
        "bad-password",
    )
    .unwrap();
    let client = finish_client(Client::builder(), Some(proxy)).unwrap();
    assert!(execute(
        &request(format!("http://{}", origin.local_addr().unwrap())),
        client,
        || true
    )
    .is_err());
    assert_eq!(
        origin.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    worker.join().unwrap();
}
