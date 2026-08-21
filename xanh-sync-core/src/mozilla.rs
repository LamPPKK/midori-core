//! Production backend for Mozilla Application Services 155.0.
//!
//! The embedding application owns secure persistence. `account_json()` and
//! the local logins key are secrets and must only be stored in Keychain,
//! Keystore, DPAPI/Windows Hello, or Secret Service.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::UNIX_EPOCH;

use fxa_client::{
    DeviceConfig, FirefoxAccount, FxaConfig, FxaError, FxaEvent, FxaServer, FxaState,
};
use logins::encryption::{ManagedEncryptorDecryptor, StaticKeyManager};
use logins::LoginStore;
use places::{
    BookmarkItem as PlacesBookmarkItem, BookmarkPosition as PlacesBookmarkPosition,
    BookmarkType as PlacesBookmarkType, BookmarkUpdateInfo as PlacesBookmarkUpdateInfo,
    ConnectionType, Guid, InsertableBookmark as PlacesInsertableBookmark,
    InsertableBookmarkFolder as PlacesInsertableFolder,
    InsertableBookmarkItem as PlacesInsertableItem,
    InsertableBookmarkSeparator as PlacesInsertableSeparator, PlacesApi, PlacesConnection,
    PlacesDb, PlacesTimestamp, VisitObservation, VisitTransitionSet, VisitType,
};
use sync_manager::manager::SyncManager;
use sync_manager::{
    DeviceSettings, ServiceStatus, SyncAuthInfo, SyncEngineSelection, SyncParams,
    SyncReason as MozillaSyncReason,
};
use tabs::{ClientRemoteTabs, RemoteTabRecord, TabsDeviceType, TabsStore};
use url::Url;

use crate::{
    sanitized_title, sanitized_web_url, truncate, validate_bookmark_delete,
    validate_bookmark_update, validate_history_delete, validate_history_limit,
    validate_legacy_bookmarks, validate_local_history, validate_local_tabs, validate_new_bookmark,
    AccountServer, AccountState, BookmarkKind, BookmarkRecord, BookmarkRoot, BookmarkUpdate,
    DeviceKind, HistoryTransition, HistoryVisitRecord, LegacyBookmark, LegacyBookmarkImportResult,
    LocalHistoryUpdateResult, LocalHistoryVisit, LocalTab, LocalTabsUpdateResult, NewBookmark,
    RemoteDeviceKind, RemoteTab, RemoteTabsDevice, SyncConfig, SyncEngine, SyncError, SyncReason,
    SyncStatus, MAX_BOOKMARK_ITEMS, MAX_BOOKMARK_JSON_BYTES, MAX_DEVICE_ID_LENGTH,
    MAX_DEVICE_NAME_LENGTH, MAX_ICON_URL_LENGTH, MAX_PLACES_URL_LENGTH, MAX_REMOTE_DEVICES,
    MAX_REMOTE_TABS_PER_DEVICE, MAX_REMOTE_TABS_TOTAL, MAX_TITLE_LENGTH, MAX_URL_HISTORY,
    MAX_URL_LENGTH,
};

const SYNC_SCOPE: &str = "https://identity.mozilla.com/apps/oldsync";

// Application Services 155 keeps the registered Places, Tabs and Logins
// engines in process-global weak registries. A second live runtime would
// replace those registrations and could make account A sync profile B.
static MOZILLA_RUNTIME_ACTIVE: AtomicBool = AtomicBool::new(false);

struct MozillaRuntimeLease;

impl MozillaRuntimeLease {
    fn acquire() -> Result<Self, SyncError> {
        MOZILLA_RUNTIME_ACTIVE
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map(|_| Self)
            .map_err(|_| {
                SyncError::InvalidConfig(
                    "only one Mozilla Sync runtime may be open in a process".into(),
                )
            })
    }
}

impl Drop for MozillaRuntimeLease {
    fn drop(&mut self) {
        MOZILLA_RUNTIME_ACTIVE.store(false, Ordering::Release);
    }
}

/// Initializes NSS and the other process-wide services required by Mozilla
/// Application Services. The upstream initializer is safe to call more than
/// once, so every public construction path can enforce this precondition.
pub(crate) fn initialize_application_services() {
    init_rust_components::initialize();
}

