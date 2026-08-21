//! Production backend for Mozilla Application Services 155.0.
//!
//! The embedding application owns secure persistence. `account_json()` and
//! the local logins key are secrets and must only be stored in Keychain,
//! Keystore, DPAPI/Windows Hello, or Secret Service.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::UNIX_EPOCH;

use fxa_client::{DeviceConfig, FirefoxAccount, FxaConfig, FxaEvent, FxaServer, FxaState};
use logins::encryption::{ManagedEncryptorDecryptor, StaticKeyManager};
use logins::LoginStore;
use places::PlacesApi;
use sync_manager::manager::SyncManager;
use sync_manager::{
    DeviceSettings, ServiceStatus, SyncAuthInfo, SyncEngineSelection, SyncParams,
    SyncReason as MozillaSyncReason,
};
use tabs::{ClientRemoteTabs, RemoteTabRecord, TabsDeviceType, TabsStore};
use url::Url;

use crate::{
    sanitized_web_url, truncate, validate_local_tabs, AccountServer, AccountState, DeviceKind,
    LocalTab, LocalTabsUpdateResult, RemoteDeviceKind, RemoteTab, RemoteTabsDevice, SyncConfig,
    SyncEngine, SyncError, SyncReason, SyncStatus, MAX_DEVICE_ID_LENGTH, MAX_DEVICE_NAME_LENGTH,
    MAX_ICON_URL_LENGTH, MAX_REMOTE_DEVICES, MAX_REMOTE_TABS_PER_DEVICE, MAX_REMOTE_TABS_TOTAL,
    MAX_TITLE_LENGTH, MAX_URL_HISTORY, MAX_URL_LENGTH,
};

const SYNC_SCOPE: &str = "https://identity.mozilla.com/apps/oldsync";

/// Initializes NSS and the other process-wide services required by Mozilla
/// Application Services. The upstream initializer is safe to call more than
/// once, so every public construction path can enforce this precondition.
pub(crate) fn initialize_application_services() {
    init_rust_components::initialize();
}

pub struct MozillaBackend {
    config: SyncConfig,
    account: FirefoxAccount,
    account_state: AccountState,
    manager: SyncManager,
    profile_dir: PathBuf,
    places: Option<Arc<PlacesApi>>,
    logins: Option<Arc<LoginStore>>,
    tabs: Option<Arc<TabsStore>>,
    persisted_sync_state: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct MozillaSyncResult {
    pub status: SyncStatus,
    pub next_sync_allowed_epoch_seconds: Option<u64>,
}

/// UniFFI boundary used by Swift and Kotlin hosts that embed the native core.
/// Platform secure storage owns every string passed to or returned from this
/// object; none of it is written to disk by the binding layer.
#[derive(uniffi::Object)]
pub struct MozillaSyncRuntime {
    backend: Mutex<MozillaBackend>,
    sync_running: AtomicBool,
}

struct UniFfiSyncFlight<'a>(&'a AtomicBool);

impl Drop for UniFfiSyncFlight<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

#[uniffi::export]
impl MozillaSyncRuntime {
    #[uniffi::constructor]
    pub fn new(
        config: SyncConfig,
        profile_dir: String,
        local_logins_key: Option<String>,
        account_json: Option<String>,
        persisted_sync_state: Option<String>,
    ) -> Result<Self, SyncError> {
        Ok(Self {
            backend: Mutex::new(MozillaBackend::open(
                config,
                profile_dir,
                local_logins_key,
                account_json.as_deref(),
                persisted_sync_state,
            )?),
            sync_running: AtomicBool::new(false),
        })
    }

    pub fn initialize(&self) -> Result<AccountState, SyncError> {
        self.backend()?.initialize()
    }

    pub fn account_state(&self) -> Result<AccountState, SyncError> {
        Ok(self.backend()?.account_state())
    }

    pub fn begin_oauth(&self) -> Result<String, SyncError> {
        self.backend()?.begin_oauth()
    }

