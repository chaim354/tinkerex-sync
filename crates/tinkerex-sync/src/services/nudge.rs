//! The realtime nudge: on every commit, mutation, restore or resolution the server tells the
//! user's devices `{head_seq}` — "something changed, go pull". Coarse (one per request), never a
//! diff; a device that misses it converges by polling. One in-process hub: the deployment is one
//! container, exactly as the Rails host's `CABLE_ADAPTER: async` was.

use std::collections::HashMap;
use std::sync::Mutex;

use tokio::sync::broadcast;

#[derive(Default)]
pub struct Hub {
    senders: Mutex<HashMap<i64, broadcast::Sender<i64>>>,
}

impl Hub {
    pub fn new() -> Self {
        Self::default()
    }

    /// Only the HIGHEST seq matters to a subscriber: a device pulls everything since its own
    /// cursor, so a nudge carrying the final head_seq subsumes any that preceded it.
    pub fn publish(&self, user_id: i64, seq: i64) {
        let senders = self.senders.lock().expect("hub lock");
        if let Some(tx) = senders.get(&user_id) {
            let _ = tx.send(seq);
        }
    }

    pub fn subscribe(&self, user_id: i64) -> broadcast::Receiver<i64> {
        let mut senders = self.senders.lock().expect("hub lock");
        senders
            .entry(user_id)
            .or_insert_with(|| broadcast::channel(64).0)
            .subscribe()
    }
}
