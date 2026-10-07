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