    pub fn complete_oauth(&self, code: String, state: String) -> Result<AccountState, SyncError> {
        self.backend()?.complete_oauth(code, state)
    }

    pub fn account_json(&self) -> Result<String, SyncError> {
        self.backend()?.account_json()
    }

    pub fn persisted_sync_state(&self) -> Result<Option<String>, SyncError> {
        Ok(self
            .backend()?
            .persisted_sync_state()
            .map(ToOwned::to_owned))
    }

    pub fn vault_unlocked(&self) -> Result<bool, SyncError> {
        Ok(self.backend()?.vault_unlocked())
    }

    pub fn unlock_vault(&self, local_logins_key: String) -> Result<(), SyncError> {
        self.backend()?.unlock_logins(local_logins_key)
    }

    pub fn lock_vault(&self) -> Result<(), SyncError> {
        self.backend()?.lock_logins();
        Ok(())
    }

    pub fn sync(
        &self,
        reason: SyncReason,
        engines: Vec<SyncEngine>,
    ) -> Result<MozillaSyncResult, SyncError> {
        if self
            .sync_running
            .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
            .is_err()
        {
            return Err(SyncError::Busy);
        }
        let _flight = UniFfiSyncFlight(&self.sync_running);
        let (status, next_sync_allowed_epoch_seconds) =
            self.backend()?.sync(reason, &engines, HashMap::new())?;
        Ok(MozillaSyncResult {
            status,
            next_sync_allowed_epoch_seconds,
        })
    }

    pub fn update_local_tabs(
        &self,
        tabs: Vec<LocalTab>,
    ) -> Result<LocalTabsUpdateResult, SyncError> {
        self.backend()?.update_local_tabs(tabs)
    }

    pub fn remote_tabs(&self) -> Result<Vec<RemoteTabsDevice>, SyncError> {
        self.backend()?.remote_tabs()
    }

    pub fn disconnect(&self, delete_local: bool) -> Result<(), SyncError> {
        self.backend()?.disconnect(delete_local)
    }
}

impl MozillaSyncRuntime {
    fn backend(&self) -> Result<std::sync::MutexGuard<'_, MozillaBackend>, SyncError> {
        self.backend
            .lock()
            .map_err(|_| SyncError::Backend("runtime state is unavailable".into()))
    }
}

impl MozillaBackend {
    pub fn open(
        config: SyncConfig,
        profile_dir: impl AsRef<Path>,
        local_logins_key: Option<String>,
        account_json: Option<&str>,
        persisted_sync_state: Option<String>,
    ) -> Result<Self, SyncError> {
        initialize_application_services();
        config.validate()?;
        let fxa_config = to_fxa_config(&config)?;
        let account = if let Some(serialized) = account_json {
            validate_persisted_account_identity(serialized, &fxa_config)?;
            let account = FirefoxAccount::from_json(serialized).map_err(backend_error)?;
            if !account
                .matches_server(&fxa_config.server)
                .map_err(backend_error)?
            {
                return Err(SyncError::InvalidConfig(
                    "stored account belongs to a different server".into(),
                ));
            }
            account
        } else {
            FirefoxAccount::new(fxa_config)
        };
        let profile_dir = profile_dir.as_ref().to_path_buf();
        std::fs::create_dir_all(&profile_dir).map_err(backend_error)?;
        let places = PlacesApi::new(profile_dir.join("places.sqlite")).map_err(backend_error)?;
        let tabs = Arc::new(TabsStore::new(profile_dir.join("tabs.sqlite")));
        places.clone().register_with_sync_manager();
        tabs.clone().register_with_sync_manager();
        let mut backend = Self {
            config,
            account,
            account_state: AccountState::Disconnected,
            manager: SyncManager::new(),
            profile_dir,
            places: Some(places),
            logins: None,
            tabs: Some(tabs),
            persisted_sync_state,
        };
        if let Some(key) = local_logins_key {
            backend.unlock_logins(key)?;
        }
        Ok(backend)
    }

