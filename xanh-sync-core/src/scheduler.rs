use serde::{Deserialize, Serialize};

use crate::SyncReason;

pub const FOREGROUND_SYNC_INTERVAL_SECONDS: u64 = 15 * 60;
pub const LOCAL_CHANGE_DEBOUNCE_SECONDS: u64 = 30;

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct Schedule {
    pub last_sync_epoch_seconds: Option<u64>,
    pub next_sync_allowed_epoch_seconds: Option<u64>,
    pub pending_local_change_epoch_seconds: Option<u64>,
}

impl Schedule {
    pub fn is_due(&self, reason: SyncReason, now: u64) -> bool {
        if self
            .next_sync_allowed_epoch_seconds
            .is_some_and(|until| now < until)
        {
            return false;
        }
        match reason {
            SyncReason::Manual | SyncReason::PreSleep => true,
            SyncReason::Startup | SyncReason::Scheduled => self
                .last_sync_epoch_seconds
                .is_none_or(|last| now.saturating_sub(last) >= FOREGROUND_SYNC_INTERVAL_SECONDS),
            SyncReason::LocalChange => self
                .pending_local_change_epoch_seconds
                .is_some_and(|change| now.saturating_sub(change) >= LOCAL_CHANGE_DEBOUNCE_SECONDS),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_changes_debounce_and_backoff_wins() {
        let mut schedule = Schedule {
            pending_local_change_epoch_seconds: Some(100),
            ..Schedule::default()
        };
        assert!(!schedule.is_due(SyncReason::LocalChange, 129));
        assert!(schedule.is_due(SyncReason::LocalChange, 130));
        schedule.next_sync_allowed_epoch_seconds = Some(200);
        assert!(!schedule.is_due(SyncReason::Manual, 199));
    }
}
