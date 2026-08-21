use std::cell::RefCell;
use std::ffi::{c_char, c_void, CStr, CString};
use std::ptr;
#[cfg(feature = "mozilla")]
use std::sync::atomic::{AtomicBool, Ordering};
#[cfg(feature = "mozilla")]
use std::sync::{Mutex, MutexGuard};

use crate::{
    credential_access_allowed, BookmarkRoot, CredentialContext, VaultState, XANH_SYNC_CORE_VERSION,
};

#[cfg(feature = "mozilla")]
use crate::{
    AccountState, BookmarkUpdate, LocalHistoryVisit, LocalTab, NewBookmark, SyncEngine, SyncReason,
    MAX_BOOKMARK_JSON_BYTES, MAX_BOOKMARK_MUTATION_JSON_BYTES, MAX_HISTORY_INPUT_JSON_BYTES,
    MAX_HISTORY_OUTPUT_JSON_BYTES, MAX_LOCAL_TABS_JSON_BYTES, MAX_REMOTE_TABS_JSON_BYTES,
};
#[cfg(feature = "mozilla")]
use std::collections::HashMap;

thread_local! {
    static LAST_ERROR: RefCell<Option<CString>> = const { RefCell::new(None) };
}

fn set_last_error(error: impl std::fmt::Display) {
    let raw = error.to_string().replace('\0', " ");
    let lowercase = raw.to_ascii_lowercase();
    // Upstream failures can contain server-provided detail. Never expose a
    // value that might include an OAuth code, bearer token, or scoped key to a
    // platform logger; configuration/policy errors remain actionable.
    let value = if ["backend", "oauth", "token", "authorization", "scoped key"]
        .iter()
        .any(|needle| lowercase.contains(needle))
    {
        "Mozilla Application Services operation failed".to_owned()
    } else {
        raw.chars().take(512).collect()
    };
    LAST_ERROR.with(|slot| *slot.borrow_mut() = CString::new(value).ok());
}

fn owned_string(value: impl AsRef<str>) -> *mut c_char {
    CString::new(value.as_ref().replace('\0', " "))
        .map(CString::into_raw)
        .unwrap_or(ptr::null_mut())
}

#[cfg(feature = "mozilla")]
unsafe fn required_string(value: *const c_char, name: &str) -> Result<String, String> {
    if value.is_null() {
        return Err(format!("{name} is null"));
    }
    // SAFETY: validated non-null above; the ABI requires NUL termination.
    unsafe { CStr::from_ptr(value) }
        .to_str()
        .map(ToOwned::to_owned)
        .map_err(|_| format!("{name} is not UTF-8"))
}

