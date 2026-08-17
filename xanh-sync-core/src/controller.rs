use std::collections::BTreeSet;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::{Schedule, SyncConfig, VaultState};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "kebab-case")]
pub enum AccountState {
    Disconnected,
    Authenticating,
    Connected,
    AuthIssues,
}

#[derive(
    Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize, Deserialize, uniffi::Enum,
)]
#[serde(rename_all = "kebab-case")]
pub enum SyncEngine {
    Bookmarks,
    History,
    Tabs,
    Passwords,
}

impl SyncEngine {
    pub fn service_name(self) -> &'static str {
        match self {
            Self::Bookmarks => "bookmarks",
            Self::History => "history",
            Self::Tabs => "tabs",
            Self::Passwords => "passwords",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "kebab-case")]
pub enum SyncReason {
    Startup,
    Manual,
    Scheduled,
    LocalChange,
    PreSleep,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "kebab-case")]
pub enum SyncStatus {
    Idle,
    Running,
    Success,
    Partial,
    NetworkError,
    AuthError,
    BackedOff,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct SyncSnapshot {
    pub account_state: AccountState,
    pub status: SyncStatus,
    pub enabled_engines: Vec<SyncEngine>,
    pub vault_state: VaultState,
    pub last_sync_epoch_seconds: Option<u64>,
    pub next_sync_allowed_epoch_seconds: Option<u64>,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SyncError {
    #[error("invalid configuration: {0}")]
    InvalidConfig(String),
    #[error("authentication is required")]
    AuthenticationRequired,
    #[error("a sync is already running")]
    Busy,
    #[error("server backoff is active until {0}")]
    BackedOff(u64),
    #[error("vault is locked")]
    VaultLocked,
    #[error("invalid bridge message: {0}")]
    InvalidBridgeMessage(String),
    #[error("migration is not safe to commit: {0}")]
    Migration(String),
    #[error("backend failure: {0}")]
    Backend(String),
}

#[derive(Debug)]
struct State {
    account_state: AccountState,
    status: SyncStatus,
    enabled_engines: BTreeSet<SyncEngine>,
    schedule: Schedule,
    vault_state: VaultState,
}

#[derive(Debug, uniffi::Object)]
pub struct SyncController {
    config: SyncConfig,
    state: Mutex<State>,
}

#[uniffi::export]
impl SyncController {
    #[uniffi::constructor]
    pub fn new(config: SyncConfig) -> Result<Self, SyncError> {
        config.validate()?;
        Ok(Self {
            config,
            state: Mutex::new(State {
                account_state: AccountState::Disconnected,
                status: SyncStatus::Idle,
                enabled_engines: [
                    SyncEngine::Bookmarks,
                    SyncEngine::History,
                    SyncEngine::Tabs,
                    SyncEngine::Passwords,
                ]
                .into_iter()
                .collect(),
                schedule: Schedule::default(),
                vault_state: VaultState::Locked,
            }),
        })
    }

    pub fn account_domain(&self) -> Result<String, SyncError> {
        self.config.displayed_domain()
    }

    pub fn snapshot(&self) -> SyncSnapshot {
        let state = self.state.lock().expect("sync state mutex poisoned");
        SyncSnapshot {
            account_state: state.account_state,
            status: state.status,
            enabled_engines: state.enabled_engines.iter().copied().collect(),
            vault_state: state.vault_state,
            last_sync_epoch_seconds: state.schedule.last_sync_epoch_seconds,
            next_sync_allowed_epoch_seconds: state.schedule.next_sync_allowed_epoch_seconds,
        }
    }

    pub fn set_engine_enabled(&self, engine: SyncEngine, enabled: bool) {
        let mut state = self.state.lock().expect("sync state mutex poisoned");
        if enabled {
            state.enabled_engines.insert(engine);
        } else {
            state.enabled_engines.remove(&engine);
        }
    }

    pub fn mark_authenticating(&self) {
        self.state
            .lock()
            .expect("sync state mutex poisoned")
            .account_state = AccountState::Authenticating;
    }

    pub fn mark_connected(&self) {
        self.state
            .lock()
            .expect("sync state mutex poisoned")
            .account_state = AccountState::Connected;
    }

    pub fn mark_auth_issues(&self) {
        let mut state = self.state.lock().expect("sync state mutex poisoned");
        state.account_state = AccountState::AuthIssues;
        state.status = SyncStatus::AuthError;
        state.vault_state = VaultState::Locked;
    }

    pub fn disconnect(&self) {
        let mut state = self.state.lock().expect("sync state mutex poisoned");
        state.account_state = AccountState::Disconnected;
        state.status = SyncStatus::Idle;
        state.vault_state = VaultState::Locked;
        state.schedule = Schedule::default();
    }

    pub fn begin_sync(&self, now_epoch_seconds: u64) -> Result<Vec<SyncEngine>, SyncError> {
        let mut state = self.state.lock().expect("sync state mutex poisoned");
        if state.account_state != AccountState::Connected {
            return Err(SyncError::AuthenticationRequired);
        }
        if state.status == SyncStatus::Running {
            return Err(SyncError::Busy);
        }
        if let Some(until) = state.schedule.next_sync_allowed_epoch_seconds {
            if now_epoch_seconds < until {
                state.status = SyncStatus::BackedOff;
                return Err(SyncError::BackedOff(until));
            }
        }
        state.status = SyncStatus::Running;
        Ok(state.enabled_engines.iter().copied().collect())
    }

    pub fn complete_sync(
        &self,
        status: SyncStatus,
        now_epoch_seconds: u64,
        next_allowed_epoch_seconds: Option<u64>,
    ) {
        let mut state = self.state.lock().expect("sync state mutex poisoned");
        state.status = status;
        state.schedule.last_sync_epoch_seconds = Some(now_epoch_seconds);
        state.schedule.next_sync_allowed_epoch_seconds = next_allowed_epoch_seconds;
        state.schedule.pending_local_change_epoch_seconds = None;
    }

    pub fn record_local_change(&self, now_epoch_seconds: u64) {
        let mut state = self.state.lock().expect("sync state mutex poisoned");
        state.schedule.pending_local_change_epoch_seconds = Some(now_epoch_seconds);
    }

    pub fn sync_due(&self, reason: SyncReason, now_epoch_seconds: u64) -> bool {
        let state = self.state.lock().expect("sync state mutex poisoned");
        state.schedule.is_due(reason, now_epoch_seconds)
    }

    pub fn unlock_vault(&self, now_epoch_seconds: u64) {
        let mut state = self.state.lock().expect("sync state mutex poisoned");
        state.vault_state = VaultState::Unlocked {
            last_activity_epoch_seconds: now_epoch_seconds,
        };
    }

    pub fn touch_vault(&self, now_epoch_seconds: u64) -> Result<(), SyncError> {
        let mut state = self.state.lock().expect("sync state mutex poisoned");
        match &mut state.vault_state {
            VaultState::Locked => Err(SyncError::VaultLocked),
            VaultState::Unlocked {
                last_activity_epoch_seconds,
            } => {
                *last_activity_epoch_seconds = now_epoch_seconds;
                Ok(())
            }
        }
    }

    pub fn lock_vault(&self) {
        self.state
            .lock()
            .expect("sync state mutex poisoned")
            .vault_state = VaultState::Locked;
    }

    pub fn expire_vault(&self, now_epoch_seconds: u64) -> bool {
        let mut state = self.state.lock().expect("sync state mutex poisoned");
        if state.vault_state.is_expired(now_epoch_seconds) {
            state.vault_state = VaultState::Locked;
            return true;
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{AccountServer, DeviceKind};

    fn controller() -> SyncController {
        SyncController::new(SyncConfig {
            server: AccountServer::Mozilla,
            client_id: "test".into(),
            redirect_uri: "xanh-browser://oauth".into(),
            device_name: "test".into(),
            device_kind: DeviceKind::Desktop,
        })
        .unwrap()
    }

    #[test]
    fn all_engines_are_device_local_and_enabled_by_default() {
        let controller = controller();
        assert_eq!(controller.snapshot().enabled_engines.len(), 4);
        controller.set_engine_enabled(SyncEngine::Passwords, false);
        assert!(!controller
            .snapshot()
            .enabled_engines
            .contains(&SyncEngine::Passwords));
    }

    #[test]
    fn single_flight_and_backoff_are_enforced() {
        let controller = controller();
        controller.mark_connected();
        controller.begin_sync(10).unwrap();
        assert!(matches!(controller.begin_sync(10), Err(SyncError::Busy)));
        controller.complete_sync(SyncStatus::Success, 20, Some(100));
        assert!(matches!(
            controller.begin_sync(99),
            Err(SyncError::BackedOff(100))
        ));
        assert!(controller.begin_sync(100).is_ok());
    }
}
