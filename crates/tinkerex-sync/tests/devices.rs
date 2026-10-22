//! Device revocation and idle expiry (tinkerex#473), driven through the real router. The corpus
//! (`conformance/scenarios/17-device-revocation.yml`) pins the door's wire answers; this file pins
//! what the wire cannot show -- the rows a revocation leaves, idle expiry (a TTL, out of the
//! corpus's reach), the `last_seen_at` throttle, a revoked token on EVERY authenticated route,
//! the mint/revoke race, and the operator's subcommands -- and repeats the door's rule against
//! `TEST_DATABASE_URL`'s Postgres when that leg runs.

mod support;

use serde_json::json;
use support::{DAY, TestServer};
use tinkerex_sync::config;
use tinkerex_sync::db::Query;
use tinkerex_sync::error::ApiError;
use tinkerex_sync::http::ROUTES;
use tinkerex_sync::models::{Device, LAST_SEEN_RESOLUTION_SECONDS};
use tinkerex_sync::services::{provisioning, revocation};
use tinkerex_sync::time::Timestamp;

const UNAUTHORIZED: &str = r#"{"error":"unauthorized"}"#;
const NOT_FOUND: &str = r#"{"error":"not_found"}"#;
const FORBIDDEN: &str = r#"{"error":"forbidden"}"#;
const LIBRARY_CREDENTIAL: &str = r#"{"error":"library_credential"}"#;

// ---- the door's rule ------------------------------------------------------------------------

#[tokio::test]
async fn the_door_answers_by_the_lineage_rule_with_its_reason() {
    let server = TestServer::start().await;
    let library = server.issue_device("rule@test.example", "library").await;
    let a = server.mint(&library.device_token, "a").await;
    let b = server.mint(&library.device_token, "b").await;
    let a1 = server.mint(&a.device_token, "a1").await;
    let id = |d: &provisioning::IssuedDevice| d.device_id.to_string();

    assert_eq!(
        server.revoke(&a.device_token, &id(&b)).await,
        (403, FORBIDDEN.into()),
        "a sibling"
    );
    assert_eq!(
        server.revoke(&a1.device_token, &id(&a)).await,
        (403, FORBIDDEN.into()),
        "the device that minted it"
    );
    assert_eq!(
        server.revoke(&a.device_token, &id(&library)).await,
        (403, LIBRARY_CREDENTIAL.into()),
        "the library credential"
    );
    assert_eq!(
        server.revoke(&library.device_token, &id(&library)).await,
        (403, LIBRARY_CREDENTIAL.into()),
        "a library credential, by itself"
    );
    // Nothing above changed anything.
    for d in [&library, &a, &b, &a1] {
        assert_eq!(server.whoami_status(&d.device_token).await, 200);
    }

    assert_eq!(
        server.revoke(&a.device_token, &id(&a1)).await,
        (204, String::new()),
        "its own child"
    );
    assert_eq!(
        server.revoke(&b.device_token, &id(&b)).await,
        (204, String::new()),
        "itself"
    );
    assert_eq!(server.whoami_status(&a1.device_token).await, 401);
    assert_eq!(server.whoami_status(&b.device_token).await, 401);
    assert_eq!(
        server.whoami_status(&a.device_token).await,
        200,
        "revoking a child leaves its issuer alone"
    );
    assert_eq!(server.whoami_status(&library.device_token).await, 200);
}