    pub fn initialize(&mut self) -> Result<AccountState, SyncError> {
        let state = self
            .account
            .process_event(FxaEvent::Initialize {
                device_config: DeviceConfig {
                    name: self.config.device_name.clone(),
                    device_type: to_device_type(self.config.device_kind),
                    capabilities: vec![],
                },
            })
            .map_err(backend_error)?;
        self.account_state = to_account_state(&state);
        Ok(self.account_state)
    }

    pub fn begin_oauth(&mut self) -> Result<String, SyncError> {
        match self
            .account
            .process_event(FxaEvent::BeginOAuthFlow {
                service: String::new(),
                scopes: vec![SYNC_SCOPE.into(), "profile".into()],
                entrypoint: "xanh-browser-sync".into(),
            })
            .map_err(backend_error)?
        {
            FxaState::Authenticating { oauth_url, .. } => {
                self.account_state = AccountState::Authenticating;
                Ok(oauth_url)
            }
            state => Err(SyncError::Backend(format!(
                "unexpected OAuth state: {state:?}"
            ))),
        }
    }

    pub fn complete_oauth(
        &mut self,
        code: String,
        state: String,
    ) -> Result<AccountState, SyncError> {
        let state = self
            .account
            .process_event(FxaEvent::CompleteOAuthFlow { code, state })
            .map_err(backend_error)?;
        self.account_state = to_account_state(&state);
        Ok(self.account_state)
    }

    pub fn account_json(&self) -> Result<String, SyncError> {
        self.account.to_json().map_err(backend_error)
    }

    pub fn persisted_sync_state(&self) -> Option<&str> {
        self.persisted_sync_state.as_deref()
    }

    pub fn account_state(&self) -> AccountState {
        self.account_state
    }

    pub fn vault_unlocked(&self) -> bool {
        self.logins.is_some()
    }

    pub fn unlock_logins(&mut self, key: String) -> Result<(), SyncError> {
        if self.logins.is_some() {
            return Ok(());
        }
        if key.is_empty() {
            return Err(SyncError::InvalidConfig("local Logins key is empty".into()));
        }
        let encryptor = Arc::new(ManagedEncryptorDecryptor::new(Arc::new(
            StaticKeyManager::new(key),
        )));
        let logins = Arc::new(
            LoginStore::new(self.profile_dir.join("logins.sqlite"), encryptor)
                .map_err(backend_error)?,
        );
        logins.clone().register_with_sync_manager();
        self.logins = Some(logins);
        Ok(())
    }

    pub fn lock_logins(&mut self) {
        if let Some(logins) = self.logins.take() {
            logins.shutdown();
        }
    }

    pub fn update_local_tabs(
        &mut self,
        tabs: Vec<LocalTab>,
    ) -> Result<LocalTabsUpdateResult, SyncError> {
        let (tabs, result) = validate_local_tabs(tabs)?;
        let store = self
            .tabs
            .as_ref()
            .ok_or_else(|| SyncError::Backend("local Tabs store was deleted".into()))?;
        store.set_local_tabs(
            tabs.into_iter()
                .map(|tab| RemoteTabRecord {
                    title: tab.title,
                    url_history: tab.url_history,
                    icon: tab.icon_url,
                    last_used: tab.last_used_epoch_millis,
                    inactive: false,
                    pinned: tab.is_pinned,
                    index: tab.index,
                    window_id: String::new(),
                    tab_group_id: String::new(),
                })
                .collect(),
        );
        Ok(result)
    }

    pub fn remote_tabs(&mut self) -> Result<Vec<RemoteTabsDevice>, SyncError> {
        let store = self
            .tabs
            .as_ref()
            .ok_or_else(|| SyncError::Backend("local Tabs store was deleted".into()))?;
        Ok(sanitize_remote_tabs(
            store.remote_tabs().unwrap_or_default(),
        ))
    }