/// Creates the random device-local key used to encrypt the Logins database.
/// Hosts must wrap this value with Keychain, Keystore, DPAPI or Secret Service
/// and must never write it to the profile directory.
#[uniffi::export]
pub fn generate_local_logins_key() -> Result<String, SyncError> {
    initialize_application_services();
    logins::encryption::create_key().map_err(backend_error)
}

pub struct MozillaBackend {
    config: SyncConfig,
    account: FirefoxAccount,
    account_state: AccountState,
    manager: SyncManager,
    profile_dir: PathBuf,
    places: Option<Arc<PlacesApi>>,
    places_writer: Option<Arc<PlacesConnection>>,
    places_reader: Option<PlacesDb>,
    logins: Option<Arc<LoginStore>>,
    tabs: Option<Arc<TabsStore>>,
    persisted_sync_state: Option<String>,
    _runtime_lease: MozillaRuntimeLease,
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

    pub fn create_bookmark(&self, item: NewBookmark) -> Result<String, SyncError> {
        self.backend()?.create_bookmark(item)
    }

    pub fn import_legacy_bookmarks(
        &self,
        bookmarks: Vec<LegacyBookmark>,
    ) -> Result<LegacyBookmarkImportResult, SyncError> {
        self.backend()?.import_legacy_bookmarks(bookmarks)
    }

    pub fn bookmark_tree(&self, root: BookmarkRoot) -> Result<Vec<BookmarkRecord>, SyncError> {
        self.backend()?.bookmark_tree(root)
    }

    pub fn update_bookmark(&self, update: BookmarkUpdate) -> Result<(), SyncError> {
        self.backend()?.update_bookmark(update)
    }

    pub fn delete_bookmark(&self, guid: String, is_private: bool) -> Result<bool, SyncError> {
        self.backend()?.delete_bookmark(guid, is_private)
    }

    pub fn record_history(
        &self,
        visits: Vec<LocalHistoryVisit>,
    ) -> Result<LocalHistoryUpdateResult, SyncError> {
        self.backend()?.record_history(visits)
    }

    pub fn recent_history(&self, limit: u32) -> Result<Vec<HistoryVisitRecord>, SyncError> {
        self.backend()?.recent_history(limit)
    }

    pub fn delete_history_visit(
        &self,
        url: String,
        visited_at_epoch_millis: i64,
    ) -> Result<(), SyncError> {
        self.backend()?
            .delete_history_visit(url, visited_at_epoch_millis)
    }