#[tokio::test]
async fn an_id_outside_the_library_is_the_plain_404_an_unknown_one_gets_and_touches_nothing() {
    let server = TestServer::start().await;
    let one = server
        .issue_device("tenant-1@test.example", "library")
        .await;
    let one_d = server.mint(&one.device_token, "one-d").await;
    let two = server
        .issue_device("tenant-2@test.example", "library")
        .await;
    let two_d = server.mint(&two.device_token, "two-d").await;

    let foreign = server
        .revoke(&one.device_token, &two_d.device_id.to_string())
        .await;
    let unknown = server.revoke(&one.device_token, "999999999").await;
    assert_eq!(foreign, (404, NOT_FOUND.into()));
    assert_eq!(foreign, unknown, "nothing says the id exists elsewhere");
    assert_eq!(
        server.revoke(&one.device_token, "not-a-device").await,
        unknown
    );
    assert_eq!(
        server
            .revoke(&two.device_token, &one_d.device_id.to_string())
            .await,
        (404, NOT_FOUND.into()),
        "and from the other side"
    );
    assert_eq!(
        server
            .revoke(&two.device_token, &one.device_id.to_string())
            .await,
        (404, NOT_FOUND.into()),
        "a foreign LIBRARY credential is a 404 too, not a 403 that would confirm it"
    );
    for d in [&one, &one_d, &two, &two_d] {
        assert_eq!(server.whoami_status(&d.device_token).await, 200);
        assert_eq!(server.device_time(d.device_id, "revoked_at").await, None);
    }
}

#[tokio::test]
async fn a_revocation_cascades_keeps_the_rows_and_stamps_once() {
    let server = TestServer::start().await;
    let library = server.issue_device("cascade@test.example", "library").await;
    let a = server.mint(&library.device_token, "a").await;
    let a1 = server.mint(&a.device_token, "a1").await;
    let a11 = server.mint(&a1.device_token, "a11").await;
    let b = server.mint(&library.device_token, "b").await;

    assert_eq!(
        server
            .revoke(&library.device_token, &a.device_id.to_string())
            .await,
        (204, String::new())
    );
    for d in [&a, &a1, &a11] {
        assert_eq!(
            server.whoami_status(&d.device_token).await,
            401,
            "device {} is in A's subtree",
            d.device_id
        );
        assert!(
            server
                .device_time(d.device_id, "revoked_at")
                .await
                .is_some(),
            "device {} keeps its row, stamped",
            d.device_id
        );
    }
    assert_eq!(server.whoami_status(&b.device_token).await, 200);
    assert_eq!(server.whoami_status(&library.device_token).await, 200);

    // A repeat answers the same and moves nothing: revoked_at is the FIRST revocation's.
    let first = server.device_time(a11.device_id, "revoked_at").await;
    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    assert_eq!(
        server
            .revoke(&library.device_token, &a.device_id.to_string())
            .await,
        (204, String::new())
    );
    assert_eq!(server.device_time(a11.device_id, "revoked_at").await, first);

    // The rows stay, so a conflict or a lock written by A still names it.
    let mut db = server.db.clone();
    assert_eq!(
        Device::name_of(
            &mut db,
            user_of(&server, a.device_id).await,
            Some(a.device_id)
        )
        .await
        .unwrap()
        .as_deref(),
        Some("a")
    );
}

/// A device the door revokes after `POST /v1/devices` authenticated it, but before the mint took
/// the user lock, must not leave a live child: the mint re-reads its issuer under the lock.
#[tokio::test]
async fn a_mint_by_a_device_revoked_after_it_authenticated_is_refused() {
    let server = TestServer::start().await;
    let library = server.issue_device("race@test.example", "library").await;
    let a = server.mint(&library.device_token, "a").await;
    let mut db = server.db.clone();
    let as_authenticated = Device::find(&mut db, a.device_id).await.unwrap().unwrap();
    assert_eq!(
        server
            .revoke(&library.device_token, &a.device_id.to_string())
            .await
            .0,
        204
    );
    let late =
        provisioning::register_sibling(&server.db, &as_authenticated, "late", Timestamp::now())
            .await;
    match late {
        Err(ApiError::Unauthorized) => {}
        Err(e) => panic!("expected a 401, got {e:?}"),
        Ok(_) => panic!("minted a live child under a revoked issuer"),
    }
    assert_eq!(
        server
            .scalar(
                "SELECT count(*) AS n FROM devices WHERE name = $1",
                &[json!("late")]
            )
            .await,
        Some(0)
    );
}

// ---- a revoked token, everywhere ------------------------------------------------------------

