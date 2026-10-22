//! The realtime nudge: on every commit, mutation, restore or resolution the server tells the
//! user's devices `{head_seq}` — "something changed, go pull". Coarse (one per request), never a
//! diff; a device that misses it converges by polling. One in-process hub: the deployment is one
//! container, exactly as the Rails host's `CABLE_ADAPTER: async` was.
//!
//! The same channel carries revocations, so the revoke door cuts a revoked device's open socket
//! at once instead of at its next re-check (`http::cable`).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use tokio::sync::broadcast;

#[derive(Debug, Clone)]
pub enum Event {
    /// The library's new `head_seq`.
    Head(i64),
    /// These devices of the library were revoked.
    Revoked(Arc<[i64]>),
}

#[derive(Default)]
pub struct Hub {
    senders: Mutex<HashMap<i64, broadcast::Sender<Event>>>,
}

impl Hub {
    pub fn new() -> Self {
        Self::default()
    }

    /// Only the HIGHEST seq matters to a subscriber: a device pulls everything since its own
    /// cursor, so a nudge carrying the final head_seq subsumes any that preceded it.
    pub fn publish(&self, user_id: i64, seq: i64) {
        self.send(user_id, Event::Head(seq));
    }

    pub fn revoked(&self, user_id: i64, device_ids: &[i64]) {
        self.send(user_id, Event::Revoked(device_ids.into()));
    }

    fn send(&self, user_id: i64, event: Event) {
        let senders = self.senders.lock().expect("hub lock");
        if let Some(tx) = senders.get(&user_id) {
            let _ = tx.send(event);
        }
    }

    pub fn subscribe(&self, user_id: i64) -> broadcast::Receiver<Event> {
        let mut senders = self.senders.lock().expect("hub lock");
        senders
            .entry(user_id)
            .or_insert_with(|| broadcast::channel(64).0)
            .subscribe()
    }
}