#[cfg(feature = "mozilla")]
unsafe fn optional_string(value: *const c_char) -> Result<Option<String>, String> {
    if value.is_null() {
        Ok(None)
    } else {
        // SAFETY: validated non-null above; the ABI requires NUL termination.
        unsafe { CStr::from_ptr(value) }
            .to_str()
            .map(|value| Some(value.to_owned()))
            .map_err(|_| "optional string is not UTF-8".into())
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_core_version() -> *mut c_char {
    CString::new(XANH_SYNC_CORE_VERSION)
        .expect("version cannot contain NUL")
        .into_raw()
}

#[no_mangle]
pub extern "C" fn xanh_sync_string_free(value: *mut c_char) {
    if !value.is_null() {
        // SAFETY: callers must only pass pointers returned by this library.
        unsafe { drop(CString::from_raw(value)) };
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_credential_access_allowed(
    context_json: *const c_char,
    vault_unlocked: bool,
) -> bool {
    if context_json.is_null() {
        return false;
    }
    // SAFETY: the C contract requires a valid NUL-terminated UTF-8 buffer.
    let Ok(json) = unsafe { CStr::from_ptr(context_json) }.to_str() else {
        return false;
    };
    let Ok(context) = serde_json::from_str::<CredentialContext>(json) else {
        return false;
    };
    let vault = if vault_unlocked {
        VaultState::Unlocked {
            last_activity_epoch_seconds: 0,
        }
    } else {
        VaultState::Locked
    };
    credential_access_allowed(&context, vault)
}

#[no_mangle]
pub extern "C" fn xanh_sync_null_string() -> *const c_char {
    ptr::null()
}

#[no_mangle]
pub extern "C" fn xanh_sync_last_error() -> *mut c_char {
    LAST_ERROR.with(|slot| {
        slot.borrow()
            .as_ref()
            .map(|value| owned_string(value.to_string_lossy()))
            .unwrap_or(ptr::null_mut())
    })
}

#[no_mangle]
pub extern "C" fn xanh_sync_generate_local_logins_key() -> *mut c_char {
    #[cfg(feature = "mozilla")]
    {
        crate::mozilla::initialize_application_services();
        match logins::encryption::create_key() {
            Ok(key) => owned_string(key),
            Err(error) => {
                set_last_error(error);
                ptr::null_mut()
            }
        }
    }
    #[cfg(not(feature = "mozilla"))]
    {
        set_last_error("xanh-sync-core was built without the mozilla feature");
        ptr::null_mut()
    }
}

#[cfg(feature = "mozilla")]
type Runtime = crate::mozilla::MozillaBackend;

#[cfg(not(feature = "mozilla"))]
struct Runtime;

#[cfg(feature = "mozilla")]
struct RuntimeHandle {
    runtime: Mutex<Runtime>,
    sync_running: AtomicBool,
}

#[cfg(not(feature = "mozilla"))]
type RuntimeHandle = Runtime;

#[cfg(feature = "mozilla")]
unsafe fn lock_runtime<'a>(runtime: *mut c_void) -> Result<MutexGuard<'a, Runtime>, String> {
    let handle = unsafe { runtime_handle(runtime) }?;
    handle
        .runtime
        .lock()
        .map_err(|_| "runtime lock is poisoned".into())
}

#[cfg(feature = "mozilla")]
unsafe fn runtime_handle<'a>(runtime: *mut c_void) -> Result<&'a RuntimeHandle, String> {
    unsafe { runtime.cast::<RuntimeHandle>().as_ref() }.ok_or_else(|| "runtime is null".to_owned())
}

#[cfg(feature = "mozilla")]
struct SyncFlight<'a>(&'a AtomicBool);

#[cfg(feature = "mozilla")]
impl Drop for SyncFlight<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_runtime_open(
    config_json: *const c_char,
    profile_dir: *const c_char,
    local_logins_key: *const c_char,
    account_json: *const c_char,
    persisted_sync_state: *const c_char,
) -> *mut c_void {
    #[cfg(feature = "mozilla")]
    {
        let result = (|| {
            // SAFETY: all pointer validation is centralized in these helpers.
            let config_json = unsafe { required_string(config_json, "config_json") }?;
            let profile_dir = unsafe { required_string(profile_dir, "profile_dir") }?;
            let key = unsafe { optional_string(local_logins_key) }?;
            let account = unsafe { optional_string(account_json) }?;
            let sync_state = unsafe { optional_string(persisted_sync_state) }?;
            let config = serde_json::from_str(&config_json).map_err(|error| error.to_string())?;
            Runtime::open(config, profile_dir, key, account.as_deref(), sync_state)
                .map_err(|error| error.to_string())
        })();
        match result {
            Ok(runtime) => Box::into_raw(Box::new(RuntimeHandle {
                runtime: Mutex::new(runtime),
                sync_running: AtomicBool::new(false),
            }))
            .cast(),
            Err(error) => {
                set_last_error(error);
                ptr::null_mut()
            }
        }
    }
    #[cfg(not(feature = "mozilla"))]
    {
        let _ = (
            config_json,
            profile_dir,
            local_logins_key,
            account_json,
            persisted_sync_state,
        );
        set_last_error("xanh-sync-core was built without the mozilla feature");
        ptr::null_mut()
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_runtime_free(runtime: *mut c_void) {
    if runtime.is_null() {
        return;
    }
    // SAFETY: this pointer must originate from `xanh_sync_runtime_open` and be
    // released exactly once by the embedding application.
    unsafe { drop(Box::from_raw(runtime.cast::<RuntimeHandle>())) };
}

#[no_mangle]
pub extern "C" fn xanh_sync_runtime_initialize(runtime: *mut c_void) -> i32 {
    #[cfg(feature = "mozilla")]
    {
        let runtime = unsafe { lock_runtime(runtime) };
        match runtime
            .and_then(|mut runtime| runtime.initialize().map_err(|error| error.to_string()))
        {
            Ok(state) => account_state_code(state),
            Err(error) => {
                set_last_error(error);
                -1
            }
        }
    }
    #[cfg(not(feature = "mozilla"))]
    {
        let _ = runtime;
        set_last_error("xanh-sync-core was built without the mozilla feature");
        -1
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_runtime_begin_oauth(runtime: *mut c_void) -> *mut c_char {
    #[cfg(feature = "mozilla")]
    {
        let runtime = unsafe { lock_runtime(runtime) };
        match runtime
            .and_then(|mut runtime| runtime.begin_oauth().map_err(|error| error.to_string()))
        {
            Ok(url) => owned_string(url),
            Err(error) => {
                set_last_error(error);
                ptr::null_mut()
            }
        }
    }
    #[cfg(not(feature = "mozilla"))]
    {
        let _ = runtime;
        set_last_error("xanh-sync-core was built without the mozilla feature");
        ptr::null_mut()
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_runtime_complete_oauth(
    runtime: *mut c_void,
    code: *const c_char,
    state: *const c_char,
) -> i32 {
    #[cfg(feature = "mozilla")]
    {
        let result = (|| {
            let mut runtime = unsafe { lock_runtime(runtime) }?;
            // SAFETY: pointer validation is centralized in `required_string`.
            let code = unsafe { required_string(code, "code") }?;
            let state = unsafe { required_string(state, "state") }?;
            runtime
                .complete_oauth(code, state)
                .map(account_state_code)
                .map_err(|error| error.to_string())
        })();
        match result {
            Ok(value) => value,
            Err(error) => {
                set_last_error(error);
                -1
            }
        }
    }
    #[cfg(not(feature = "mozilla"))]
    {
        let _ = (runtime, code, state);
        set_last_error("xanh-sync-core was built without the mozilla feature");
        -1
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_runtime_account_json(runtime: *mut c_void) -> *mut c_char {
    #[cfg(feature = "mozilla")]
    {
        let runtime = unsafe { lock_runtime(runtime) };
        match runtime.and_then(|runtime| runtime.account_json().map_err(|error| error.to_string()))
        {
            Ok(value) => owned_string(value),
            Err(error) => {
                set_last_error(error);
                ptr::null_mut()
            }
        }
    }
    #[cfg(not(feature = "mozilla"))]
    {
        let _ = runtime;
        set_last_error("xanh-sync-core was built without the mozilla feature");
        ptr::null_mut()
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_runtime_persisted_state(runtime: *mut c_void) -> *mut c_char {
    #[cfg(feature = "mozilla")]
    {
        let runtime = unsafe { lock_runtime(runtime) };
        match runtime {
            Ok(runtime) => runtime
                .persisted_sync_state()
                .map(owned_string)
                .unwrap_or(ptr::null_mut()),
            Err(error) => {
                set_last_error(error);
                ptr::null_mut()
            }
        }
    }
    #[cfg(not(feature = "mozilla"))]
    {
        let _ = runtime;
        ptr::null_mut()
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_runtime_sync(
    runtime: *mut c_void,
    reason: i32,
    engines_json: *const c_char,
) -> *mut c_char {
    #[cfg(feature = "mozilla")]
    {
        let result = (|| {
            let handle = unsafe { runtime_handle(runtime) }?;
            if handle
                .sync_running
                .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
                .is_err()
            {
                return Err("a sync is already running".to_owned());
            }
            let _flight = SyncFlight(&handle.sync_running);
            let mut runtime = handle
                .runtime
                .lock()
                .map_err(|_| "runtime lock is poisoned".to_owned())?;
            // SAFETY: pointer validation is centralized in `required_string`.
            let engines_json = unsafe { required_string(engines_json, "engines_json") }?;
            let engines: Vec<SyncEngine> =
                serde_json::from_str(&engines_json).map_err(|error| error.to_string())?;
            let reason = sync_reason(reason)?;
            let (status, next_allowed) = runtime
                .sync(reason, &engines, HashMap::new())
                .map_err(|error| error.to_string())?;
            serde_json::to_string(&serde_json::json!({
                "status": status,
                "next_sync_allowed_epoch_seconds": next_allowed,
            }))
            .map_err(|error| error.to_string())
        })();
        match result {
            Ok(json) => owned_string(json),
            Err(error) => {
                set_last_error(error);
                ptr::null_mut()
            }
        }
    }
    #[cfg(not(feature = "mozilla"))]
    {
        let _ = (runtime, reason, engines_json);
        set_last_error("xanh-sync-core was built without the mozilla feature");
        ptr::null_mut()
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_runtime_update_local_tabs(
    runtime: *mut c_void,
    tabs_json: *const c_char,
) -> *mut c_char {
    #[cfg(feature = "mozilla")]
    {
        let result = (|| {
            let mut runtime = unsafe { lock_runtime(runtime) }?;
            // SAFETY: pointer validation is centralized in `required_string`.
            let tabs_json = unsafe { required_string(tabs_json, "tabs_json") }?;
            if tabs_json.len() > MAX_LOCAL_TABS_JSON_BYTES {
                return Err(format!(
                    "tabs_json exceeds {MAX_LOCAL_TABS_JSON_BYTES} bytes"
                ));
            }
            let tabs: Vec<LocalTab> =
                serde_json::from_str(&tabs_json).map_err(|error| error.to_string())?;
            let result = runtime
                .update_local_tabs(tabs)
                .map_err(|error| error.to_string())?;
            serde_json::to_string(&result).map_err(|error| error.to_string())
        })();
        match result {
            Ok(json) => owned_string(json),
            Err(error) => {
                set_last_error(error);
                ptr::null_mut()
            }
        }
    }
    #[cfg(not(feature = "mozilla"))]
    {
        let _ = (runtime, tabs_json);
        set_last_error("xanh-sync-core was built without the mozilla feature");
        ptr::null_mut()
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_runtime_remote_tabs_json(runtime: *mut c_void) -> *mut c_char {
    #[cfg(feature = "mozilla")]
    {
        let result = unsafe { lock_runtime(runtime) }.and_then(|mut runtime| {
            let json = runtime
                .remote_tabs()
                .and_then(|tabs| serde_json::to_string(&tabs).map_err(backend_error))
                .map_err(|error| error.to_string())?;
            if json.len() > MAX_REMOTE_TABS_JSON_BYTES {
                return Err(format!(
                    "remote tabs JSON exceeds {MAX_REMOTE_TABS_JSON_BYTES} bytes"
                ));
            }
            Ok(json)
        });
        match result {
            Ok(json) => owned_string(json),
            Err(error) => {
                set_last_error(error);
                ptr::null_mut()
            }
        }
    }
    #[cfg(not(feature = "mozilla"))]
    {
        let _ = runtime;
        set_last_error("xanh-sync-core was built without the mozilla feature");
        ptr::null_mut()
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_bookmark_root_guid(root: i32) -> *mut c_char {
    match bookmark_root(root) {
        Ok(root) => owned_string(crate::bookmark_root_guid(root)),
        Err(error) => {
            set_last_error(error);
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_runtime_create_bookmark(
    runtime: *mut c_void,
    bookmark_json: *const c_char,
) -> *mut c_char {
    #[cfg(feature = "mozilla")]
    {
        let result = (|| {
            let mut runtime = unsafe { lock_runtime(runtime) }?;
            let bookmark_json = unsafe { required_string(bookmark_json, "bookmark_json") }?;
            if bookmark_json.len() > MAX_BOOKMARK_MUTATION_JSON_BYTES {
                return Err(format!(
                    "bookmark_json exceeds {MAX_BOOKMARK_MUTATION_JSON_BYTES} bytes"
                ));
            }
            let bookmark: NewBookmark =
                serde_json::from_str(&bookmark_json).map_err(|error| error.to_string())?;
            runtime
                .create_bookmark(bookmark)
                .map_err(|error| error.to_string())
        })();
        match result {
            Ok(guid) => owned_string(guid),
            Err(error) => {
                set_last_error(error);
                ptr::null_mut()
            }
        }
    }
    #[cfg(not(feature = "mozilla"))]
    {
        let _ = (runtime, bookmark_json);
        set_last_error("xanh-sync-core was built without the mozilla feature");
        ptr::null_mut()
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_runtime_bookmarks_json(runtime: *mut c_void, root: i32) -> *mut c_char {
    #[cfg(feature = "mozilla")]
    {
        let result = (|| {
            let mut runtime = unsafe { lock_runtime(runtime) }?;
            let root = bookmark_root(root)?;
            let json = runtime
                .bookmark_tree(root)
                .and_then(|records| serde_json::to_string(&records).map_err(backend_error))
                .map_err(|error| error.to_string())?;
            if json.len() > MAX_BOOKMARK_JSON_BYTES {
                return Err(format!(
                    "bookmark tree JSON exceeds {MAX_BOOKMARK_JSON_BYTES} bytes"
                ));
            }
            Ok(json)
        })();
        match result {
            Ok(json) => owned_string(json),
            Err(error) => {
                set_last_error(error);
                ptr::null_mut()
            }
        }
    }
    #[cfg(not(feature = "mozilla"))]
    {
        let _ = (runtime, root);
        set_last_error("xanh-sync-core was built without the mozilla feature");
        ptr::null_mut()
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_runtime_update_bookmark(
    runtime: *mut c_void,
    update_json: *const c_char,
) -> bool {
    #[cfg(feature = "mozilla")]
    {
        let result = (|| {
            let mut runtime = unsafe { lock_runtime(runtime) }?;
            let update_json = unsafe { required_string(update_json, "update_json") }?;
            if update_json.len() > MAX_BOOKMARK_MUTATION_JSON_BYTES {
                return Err(format!(
                    "update_json exceeds {MAX_BOOKMARK_MUTATION_JSON_BYTES} bytes"
                ));
            }
            let update: BookmarkUpdate =
                serde_json::from_str(&update_json).map_err(|error| error.to_string())?;
            runtime
                .update_bookmark(update)
                .map_err(|error| error.to_string())
        })();
        result.map(|_| true).unwrap_or_else(|error| {
            set_last_error(error);
            false
        })
    }
    #[cfg(not(feature = "mozilla"))]
    {
        let _ = (runtime, update_json);
        set_last_error("xanh-sync-core was built without the mozilla feature");
        false
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_runtime_delete_bookmark(
    runtime: *mut c_void,
    guid: *const c_char,
    is_private: bool,
) -> i32 {
    #[cfg(feature = "mozilla")]
    {
        let result = (|| {
            let mut runtime = unsafe { lock_runtime(runtime) }?;
            let guid = unsafe { required_string(guid, "guid") }?;
            runtime
                .delete_bookmark(guid, is_private)
                .map_err(|error| error.to_string())
        })();
        match result {
            Ok(true) => 1,
            Ok(false) => 0,
            Err(error) => {
                set_last_error(error);
                -1
            }
        }
    }
    #[cfg(not(feature = "mozilla"))]
    {
        let _ = (runtime, guid, is_private);
        set_last_error("xanh-sync-core was built without the mozilla feature");
        -1
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_runtime_record_history(
    runtime: *mut c_void,
    visits_json: *const c_char,
) -> *mut c_char {
    #[cfg(feature = "mozilla")]
    {
        let result = (|| {
            let mut runtime = unsafe { lock_runtime(runtime) }?;
            let visits_json = unsafe { required_string(visits_json, "visits_json") }?;
            if visits_json.len() > MAX_HISTORY_INPUT_JSON_BYTES {
                return Err(format!(
                    "visits_json exceeds {MAX_HISTORY_INPUT_JSON_BYTES} bytes"
                ));
            }
            let visits: Vec<LocalHistoryVisit> =
                serde_json::from_str(&visits_json).map_err(|error| error.to_string())?;
            let result = runtime
                .record_history(visits)
                .map_err(|error| error.to_string())?;
            serde_json::to_string(&result).map_err(|error| error.to_string())
        })();
        match result {
            Ok(json) => owned_string(json),
            Err(error) => {
                set_last_error(error);
                ptr::null_mut()
            }
        }
    }
    #[cfg(not(feature = "mozilla"))]
    {
        let _ = (runtime, visits_json);
        set_last_error("xanh-sync-core was built without the mozilla feature");
        ptr::null_mut()
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_runtime_recent_history_json(
    runtime: *mut c_void,
    limit: u32,
) -> *mut c_char {
    #[cfg(feature = "mozilla")]
    {
        let result = unsafe { lock_runtime(runtime) }.and_then(|mut runtime| {
            let json = runtime
                .recent_history(limit)
                .and_then(|visits| serde_json::to_string(&visits).map_err(backend_error))
                .map_err(|error| error.to_string())?;
            if json.len() > MAX_HISTORY_OUTPUT_JSON_BYTES {
                return Err(format!(
                    "history JSON exceeds {MAX_HISTORY_OUTPUT_JSON_BYTES} bytes"
                ));
            }
            Ok(json)
        });
        match result {
            Ok(json) => owned_string(json),
            Err(error) => {
                set_last_error(error);
                ptr::null_mut()
            }
        }
    }
    #[cfg(not(feature = "mozilla"))]
    {
        let _ = (runtime, limit);
        set_last_error("xanh-sync-core was built without the mozilla feature");
        ptr::null_mut()
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_runtime_delete_history_visit(
    runtime: *mut c_void,
    url: *const c_char,
    visited_at_epoch_millis: i64,
) -> bool {
    #[cfg(feature = "mozilla")]
    {
        let result = (|| {
            let mut runtime = unsafe { lock_runtime(runtime) }?;
            let url = unsafe { required_string(url, "url") }?;
            runtime
                .delete_history_visit(url, visited_at_epoch_millis)
                .map_err(|error| error.to_string())
        })();
        result.map(|_| true).unwrap_or_else(|error| {
            set_last_error(error);
            false
        })
    }
    #[cfg(not(feature = "mozilla"))]
    {
        let _ = (runtime, url, visited_at_epoch_millis);
        set_last_error("xanh-sync-core was built without the mozilla feature");
        false
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_runtime_disconnect(runtime: *mut c_void, delete_local: bool) -> bool {
    #[cfg(feature = "mozilla")]
    {
        let runtime = unsafe { lock_runtime(runtime) };
        runtime
            .and_then(|mut runtime| {
                runtime
                    .disconnect(delete_local)
                    .map_err(|error| error.to_string())
            })
            .map(|_| true)
            .unwrap_or_else(|error| {
                set_last_error(error);
                false
            })
    }
    #[cfg(not(feature = "mozilla"))]
    {
        let _ = (runtime, delete_local);
        set_last_error("xanh-sync-core was built without the mozilla feature");
        false
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_runtime_account_state(runtime: *mut c_void) -> i32 {
    #[cfg(feature = "mozilla")]
    {
        match unsafe { lock_runtime(runtime) } {
            Ok(runtime) => account_state_code(runtime.account_state()),
            Err(error) => {
                set_last_error(error);
                -1
            }
        }
    }
    #[cfg(not(feature = "mozilla"))]
    {
        let _ = runtime;
        set_last_error("xanh-sync-core was built without the mozilla feature");
        -1
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_runtime_unlock_vault(
    runtime: *mut c_void,
    local_logins_key: *const c_char,
) -> bool {
    #[cfg(feature = "mozilla")]
    {
        let result = (|| {
            let mut runtime = unsafe { lock_runtime(runtime) }?;
            let key = unsafe { required_string(local_logins_key, "local_logins_key") }?;
            runtime
                .unlock_logins(key)
                .map_err(|error| error.to_string())
        })();
        result.map(|_| true).unwrap_or_else(|error| {
            set_last_error(error);
            false
        })
    }
    #[cfg(not(feature = "mozilla"))]
    {
        let _ = (runtime, local_logins_key);
        set_last_error("xanh-sync-core was built without the mozilla feature");
        false
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_runtime_lock_vault(runtime: *mut c_void) -> bool {
    #[cfg(feature = "mozilla")]
    {
        match unsafe { lock_runtime(runtime) } {
            Ok(mut runtime) => {
                runtime.lock_logins();
                true
            }
            Err(error) => {
                set_last_error(error);
                false
            }
        }
    }
    #[cfg(not(feature = "mozilla"))]
    {
        let _ = runtime;
        set_last_error("xanh-sync-core was built without the mozilla feature");
        false
    }
}

#[no_mangle]
pub extern "C" fn xanh_sync_runtime_vault_unlocked(runtime: *mut c_void) -> bool {
    #[cfg(feature = "mozilla")]
    {
        return match unsafe { lock_runtime(runtime) } {
            Ok(runtime) => runtime.vault_unlocked(),
            Err(error) => {
                set_last_error(error);
                false
            }
        };
    }
    #[cfg(not(feature = "mozilla"))]
    {
        let _ = runtime;
        false
    }
}

#[cfg(feature = "mozilla")]
fn account_state_code(state: AccountState) -> i32 {
    match state {
        AccountState::Disconnected => 0,
        AccountState::Authenticating => 1,
        AccountState::Connected => 2,
        AccountState::AuthIssues => 3,
    }
}

#[cfg(feature = "mozilla")]
fn sync_reason(reason: i32) -> Result<SyncReason, String> {
    match reason {
        0 => Ok(SyncReason::Startup),
        1 => Ok(SyncReason::Manual),
        2 => Ok(SyncReason::Scheduled),
        3 => Ok(SyncReason::LocalChange),
        4 => Ok(SyncReason::PreSleep),
        _ => Err("unknown sync reason".into()),
    }
}

fn bookmark_root(root: i32) -> Result<BookmarkRoot, String> {
    match root {
        0 => Ok(BookmarkRoot::Menu),
        1 => Ok(BookmarkRoot::Toolbar),
        2 => Ok(BookmarkRoot::Unfiled),
        3 => Ok(BookmarkRoot::Mobile),
        _ => Err("unknown bookmark root".into()),
    }
}

#[cfg(feature = "mozilla")]
fn backend_error(error: impl std::fmt::Display) -> crate::SyncError {
    crate::SyncError::Backend(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_errors_redact_oauth_and_token_detail() {
        set_last_error("OAuth token rejected: bearer super-secret");
        let pointer = xanh_sync_last_error();
        assert!(!pointer.is_null());
        // SAFETY: this function returned a valid owned C string above.
        let message = unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned();
        xanh_sync_string_free(pointer);
        assert_eq!(message, "Mozilla Application Services operation failed");
        assert!(!message.contains("super-secret"));
    }
}