    pub fn sync(
        &mut self,
        reason: SyncReason,
        engines: &[SyncEngine],
        local_encryption_keys: HashMap<String, String>,
    ) -> Result<(SyncStatus, Option<u64>), SyncError> {
        if self.places.is_none() || self.tabs.is_none() {
            return Err(SyncError::Backend("local Sync stores were deleted".into()));
        }
        let token = self
            .account
            .get_access_token(SYNC_SCOPE, false)
            .map_err(backend_error)?;
        let key = token.key.ok_or(SyncError::AuthenticationRequired)?;
        let tokenserver_url = Url::parse(
            &self
                .account
                .get_token_server_endpoint_url()
                .map_err(backend_error)?,
        )
        .map_err(backend_error)?;
        if tokenserver_url.scheme() != "https" {
            return Err(SyncError::InvalidConfig("token server is not HTTPS".into()));
        }
        let result = self
            .manager
            .sync(SyncParams {
                reason: to_sync_reason(reason),
                engines: SyncEngineSelection::Some {
                    engines: engines
                        .iter()
                        .filter(|engine| **engine != SyncEngine::Passwords || self.logins.is_some())
                        .map(|engine| engine.service_name().to_owned())
                        .collect(),
                },
                // Engine switches are local-only by design; do not modify the
                // account-global declined engine list.
                enabled_changes: HashMap::new(),
                local_encryption_keys,
                auth_info: SyncAuthInfo {
                    kid: key.kid,
                    fxa_access_token: token.token,
                    sync_key: key.k,
                    tokenserver_url: tokenserver_url.to_string(),
                },
                persisted_state: self.persisted_sync_state.take(),
                device_settings: DeviceSettings {
                    fxa_device_id: self
                        .account
                        .get_current_device_id()
                        .map_err(backend_error)?,
                    name: self.config.device_name.clone(),
                    kind: to_device_type(self.config.device_kind),
                },
            })
            .map_err(backend_error)?;
        self.persisted_sync_state = Some(result.persisted_state);
        let status = match result.status {
            ServiceStatus::Ok if result.failures.is_empty() => SyncStatus::Success,
            ServiceStatus::Ok => SyncStatus::Partial,
            ServiceStatus::NetworkError | ServiceStatus::ServiceError => SyncStatus::NetworkError,
            ServiceStatus::AuthError => SyncStatus::AuthError,
            ServiceStatus::BackedOff => SyncStatus::BackedOff,
            ServiceStatus::OtherError => SyncStatus::Partial,
        };
        let next_allowed = result.next_sync_allowed_at.and_then(|time| {
            time.duration_since(UNIX_EPOCH)
                .ok()
                .map(|duration| duration.as_secs())
        });
        Ok((status, next_allowed))
    }

    pub fn disconnect(&mut self, delete_local: bool) -> Result<(), SyncError> {
        self.account
            .process_event(FxaEvent::Disconnect)
            .map_err(backend_error)?;
        self.manager.disconnect();
        self.persisted_sync_state = None;
        self.account_state = AccountState::Disconnected;
        if delete_local {
            if let Some(logins) = self.logins.as_ref() {
                logins.wipe_local().map_err(backend_error)?;
            }
            self.lock_logins();
            if let Some(tabs) = self.tabs.take() {
                tabs.close_connection();
            }
            self.places.take();
            for database in ["places.sqlite", "logins.sqlite", "tabs.sqlite"] {
                for suffix in ["", "-wal", "-shm"] {
                    let path = self.profile_dir.join(format!("{database}{suffix}"));
                    if let Err(error) = std::fs::remove_file(&path) {
                        if error.kind() != std::io::ErrorKind::NotFound {
                            return Err(SyncError::Backend(format!(
                                "failed to remove local Sync database {}",
                                path.display()
                            )));
                        }
                    }
                }
            }
        }
        Ok(())
    }
}

impl Drop for MozillaBackend {
    fn drop(&mut self) {
        self.lock_logins();
        if let Some(tabs) = self.tabs.take() {
            tabs.close_connection();
        }
        self.places.take();
    }
}

