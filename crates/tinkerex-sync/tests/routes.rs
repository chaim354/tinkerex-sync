//! `ROUTES` is what `tinkerex-sync routes` prints for an operator, so it must list exactly what
//! the router serves. One direction is checkable from outside: every listed route, requested
//! with no credentials, must reach a handler. axum's own "no such route" answer is an EMPTY 404,
//! whereas every handler-level 404 here carries `{"error":"not_found"}` — so an empty 404 is the
//! one shape that means the listing named a route the router does not have.

mod support;

use support::TestServer;
use tinkerex_sync::http::ROUTES;

#[tokio::test]
async fn every_listed_route_reaches_a_handler() {
    let server = TestServer::start().await;
    let client = server.http();
    for (method, path) in ROUTES {
        // The listing spells params Rails-style (`:node_id`), as the Ruby drawer's listing did.
        let hash = "a".repeat(64);
        let concrete: String = path
            .split('/')
            .map(|seg| match seg {
                ":user_id" | ":id" => "1",
                ":hash" => hash.as_str(),
                s if s.starts_with(':') => "x",
                s => s,
            })
            .collect::<Vec<_>>()
            .join("/");
        let url = format!("{}{concrete}", server.base_url);
        let req = match *method {
            "GET" => client.get(&url),
            "POST" => client.post(&url),
            "PUT" => client.put(&url),
            "DELETE" => client.delete(&url),
            other => panic!("unexpected method {other} in ROUTES"),
        };
        let resp = req.send().await.expect("request");
        let status = resp.status().as_u16();
        let body = resp.text().await.expect("body");
        assert!(
            !(status == 404 && body.is_empty()),
            "{method} {path}: the router has no such route (an empty 404)"
        );
    }
    assert_eq!(
        ROUTES.len(),
        30,
        "29 HTTP routes plus /cable; update this with the listing"
    );
    assert!(ROUTES.contains(&("GET", "/cable")));
}

/// `conformance/routes.txt` is the route list the corpus verifier (`test/conformance_test.rb`)
/// demands a scenario for, one route at a time. It replaced the Ruby drawer the verifier used to
/// ask (`Sync.draw_v1_routes`, deleted with the Ruby in Phase 6), so the one thing it must never be
/// is a hand-kept copy that drifts: this runs the REAL binary's `routes` subcommand and compares
/// its stdout with the file byte for byte, order and trailing newline included. A route added to
/// `ROUTES` is red here until the file is regenerated -- and once it is, the verifier's coverage
/// check is red until a scenario exercises the route or names it as an exception, with a reason.
#[test]
fn the_checked_in_route_list_is_what_the_binary_prints() {
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_tinkerex-sync"))
        .arg("routes")
        .output()
        .expect("run `tinkerex-sync routes`");
    assert!(
        out.status.success(),
        "`tinkerex-sync routes` failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let printed = String::from_utf8(out.stdout).expect("utf-8 output");
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../conformance/routes.txt");
    let checked_in = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{path}: {e}"));
    if printed != checked_in {
        let printed_lines: Vec<&str> = printed.lines().collect();
        let file_lines: Vec<&str> = checked_in.lines().collect();
        let not_in_file: Vec<&&str> = printed_lines
            .iter()
            .filter(|l| !file_lines.contains(l))
            .collect();
        let not_printed: Vec<&&str> = file_lines
            .iter()
            .filter(|l| !printed_lines.contains(l))
            .collect();
        panic!(
            "conformance/routes.txt is not what `tinkerex-sync routes` prints\n  \
             printed, missing from the file: {not_in_file:?}\n  \
             in the file, not printed:       {not_printed:?}\n  \
             (both empty: the order or the trailing newline differs)\n\
             regenerate it: cargo run -q -p tinkerex-sync -- routes > conformance/routes.txt"
        );
    }
}