/// The routes a device token does not authenticate, each for its own reason; every other route
/// in `ROUTES` must refuse a revoked token.
const NOT_DEVICE_AUTHENTICATED: &[(&str, &str)] = &[
    ("GET", "/up"),                            // the readiness probe
    ("GET", "/v1/share/:token"),               // the share token is the authorization
    ("POST", "/v1/share/:token/download"),     // likewise
    ("PUT", "/v1/chunks/blob/:user_id/:hash"), // a presigned URL: signature and exp
    ("GET", "/v1/chunks/blob/:user_id/:hash"), // likewise
    ("POST", "/v1/admin/libraries"),           // the operator credential
    ("GET", "/cable"),                         // the token in the query; tests/cable.rs
];

async fn send(server: &TestServer, method: &str, path: &str, token: &str) -> (u16, String) {
    let concrete: String = path
        .split('/')
        .map(|seg| match seg {
            ":id" => "1",
            s if s.starts_with(':') => "x",
            s => s,
        })
        .collect::<Vec<_>>()
        .join("/");
    let url = format!("{}{concrete}", server.base_url);
    let client = server.http();
    let req = match method {
        "GET" => client.get(&url),
        "POST" => client.post(&url).json(&json!({})),
        "PUT" => client.put(&url).json(&json!({})),
        "DELETE" => client.delete(&url),
        other => panic!("unexpected method {other}"),
    };
    let resp = req.bearer_auth(token).send().await.expect("request");
    let status = resp.status().as_u16();
    (status, resp.text().await.expect("body"))
}

#[tokio::test]
async fn a_revoked_token_is_refused_on_every_device_authenticated_route() {
    let server = TestServer::start().await;
    let library = server
        .issue_device("every-route@test.example", "library")
        .await;
    let device = server.mint(&library.device_token, "doomed").await;
    for exception in NOT_DEVICE_AUTHENTICATED {
        assert!(
            ROUTES.contains(exception),
            "{exception:?} is no route any more"
        );
    }
    let routes: Vec<&(&str, &str)> = ROUTES
        .iter()
        .filter(|r| !NOT_DEVICE_AUTHENTICATED.contains(r))
        .collect();
    assert!(
        routes.len() >= 20,
        "the scanned set must not be (nearly) empty: {routes:?}"
    );

    // Live first, so the 401s below are the revocation's and not the requests' own shape.
    for (method, path) in &routes {
        let (status, body) = send(&server, method, path, &device.device_token).await;
        assert_ne!(status, 401, "{method} {path} refused a LIVE token: {body}");
    }
    assert_eq!(
        server
            .revoke(&library.device_token, &device.device_id.to_string())
            .await
            .0,
        204
    );
    for (method, path) in &routes {
        assert_eq!(
            send(&server, method, path, &device.device_token).await,
            (401, UNAUTHORIZED.into()),
            "{method} {path} with a revoked token"
        );
    }
}

// ---- idle expiry ----------------------------------------------------------------------------

#[tokio::test]
async fn a_device_credential_idle_past_the_limit_is_refused_and_not_restamped() {
    let server = TestServer::start().await; // DEVICE_IDLE_DAYS unset: the maker app's 90
    let library = server.issue_device("idle@test.example", "library").await;
    let device = server.mint(&library.device_token, "idle").await;
    let now = Timestamp::now();

    let idle = now.minus_seconds(91 * DAY);
    server
        .set_device_time(device.device_id, "last_seen_at", Some(idle))
        .await;
    assert_eq!(server.whoami_status(&device.device_token).await, 401);
    assert_eq!(
        server.device_time(device.device_id, "last_seen_at").await,
        Some(idle),
        "a refused request must not restart the clock it was refused by"
    );

    let in_use = now.minus_seconds(89 * DAY);
    server
        .set_device_time(device.device_id, "last_seen_at", Some(in_use))
        .await;
    assert_eq!(server.whoami_status(&device.device_token).await, 200);
    assert!(
        server
            .device_time(device.device_id, "last_seen_at")
            .await
            .unwrap()
            >= now,
        "an admitted request moves the clock"
    );
}