fn to_fxa_config(config: &SyncConfig) -> Result<FxaConfig, SyncError> {
    let server = match &config.server {
        AccountServer::Mozilla => FxaServer::Release,
        AccountServer::SelfHosted {
            accounts_url,
            token_server_url: _,
        } => FxaServer::Custom {
            url: accounts_url.clone(),
        },
    };
    let token_server_url_override = match &config.server {
        AccountServer::Mozilla => None,
        AccountServer::SelfHosted {
            token_server_url, ..
        } => Some(token_server_url.clone()),
    };
    Ok(FxaConfig {
        server,
        client_id: config.client_id.clone(),
        redirect_uri: config.redirect_uri.clone(),
        token_server_url_override,
    })
}

fn validate_persisted_account_identity(
    serialized: &str,
    expected: &FxaConfig,
) -> Result<(), SyncError> {
    let value: serde_json::Value = serde_json::from_str(serialized).map_err(backend_error)?;
    let stored = value.get("config").and_then(serde_json::Value::as_object);
    let string = |name: &str| {
        stored
            .and_then(|config| config.get(name))
            .and_then(serde_json::Value::as_str)
    };
    let stored_token = stored
        .and_then(|config| config.get("token_server_url_override"))
        .and_then(serde_json::Value::as_str);
    let matches = string("client_id") == Some(expected.client_id.as_str())
        && string("redirect_uri") == Some(expected.redirect_uri.as_str())
        && string("content_url") == Some(expected.server.content_url())
        && stored_token == expected.token_server_url_override.as_deref();
    if !matches {
        return Err(SyncError::InvalidConfig(
            "persisted account belongs to a different application identity".into(),
        ));
    }
    Ok(())
}

fn to_account_state(state: &FxaState) -> AccountState {
    match state {
        FxaState::Connected => AccountState::Connected,
        FxaState::Authenticating { .. } => AccountState::Authenticating,
        FxaState::AuthIssues => AccountState::AuthIssues,
        FxaState::Disconnected | FxaState::Uninitialized => AccountState::Disconnected,
    }
}

fn to_sync_reason(reason: SyncReason) -> MozillaSyncReason {
    match reason {
        SyncReason::Startup => MozillaSyncReason::Startup,
        SyncReason::Manual => MozillaSyncReason::User,
        SyncReason::Scheduled | SyncReason::LocalChange => MozillaSyncReason::Scheduled,
        SyncReason::PreSleep => MozillaSyncReason::PreSleep,
    }
}

fn to_device_type(kind: DeviceKind) -> fxa_client::DeviceType {
    match kind {
        DeviceKind::Desktop => fxa_client::DeviceType::Desktop,
        DeviceKind::Mobile => fxa_client::DeviceType::Mobile,
        DeviceKind::Tablet => fxa_client::DeviceType::Tablet,
        DeviceKind::Tv => fxa_client::DeviceType::TV,
        DeviceKind::Vr => fxa_client::DeviceType::VR,
    }
}