    pub fn clear_history(&self) -> Result<(), SyncError> {
        self.backend()?.clear_history()
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
        let runtime_lease = MozillaRuntimeLease::acquire()?;
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
        let places_writer = places
            .new_connection(ConnectionType::ReadWrite)
            .map_err(backend_error)?;
        let places_reader = places
            .open_connection(ConnectionType::ReadOnly)
            .map_err(backend_error)?;
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
            places_writer: Some(places_writer),
            places_reader: Some(places_reader),
            logins: None,
            tabs: Some(tabs),
            persisted_sync_state,
            _runtime_lease: runtime_lease,
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

    pub fn create_bookmark(&mut self, item: NewBookmark) -> Result<String, SyncError> {
        let item = validate_new_bookmark(item)?;
        let position = item.position.map_or(PlacesBookmarkPosition::Append, |pos| {
            PlacesBookmarkPosition::Specific { pos }
        });
        let parent_guid = Guid::new(&item.parent_guid);
        let date_added = item.date_added_epoch_millis.map(PlacesTimestamp);
        let last_modified = item.last_modified_epoch_millis.map(PlacesTimestamp);
        let places_item = match item.kind {
            BookmarkKind::Bookmark => PlacesInsertableItem::Bookmark {
                b: PlacesInsertableBookmark {
                    parent_guid,
                    position,
                    date_added,
                    last_modified,
                    guid: None,
                    url: Url::parse(item.url.as_deref().expect("validated bookmark URL"))
                        .map_err(backend_error)?,
                    title: item.title,
                },
            },
            BookmarkKind::Folder => PlacesInsertableItem::Folder {
                f: PlacesInsertableFolder {
                    parent_guid,
                    position,
                    date_added,
                    last_modified,
                    guid: None,
                    title: item.title,
                    children: vec![],
                },
            },
            BookmarkKind::Separator => PlacesInsertableItem::Separator {
                s: PlacesInsertableSeparator {
                    parent_guid,
                    position,
                    date_added,
                    last_modified,
                    guid: None,
                },
            },
        };
        self.places_writer()?
            .bookmarks_insert(places_item)
            .map(|guid| guid.as_str().to_owned())
            .map_err(backend_error)
    }

    pub fn import_legacy_bookmarks(
        &mut self,
        bookmarks: Vec<LegacyBookmark>,
    ) -> Result<LegacyBookmarkImportResult, SyncError> {
        let bookmarks = validate_legacy_bookmarks(bookmarks)?;
        let accepted_count = u32::try_from(bookmarks.len())
            .map_err(|_| SyncError::Migration("too many legacy bookmarks".into()))?;
        let writer = self.places_writer()?;
        let mut existing_count = 0u32;
        let mut created_count = 0u32;

        for bookmark in bookmarks {
            let existing = writer
                .bookmarks_get_all_with_url(bookmark.url.clone())
                .map_err(backend_error)?;
            if existing
                .iter()
                .any(|item| matches!(item, PlacesBookmarkItem::Bookmark { .. }))
            {
                existing_count = existing_count.saturating_add(1);
                continue;
            }
            writer
                .bookmarks_insert(PlacesInsertableItem::Bookmark {
                    b: PlacesInsertableBookmark {
                        parent_guid: Guid::new(&crate::bookmark_root_guid(BookmarkRoot::Unfiled)),
                        position: PlacesBookmarkPosition::Append,
                        date_added: Some(PlacesTimestamp(bookmark.created_at_epoch_millis)),
                        last_modified: Some(PlacesTimestamp(bookmark.created_at_epoch_millis)),
                        guid: None,
                        url: Url::parse(&bookmark.url).map_err(backend_error)?,
                        title: Some(bookmark.title),
                    },
                })
                .map_err(backend_error)?;
            created_count = created_count.saturating_add(1);
        }
        Ok(LegacyBookmarkImportResult {
            accepted_count,
            existing_count,
            created_count,
        })
    }

    pub fn bookmark_tree(&mut self, root: BookmarkRoot) -> Result<Vec<BookmarkRecord>, SyncError> {
        bounded_bookmark_tree(self.places_reader()?, &crate::bookmark_root_guid(root))
    }

    pub fn update_bookmark(&mut self, update: BookmarkUpdate) -> Result<(), SyncError> {
        let update = validate_bookmark_update(update)?;
        self.places_writer()?
            .bookmarks_update(PlacesBookmarkUpdateInfo {
                guid: Guid::new(&update.guid),
                title: update.title,
                url: update.url,
                parent_guid: update.parent_guid.map(|guid| Guid::new(&guid)),
                position: update.position,
            })
            .map_err(backend_error)
    }

    pub fn delete_bookmark(&mut self, guid: String, is_private: bool) -> Result<bool, SyncError> {
        let guid = validate_bookmark_delete(&guid, is_private)?;
        self.places_writer()?
            .bookmarks_delete(Guid::new(&guid))
            .map_err(backend_error)
    }

    pub fn record_history(
        &mut self,
        visits: Vec<LocalHistoryVisit>,
    ) -> Result<LocalHistoryUpdateResult, SyncError> {
        let (visits, result) = validate_local_history(visits)?;
        let writer = self.places_writer()?;
        for visit in visits {
            let timestamp = PlacesTimestamp(visit.visited_at_epoch_millis);
            let already_recorded = writer
                .get_visit_infos(timestamp, timestamp, VisitTransitionSet::empty())
                .map_err(backend_error)?
                .into_iter()
                .any(|existing| existing.url.as_str() == visit.url);
            if already_recorded {
                continue;
            }
            let observation = VisitObservation::new(Url::parse(&visit.url).map_err(backend_error)?)
                .with_title(visit.title)
                .with_visit_type(to_places_visit_type(visit.transition))
                .with_at(timestamp)
                .with_is_remote(false);
            writer
                .apply_observation(observation)
                .map_err(backend_error)?;
        }
        Ok(result)
    }

    pub fn recent_history(&mut self, limit: u32) -> Result<Vec<HistoryVisitRecord>, SyncError> {
        let limit = validate_history_limit(limit)?;
        let visits = self
            .places_writer()?
            .get_visit_page(0, i64::from(limit), VisitTransitionSet::empty())
            .map_err(backend_error)?;
        Ok(visits
            .into_iter()
            .filter(|visit| !visit.is_hidden)
            .filter_map(|visit| {
                let url = sanitized_web_url(visit.url.as_str(), MAX_PLACES_URL_LENGTH)?;
                let transition = from_places_visit_type(visit.visit_type)?;
                Some(HistoryVisitRecord {
                    url,
                    title: sanitized_title(visit.title),
                    visited_at_epoch_millis: i64::try_from(visit.timestamp.as_millis()).ok()?,
                    transition,
                    is_remote: visit.is_remote,
                })
            })
            .collect())
    }

    pub fn delete_history_visit(
        &mut self,
        url: String,
        visited_at_epoch_millis: i64,
    ) -> Result<(), SyncError> {
        let (url, timestamp) = validate_history_delete(&url, visited_at_epoch_millis)?;
        self.places_writer()?
            .delete_visit(url, PlacesTimestamp(timestamp))
            .map_err(backend_error)
    }

    pub fn clear_history(&mut self) -> Result<(), SyncError> {
        self.places_writer()?
            .delete_visits_between(PlacesTimestamp(0), PlacesTimestamp(i64::MAX as u64))
            .map_err(backend_error)
    }

    fn places_writer(&self) -> Result<&PlacesConnection, SyncError> {
        self.places_writer
            .as_deref()
            .ok_or_else(|| SyncError::Backend("local Places store was deleted".into()))
    }

    fn places_reader(&self) -> Result<&PlacesDb, SyncError> {
        self.places_reader
            .as_ref()
            .ok_or_else(|| SyncError::Backend("local Places store was deleted".into()))
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
        let token = match self.account.get_access_token(SYNC_SCOPE, false) {
            Ok(token) => token,
            Err(FxaError::Authentication | FxaError::SyncScopedKeyMissingInServerResponse) => {
                self.mark_auth_issues();
                return Ok((SyncStatus::AuthError, None));
            }
            Err(error) => return Err(backend_error(error)),
        };
        let key = match token.key {
            Some(key) => key,
            None => {
                self.mark_auth_issues();
                return Ok((SyncStatus::AuthError, None));
            }
        };
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
        if status == SyncStatus::AuthError {
            self.mark_auth_issues();
        }
        let next_allowed = result.next_sync_allowed_at.and_then(|time| {
            time.duration_since(UNIX_EPOCH)
                .ok()
                .map(|duration| duration.as_secs())
        });
        Ok((status, next_allowed))
    }

    fn mark_auth_issues(&mut self) {
        // Persist the upstream FxA transition directly so restart does not
        // silently turn a known authorization failure back into a connected
        // scheduler loop.
        self.account.on_auth_issues();
        self.account_state = AccountState::AuthIssues;
    }

    pub fn disconnect(&mut self, delete_local: bool) -> Result<(), SyncError> {
        // Disconnect is deliberately idempotent. Native hosts persist a
        // write-ahead removal intent and may repeat this operation after a
        // crash between FxA, database, and secure-storage cleanup phases.
        if self.account_state != AccountState::Disconnected {
            self.account
                .process_event(FxaEvent::Disconnect)
                .map_err(backend_error)?;
        }
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
            self.places_reader.take();
            self.places_writer.take();
            self.places.take();
            for database in ["places.sqlite", "logins.sqlite", "tabs.sqlite"] {
                for suffix in ["", "-wal", "-shm", "-journal"] {
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
        self.places_reader.take();
        self.places_writer.take();
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

fn bounded_bookmark_tree(db: &PlacesDb, root_guid: &str) -> Result<Vec<BookmarkRecord>, SyncError> {
    let mut records = Vec::new();
    let mut pending = vec![root_guid.to_owned()];
    let mut seen = HashSet::new();
    // JSON arrays add two brackets and one comma between records. Enforce the
    // same aggregate budget before pushing so typed UniFFI callers cannot
    // bypass the C ABI's post-serialization check.
    let mut serialized_bytes = 2usize;
    while let Some(guid) = pending.pop() {
        if records.len() >= MAX_BOOKMARK_ITEMS {
            return Err(SyncError::Backend(format!(
                "bookmark tree exceeds {MAX_BOOKMARK_ITEMS} records"
            )));
        }
        if !seen.insert(guid.clone()) {
            return Err(SyncError::Backend(
                "bookmark tree contains a repeated GUID".into(),
            ));
        }
        let (record, is_folder) = read_bookmark_record(db, &guid)?
            .ok_or_else(|| SyncError::Backend("Places bookmark item is missing".into()))?;
        let record_bytes = serde_json::to_vec(&record).map_err(backend_error)?.len();
        let separator_bytes = usize::from(!records.is_empty());
        serialized_bytes = serialized_bytes
            .checked_add(separator_bytes)
            .and_then(|size| size.checked_add(record_bytes))
            .filter(|size| *size <= MAX_BOOKMARK_JSON_BYTES)
            .ok_or_else(|| {
                SyncError::Backend(format!(
                    "bookmark tree JSON exceeds {MAX_BOOKMARK_JSON_BYTES} bytes"
                ))
            })?;
        records.push(record);
        if is_folder {
            let reserved = records.len() + pending.len();
            let available = MAX_BOOKMARK_ITEMS.checked_sub(reserved).ok_or_else(|| {
                SyncError::Backend(format!(
                    "bookmark tree exceeds {MAX_BOOKMARK_ITEMS} records"
                ))
            })?;
            let children = read_bookmark_children(db, &guid, available + 1)?;
            if children.len() > available {
                return Err(SyncError::Backend(format!(
                    "bookmark tree exceeds {MAX_BOOKMARK_ITEMS} records"
                )));
            }
            pending.extend(children.into_iter().rev());
        }
    }
    Ok(records)
}

fn read_bookmark_record(
    db: &PlacesDb,
    guid: &str,
) -> Result<Option<(BookmarkRecord, bool)>, SyncError> {
    let mut statement = db
        .prepare(
            "SELECT b.guid, p.guid, b.position, b.type, NULLIF(b.title, ''), \
                    b.dateAdded, b.lastModified, h.url \
             FROM moz_bookmarks b \
             LEFT JOIN moz_bookmarks p ON p.id = b.parent \
             LEFT JOIN moz_places h ON h.id = b.fk \
             WHERE b.guid = ?1 LIMIT 1",
        )
        .map_err(backend_error)?;
    let mut rows = statement.query([guid]).map_err(backend_error)?;
    let Some(row) = rows.next().map_err(backend_error)? else {
        return Ok(None);
    };
    let item_type: PlacesBookmarkType = row.get(3).map_err(backend_error)?;
    let raw_url: Option<String> = row.get(7).map_err(backend_error)?;
    let canonical_url = raw_url
        .as_deref()
        .and_then(|value| Url::parse(value).ok())
        .map(|url| url.to_string())
        .filter(|url| url.len() <= MAX_PLACES_URL_LENGTH);
    let is_openable = canonical_url
        .as_deref()
        .and_then(|url| sanitized_web_url(url, MAX_PLACES_URL_LENGTH))
        .is_some();
    let (kind, url) = match item_type {
        PlacesBookmarkType::Bookmark => (BookmarkKind::Bookmark, canonical_url),
        PlacesBookmarkType::Folder => (BookmarkKind::Folder, None),
        PlacesBookmarkType::Separator => (BookmarkKind::Separator, None),
    };
    Ok(Some((
        BookmarkRecord {
            guid: row.get(0).map_err(backend_error)?,
            parent_guid: row.get(1).map_err(backend_error)?,
            position: row.get(2).map_err(backend_error)?,
            kind,
            title: if item_type == PlacesBookmarkType::Separator {
                None
            } else {
                sanitized_title(row.get(4).map_err(backend_error)?)
            },
            url,
            is_openable: item_type == PlacesBookmarkType::Bookmark && is_openable,
            date_added_epoch_millis: row.get::<_, i64>(5).map_err(backend_error)?.max(0),
            last_modified_epoch_millis: row.get::<_, i64>(6).map_err(backend_error)?.max(0),
        },
        item_type == PlacesBookmarkType::Folder,
    )))
}

fn read_bookmark_children(
    db: &PlacesDb,
    parent_guid: &str,
    limit: usize,
) -> Result<Vec<String>, SyncError> {
    let sql = format!(
        "SELECT child.guid FROM moz_bookmarks child \
         WHERE child.parent = (SELECT parent.id FROM moz_bookmarks parent WHERE parent.guid = ?1) \
         ORDER BY child.position LIMIT {limit}"
    );
    let mut statement = db.prepare(&sql).map_err(backend_error)?;
    let rows = statement
        .query_map([parent_guid], |row| row.get(0))
        .map_err(backend_error)?;
    rows.collect::<Result<Vec<String>, _>>()
        .map_err(backend_error)
}

fn to_places_visit_type(transition: HistoryTransition) -> VisitType {
    match transition {
        HistoryTransition::Link => VisitType::Link,
        HistoryTransition::Typed => VisitType::Typed,
        HistoryTransition::Bookmark => VisitType::Bookmark,
        HistoryTransition::RedirectPermanent => VisitType::RedirectPermanent,
        HistoryTransition::RedirectTemporary => VisitType::RedirectTemporary,
        HistoryTransition::Download => VisitType::Download,
        HistoryTransition::Reload => VisitType::Reload,
    }
}

fn from_places_visit_type(transition: VisitType) -> Option<HistoryTransition> {
    match transition {
        VisitType::Link => Some(HistoryTransition::Link),
        VisitType::Typed => Some(HistoryTransition::Typed),
        VisitType::Bookmark => Some(HistoryTransition::Bookmark),
        VisitType::RedirectPermanent => Some(HistoryTransition::RedirectPermanent),
        VisitType::RedirectTemporary => Some(HistoryTransition::RedirectTemporary),
        VisitType::Download => Some(HistoryTransition::Download),
        VisitType::Reload => Some(HistoryTransition::Reload),
        VisitType::Embed | VisitType::FramedLink | VisitType::UpdatePlace => None,
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

    fn test_config() -> SyncConfig {
        SyncConfig {
            server: AccountServer::Mozilla,
            client_id: "xanh-places-test".into(),
            redirect_uri: "xanh-browser://accounts/oauth".into(),
            device_name: "Xanh Places Test".into(),
            device_kind: DeviceKind::Desktop,
        }
    }

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

    #[test]
    fn places_bookmarks_and_history_round_trip_through_the_production_backend() {
        let profile = tempfile::tempdir().unwrap();
        let mut backend =
            MozillaBackend::open(test_config(), profile.path(), None, None, None).unwrap();

        let legacy = LegacyBookmark {
            url: "https://example.com/legacy".into(),
            title: "Legacy".into(),
            created_at_epoch_millis: 1_700_000_000_000,
        };
        let first_import = backend
            .import_legacy_bookmarks(vec![legacy.clone()])
            .unwrap();
        assert_eq!(first_import.accepted_count, 1);
        assert_eq!(first_import.created_count, 1);
        assert_eq!(first_import.existing_count, 0);
        let retry_import = backend.import_legacy_bookmarks(vec![legacy]).unwrap();
        assert_eq!(retry_import.accepted_count, 1);
        assert_eq!(retry_import.created_count, 0);
        assert_eq!(retry_import.existing_count, 1);

        let folder_guid = backend
            .create_bookmark(NewBookmark {
                parent_guid: crate::bookmark_root_guid(BookmarkRoot::Unfiled),
                position: None,
                kind: BookmarkKind::Folder,
                title: Some("Imported".into()),
                url: None,
                date_added_epoch_millis: Some(1_700_000_000_000),
                last_modified_epoch_millis: Some(1_700_000_000_001),
                is_private: false,
            })
            .unwrap();
        let bookmark_guid = backend
            .create_bookmark(NewBookmark {
                parent_guid: folder_guid.clone(),
                position: None,
                kind: BookmarkKind::Bookmark,
                title: Some("Before".into()),
                url: Some("https://example.com/old".into()),
                date_added_epoch_millis: Some(1_700_000_000_002),
                last_modified_epoch_millis: Some(1_700_000_000_003),
                is_private: false,
            })
            .unwrap();
        backend
            .update_bookmark(BookmarkUpdate {
                guid: bookmark_guid.clone(),
                title: Some("After".into()),
                url: Some("https://ex\nample.com/new".into()),
                parent_guid: None,
                position: None,
                is_private: false,
            })
            .unwrap();

        let tree = backend.bookmark_tree(BookmarkRoot::Unfiled).unwrap();
        let bookmark = tree
            .iter()
            .find(|record| record.guid == bookmark_guid)
            .unwrap();
        assert_eq!(bookmark.title.as_deref(), Some("After"));
        assert_eq!(bookmark.url.as_deref(), Some("https://example.com/new"));
        assert!(bookmark.is_openable);

        let history_result = backend
            .record_history(vec![
                LocalHistoryVisit {
                    url: "https://example.com/regular".into(),
                    title: Some("Regular".into()),
                    visited_at_epoch_millis: 1_700_000_000_100,
                    transition: HistoryTransition::Typed,
                    is_private: false,
                },
                LocalHistoryVisit {
                    url: "https://example.com/private".into(),
                    title: Some("Private".into()),
                    visited_at_epoch_millis: 1_700_000_000_101,
                    transition: HistoryTransition::Link,
                    is_private: true,
                },
            ])
            .unwrap();
        assert_eq!(history_result.accepted_count, 1);
        assert_eq!(history_result.skipped_private_count, 1);
        let retry_result = backend
            .record_history(vec![LocalHistoryVisit {
                url: "https://example.com/regular".into(),
                title: Some("Regular".into()),
                visited_at_epoch_millis: 1_700_000_000_100,
                transition: HistoryTransition::Typed,
                is_private: false,
            }])
            .unwrap();
        assert_eq!(retry_result.accepted_count, 1);
        let history = backend.recent_history(10).unwrap();
        assert_eq!(history.len(), 1);
        assert_eq!(history[0].url, "https://example.com/regular");
        assert_eq!(history[0].transition, HistoryTransition::Typed);

        backend
            .delete_history_visit(history[0].url.clone(), history[0].visited_at_epoch_millis)
            .unwrap();
        assert!(backend.recent_history(10).unwrap().is_empty());
        backend
            .record_history(vec![
                LocalHistoryVisit {
                    url: "https://example.com/clear-me".into(),
                    title: Some("Clear me".into()),
                    visited_at_epoch_millis: 1_700_000_000_200,
                    transition: HistoryTransition::Link,
                    is_private: false,
                },
                LocalHistoryVisit {
                    url: "https://example.com/legacy-timestamp".into(),
                    title: Some("Legacy timestamp".into()),
                    visited_at_epoch_millis: 1_000,
                    transition: HistoryTransition::Link,
                    is_private: false,
                },
            ])
            .unwrap();
        backend.clear_history().unwrap();
        assert!(backend.recent_history(10).unwrap().is_empty());
        assert!(backend
            .delete_bookmark(bookmark_guid.clone(), true)
            .is_err());
        assert!(backend.delete_bookmark(bookmark_guid, false).unwrap());
        assert!(backend.delete_bookmark(folder_guid, false).unwrap());

        let mut parent_guid = crate::bookmark_root_guid(BookmarkRoot::Unfiled);
        let mut top_folder_guid = None;
        for depth in 0..128 {
            let guid = backend
                .create_bookmark(NewBookmark {
                    parent_guid,
                    position: None,
                    kind: BookmarkKind::Folder,
                    title: Some(format!("Depth {depth}")),
                    url: None,
                    date_added_epoch_millis: None,
                    last_modified_epoch_millis: None,
                    is_private: false,
                })
                .unwrap();
            top_folder_guid.get_or_insert_with(|| guid.clone());
            parent_guid = guid;
        }
        let deep_tree = backend.bookmark_tree(BookmarkRoot::Unfiled).unwrap();
        assert_eq!(deep_tree.len(), 129);
        assert!(backend
            .delete_bookmark(top_folder_guid.unwrap(), false)
            .unwrap());

        // A host may resume a durable Remove-from-device intent after the
        // first call changed FxA state or deleted only part of the stores.
        let rollback_journals: Vec<_> = ["places.sqlite", "logins.sqlite", "tabs.sqlite"]
            .into_iter()
            .map(|database| profile.path().join(format!("{database}-journal")))
            .collect();
        for journal in &rollback_journals {
            std::fs::write(journal, b"stale rollback page").unwrap();
        }
        backend.disconnect(true).unwrap();
        backend.disconnect(true).unwrap();
        assert!(rollback_journals.iter().all(|journal| !journal.exists()));

        let second_profile = tempfile::tempdir().unwrap();
        assert!(
            MozillaBackend::open(test_config(), second_profile.path(), None, None, None).is_err()
        );
        drop(backend);
        assert!(
            MozillaBackend::open(test_config(), second_profile.path(), None, None, None).is_ok()
        );
    }
}