#[tokio::test]
async fn a_device_never_used_since_it_was_minted_counts_from_created_at() {
    let server = TestServer::start().await;
    let library = server.issue_device("never@test.example", "library").await;
    let device = server.mint(&library.device_token, "never").await;
    assert_eq!(
        server.device_time(device.device_id, "last_seen_at").await,
        None
    );
    let now = Timestamp::now();
    server
        .set_device_time(
            device.device_id,
            "created_at",
            Some(now.minus_seconds(91 * DAY)),
        )
        .await;
    assert_eq!(server.whoami_status(&device.device_token).await, 401);
    server
        .set_device_time(
            device.device_id,
            "created_at",
            Some(now.minus_seconds(89 * DAY)),
        )
        .await;
    assert_eq!(server.whoami_status(&device.device_token).await, 200);
}

/// The maker app's own token is a library credential, and nothing can mint that library another
/// one through the API: if it idled out while the user only synced from a desktop, their library
/// would be stranded until an operator stepped in.
#[tokio::test]
async fn a_library_credential_never_idles_out() {
    let server = TestServer::start().await;
    let library = server.issue_device("ancient@test.example", "library").await;
    server
        .set_device_time(
            library.device_id,
            "last_seen_at",
            Some(Timestamp::now().minus_seconds(400 * DAY)),
        )
        .await;
    assert_eq!(server.whoami_status(&library.device_token).await, 200);
}

#[tokio::test]
async fn zero_turns_idle_expiry_off() {
    let server = TestServer::start_tuned(|c| {
        c.device_idle_days = config::device_idle_days(Some("0"));
    })
    .await;
    let library = server.issue_device("zero@test.example", "library").await;
    let device = server.mint(&library.device_token, "kept").await;
    server
        .set_device_time(
            device.device_id,
            "last_seen_at",
            Some(Timestamp::now().minus_seconds(400 * DAY)),
        )
        .await;
    assert_eq!(server.whoami_status(&device.device_token).await, 200);
}

#[tokio::test]
async fn last_seen_moves_at_most_once_per_resolution() {
    let server = TestServer::start().await;
    let library = server
        .issue_device("throttle@test.example", "library")
        .await;
    let device = server.mint(&library.device_token, "busy").await;
    let now = Timestamp::now();

    let recent = now.minus_seconds(LAST_SEEN_RESOLUTION_SECONDS - 60);
    server
        .set_device_time(device.device_id, "last_seen_at", Some(recent))
        .await;
    assert_eq!(server.whoami_status(&device.device_token).await, 200);
    assert_eq!(
        server.device_time(device.device_id, "last_seen_at").await,
        Some(recent),
        "within the resolution, an admitted request writes nothing"
    );

    let stale = now.minus_seconds(LAST_SEEN_RESOLUTION_SECONDS + 1);
    server
        .set_device_time(device.device_id, "last_seen_at", Some(stale))
        .await;
    assert_eq!(server.whoami_status(&device.device_token).await, 200);
    assert!(
        server
            .device_time(device.device_id, "last_seen_at")
            .await
            .unwrap()
            >= now,
        "past it, the request moves the clock"
    );
}

// ---- the operator ---------------------------------------------------------------------------

fn bin(dir: &std::path::Path, args: &[&str]) -> std::process::Output {
    std::process::Command::new(env!("CARGO_BIN_EXE_tinkerex-sync"))
        .args(args)
        .env_remove("DATABASE_URL")
        .env("SQLITE_DATABASE", dir.join("op.sqlite3"))
        .env("STORAGE_BACKEND", "local")
        .env("CHUNK_LOCAL_DIR", dir.join("chunks"))
        .env("SECRET_KEY_BASE", "operator-test")
        .output()
        .expect("run tinkerex-sync")
}

fn stdout(o: &std::process::Output) -> String {
    String::from_utf8_lossy(&o.stdout).into_owned()
}