fn sanitize_remote_tabs(devices: Vec<ClientRemoteTabs>) -> Vec<RemoteTabsDevice> {
    let mut remaining_tabs = MAX_REMOTE_TABS_TOTAL;
    let mut sanitized: Vec<_> = devices
        .into_iter()
        .take(MAX_REMOTE_DEVICES)
        .filter(|device| {
            !device.client_id.is_empty() && device.client_id.len() <= MAX_DEVICE_ID_LENGTH
        })
        .filter_map(|device| {
            if remaining_tabs == 0 {
                return None;
            }
            let tabs: Vec<_> = device
                .remote_tabs
                .into_iter()
                .take(MAX_REMOTE_TABS_PER_DEVICE.min(remaining_tabs))
                .filter_map(|tab| {
                    let url_history: Vec<_> = tab
                        .url_history
                        .iter()
                        .take(MAX_URL_HISTORY)
                        .filter_map(|url| sanitized_web_url(url, MAX_URL_LENGTH))
                        .collect();
                    if url_history.is_empty() {
                        return None;
                    }
                    Some(RemoteTab {
                        title: truncate(&tab.title, MAX_TITLE_LENGTH),
                        url_history,
                        icon_url: tab
                            .icon
                            .as_deref()
                            .and_then(|url| sanitized_web_url(url, MAX_ICON_URL_LENGTH)),
                        last_used_epoch_millis: tab.last_used.max(0),
                        is_pinned: tab.pinned,
                    })
                })
                .collect();
            if tabs.is_empty() {
                return None;
            }
            remaining_tabs -= tabs.len();
            Some(RemoteTabsDevice {
                device_id: device.client_id,
                device_name: truncate(&device.client_name, MAX_DEVICE_NAME_LENGTH),
                device_kind: match device.device_type {
                    TabsDeviceType::Desktop => RemoteDeviceKind::Desktop,
                    TabsDeviceType::Mobile => RemoteDeviceKind::Mobile,
                    TabsDeviceType::Tablet => RemoteDeviceKind::Tablet,
                    TabsDeviceType::TV => RemoteDeviceKind::Tv,
                    TabsDeviceType::VR => RemoteDeviceKind::Vr,
                    TabsDeviceType::Unknown => RemoteDeviceKind::Unknown,
                },
                last_modified_epoch_millis: device.last_modified.max(0),
                tabs,
            })
        })
        .collect();
    sanitized.sort_by(|left, right| {
        right
            .last_modified_epoch_millis
            .cmp(&left.last_modified_epoch_millis)
            .then_with(|| left.device_name.cmp(&right.device_name))
            .then_with(|| left.device_id.cmp(&right.device_id))
    });
    sanitized
}

fn backend_error(error: impl std::fmt::Display) -> SyncError {
    SyncError::Backend(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn upstream_tab(urls: &[&str]) -> RemoteTabRecord {
        RemoteTabRecord {
            title: "Remote".into(),
            url_history: urls.iter().map(|url| (*url).to_owned()).collect(),
            icon: Some("javascript:alert(1)".into()),
            last_used: -1,
            inactive: false,
            pinned: true,
            index: 0,
            window_id: String::new(),
            tab_group_id: String::new(),
        }
    }

    fn upstream_device(
        id: &str,
        name: &str,
        last_modified: i64,
        tabs: Vec<RemoteTabRecord>,
    ) -> ClientRemoteTabs {
        ClientRemoteTabs {
            client_id: id.into(),
            client_name: name.into(),
            device_type: TabsDeviceType::Desktop,
            last_modified,
            remote_tabs: tabs,
            tab_groups: HashMap::new(),
            windows: HashMap::new(),
        }
    }

    #[test]
    fn remote_tabs_are_sanitized_grouped_and_sorted_without_navigation() {
        let devices = vec![
            upstream_device(
                "older",
                "Desktop B",
                100,
                vec![upstream_tab(&["file:///secret"])],
            ),
            upstream_device(
                "newer",
                "Desktop A",
                200,
                vec![upstream_tab(&[
                    "javascript:alert(1)",
                    "https://example.com/allowed",
                ])],
            ),
        ];

        let result = sanitize_remote_tabs(devices);

        assert_eq!(result.len(), 1);
        assert_eq!(result[0].device_id, "newer");
        assert_eq!(result[0].tabs.len(), 1);
        assert_eq!(
            result[0].tabs[0].url_history,
            ["https://example.com/allowed"]
        );
        assert_eq!(result[0].tabs[0].icon_url, None);
        assert_eq!(result[0].tabs[0].last_used_epoch_millis, 0);
        assert!(result[0].tabs[0].is_pinned);
    }

    #[test]
    fn remote_output_has_a_global_tab_limit() {
        let tabs = vec![upstream_tab(&["https://example.com/allowed"]); MAX_REMOTE_TABS_TOTAL + 1];

        let result = sanitize_remote_tabs(vec![upstream_device("device", "Desktop", 1, tabs)]);

        assert_eq!(result.len(), 1);
        assert_eq!(result[0].tabs.len(), MAX_REMOTE_TABS_TOTAL);
    }
}