#[test]
fn the_operator_revokes_a_library_credential_and_the_list_says_so() {
    let dir = tempfile::tempdir().unwrap();
    assert_eq!(stdout(&bin(dir.path(), &["migrate"])).trim(), "Created");
    let issued = bin(
        dir.path(),
        &["device", "issue", "--email", "op@test.example"],
    );
    let device_id = stdout(&issued)
        .lines()
        .find_map(|l| l.strip_prefix("device_id:").map(|v| v.trim().to_string()))
        .expect("device issue prints device_id");

    let listed = stdout(&bin(
        dir.path(),
        &["device", "list", "--email", "op@test.example"],
    ));
    assert!(listed.contains("library credential\tlive"), "{listed}");

    let revoked = bin(dir.path(), &["device", "revoke", "--id", &device_id]);
    assert!(revoked.status.success(), "{revoked:?}");
    assert!(
        stdout(&revoked).contains(&format!("revoked {device_id} ")),
        "{}",
        stdout(&revoked)
    );
    let listed = stdout(&bin(
        dir.path(),
        &["device", "list", "--email", "op@test.example"],
    ));
    assert!(listed.contains("library credential\trevoked "), "{listed}");
    assert!(
        !bin(dir.path(), &["device", "revoke", "--id", "999999"])
            .status
            .success(),
        "an unknown id is an error"
    );
}

/// A server whose database lacks a migration would answer 500 to every device request while `/up`
/// (which reads only `users`) said ok; it must refuse to start instead.
#[test]
fn serve_refuses_a_database_with_a_pending_migration() {
    let dir = tempfile::tempdir().unwrap();
    assert_eq!(stdout(&bin(dir.path(), &["migrate"])).trim(), "Created");
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        let db = tinkerex_sync::db::Db::connect(&config::DatabaseConfig::Sqlite {
            path: dir.path().join("op.sqlite3"),
        })
        .await
        .unwrap();
        db.execute(&Query::new("DELETE FROM tinkerex_sync_migrations"))
            .await
            .unwrap();
    });
    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_tinkerex-sync"))
        .args(["serve", "--bind", "127.0.0.1", "--port", "0"])
        .env_remove("DATABASE_URL")
        .env_remove("SYNC_SCHEDULER")
        .env("SQLITE_DATABASE", dir.path().join("op.sqlite3"))
        .env("STORAGE_BACKEND", "local")
        .env("CHUNK_LOCAL_DIR", dir.path().join("chunks"))
        .env("SECRET_KEY_BASE", "operator-test")
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if std::time::Instant::now() > deadline {
            let _ = child.kill();
            panic!("serve started on a database missing a migration");
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    };
    let out = child.wait_with_output().unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(!status.success());
    assert!(
        stderr.contains("missing migration(s) 20261022000001"),
        "{stderr}"
    );
}

// ---- helpers --------------------------------------------------------------------------------

async fn user_of(server: &TestServer, device_id: i64) -> i64 {
    let mut db = server.db.clone();
    Device::find(&mut db, device_id)
        .await
        .unwrap()
        .unwrap()
        .user_id
}

#[tokio::test]
async fn the_operator_door_reaches_every_kind_with_the_same_cascade() {
    let server = TestServer::start().await;
    let library = server.issue_device("op-door@test.example", "library").await;
    let a = server.mint(&library.device_token, "a").await;
    let a1 = server.mint(&a.device_token, "a1").await;
    let (target, mut ids) =
        revocation::revoke_as_operator(&server.db, library.device_id, Timestamp::now())
            .await
            .unwrap()
            .expect("a known id");
    ids.sort_unstable();
    assert_eq!(target.id, library.device_id);
    assert_eq!(ids, vec![library.device_id, a.device_id, a1.device_id]);
    for d in [&library, &a, &a1] {
        assert_eq!(server.whoami_status(&d.device_token).await, 401);
    }
    assert!(
        revocation::revoke_as_operator(&server.db, 999_999_999, Timestamp::now())
            .await
            .unwrap()
            .is_none()
    );
}
