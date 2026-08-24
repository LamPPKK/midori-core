// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

use std::cell::RefCell;
#[cfg(test)]
use std::ffi::CStr;
use std::ffi::{c_char, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

use crate::{
    compile_webkit_content_blocker, compile_xanh_baseline_for_webkit, AdblockEngine,
    MAX_FILTER_LIST_BYTES, MAX_METHOD_BYTES, MAX_REQUEST_TYPE_BYTES, MAX_URL_BYTES,
};

thread_local! {
    static LAST_ERROR: RefCell<Option<CString>> = const { RefCell::new(None) };
}

fn clear_error() {
    LAST_ERROR.with(|slot| *slot.borrow_mut() = None);
}

fn set_error(message: impl ToString) {
    let sanitized = message.to_string().replace('\0', " ");
    LAST_ERROR.with(|slot| {
        *slot.borrow_mut() = CString::new(sanitized).ok();
    });
}

unsafe fn required_utf8(
    value: *const c_char,
    name: &str,
    maximum_bytes: usize,
) -> Result<String, String> {
    if value.is_null() {
        return Err(format!("{name} is required"));
    }
    let mut length = 0_usize;
    while length <= maximum_bytes && *value.add(length) != 0 {
        length += 1;
    }
    if length == 0 {
        return Err(format!("{name} is empty"));
    }
    if length > maximum_bytes {
        return Err(format!("{name} exceeds {maximum_bytes} bytes"));
    }
    std::str::from_utf8(std::slice::from_raw_parts(value.cast::<u8>(), length))
        .map(str::to_owned)
        .map_err(|_| format!("{name} is not valid UTF-8"))
}

fn ffi_guard<T>(fallback: T, operation: impl FnOnce() -> Result<T, String>) -> T {
    clear_error();
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => {
            set_error(error);
            fallback
        }
        Err(_) => {
            set_error("adblock core panicked");
            fallback
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn xanh_adblock_engine_create(
    filter_list_utf8: *const c_char,
) -> *mut AdblockEngine {
    ffi_guard(ptr::null_mut(), || {
        let filter_list =
            required_utf8(filter_list_utf8, "filter_list_utf8", MAX_FILTER_LIST_BYTES)?;
        let engine =
            AdblockEngine::from_filter_list(&filter_list).map_err(|error| error.to_string())?;
        Ok(Box::into_raw(Box::new(engine)))
    })
}

#[no_mangle]
pub extern "C" fn xanh_adblock_engine_create_default() -> *mut AdblockEngine {
    ffi_guard(ptr::null_mut(), || {
        let engine = AdblockEngine::from_xanh_baseline().map_err(|error| error.to_string())?;
        Ok(Box::into_raw(Box::new(engine)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn xanh_adblock_engine_free(engine: *mut AdblockEngine) {
    if !engine.is_null() {
        drop(Box::from_raw(engine));
    }
}

/// Returns 1 to block, 0 to allow, and -1 on invalid input or engine failure.
#[no_mangle]
pub unsafe extern "C" fn xanh_adblock_engine_should_block(
    engine: *const AdblockEngine,
    url_utf8: *const c_char,
    source_url_utf8: *const c_char,
    request_type_utf8: *const c_char,
    method_utf8: *const c_char,
) -> i32 {
    ffi_guard(-1, || {
        let engine = engine
            .as_ref()
            .ok_or_else(|| "engine is required".to_owned())?;
        let url = required_utf8(url_utf8, "url_utf8", MAX_URL_BYTES)?;
        let source_url = required_utf8(source_url_utf8, "source_url_utf8", MAX_URL_BYTES)?;
        let request_type = required_utf8(
            request_type_utf8,
            "request_type_utf8",
            MAX_REQUEST_TYPE_BYTES,
        )?;
        let method = required_utf8(method_utf8, "method_utf8", MAX_METHOD_BYTES)?;
        let decision = engine
            .check(&url, &source_url, &request_type, &method)
            .map_err(|error| error.to_string())?;
        Ok(i32::from(decision.should_block))
    })
}

#[no_mangle]
pub unsafe extern "C" fn xanh_adblock_compile_webkit_json(
    filter_list_utf8: *const c_char,
) -> *mut c_char {
    ffi_guard(ptr::null_mut(), || {
        let filter_list =
            required_utf8(filter_list_utf8, "filter_list_utf8", MAX_FILTER_LIST_BYTES)?;
        let json =
            compile_webkit_content_blocker(&filter_list).map_err(|error| error.to_string())?;
        CString::new(json)
            .map(CString::into_raw)
            .map_err(|_| "content-blocking JSON contains a NUL byte".to_owned())
    })
}

#[no_mangle]
pub extern "C" fn xanh_adblock_compile_webkit_default_json() -> *mut c_char {
    ffi_guard(ptr::null_mut(), || {
        let json = compile_xanh_baseline_for_webkit().map_err(|error| error.to_string())?;
        CString::new(json)
            .map(CString::into_raw)
            .map_err(|_| "content-blocking JSON contains a NUL byte".to_owned())
    })
}

#[no_mangle]
pub extern "C" fn xanh_adblock_core_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
}

#[no_mangle]
pub extern "C" fn xanh_adblock_last_error() -> *mut c_char {
    LAST_ERROR.with(|slot| {
        slot.borrow()
            .as_ref()
            .and_then(|message| CString::new(message.as_bytes()).ok())
            .map(CString::into_raw)
            .unwrap_or(ptr::null_mut())
    })
}

#[no_mangle]
pub unsafe extern "C" fn xanh_adblock_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::XANH_ADBLOCK_CORE_VERSION;

    #[test]
    fn c_abi_round_trip_and_thread_local_error() {
        let rules = CString::new("||ads.example^").unwrap();
        let engine = unsafe { xanh_adblock_engine_create(rules.as_ptr()) };
        assert!(!engine.is_null());
        let url = CString::new("https://ads.example/banner.js").unwrap();
        let source = CString::new("https://news.example/article").unwrap();
        let kind = CString::new("script").unwrap();
        let method = CString::new("GET").unwrap();
        assert_eq!(
            unsafe {
                xanh_adblock_engine_should_block(
                    engine,
                    url.as_ptr(),
                    source.as_ptr(),
                    kind.as_ptr(),
                    method.as_ptr(),
                )
            },
            1
        );
        unsafe { xanh_adblock_engine_free(engine) };

        assert_eq!(
            unsafe {
                xanh_adblock_engine_should_block(
                    ptr::null(),
                    ptr::null(),
                    ptr::null(),
                    ptr::null(),
                    ptr::null(),
                )
            },
            -1
        );
        let error = xanh_adblock_last_error();
        assert!(!error.is_null());
        let message = unsafe { CStr::from_ptr(error) }
            .to_string_lossy()
            .into_owned();
        assert!(message.contains("engine is required"));
        unsafe { xanh_adblock_string_free(error) };
    }

    #[test]
    fn c_abi_default_engine_uses_the_bundled_baseline() {
        let engine = xanh_adblock_engine_create_default();
        assert!(!engine.is_null());
        let url = CString::new("https://ads.doubleclick.net/banner.js").unwrap();
        let source = CString::new("https://news.example/article").unwrap();
        let kind = CString::new("script").unwrap();
        let method = CString::new("GET").unwrap();
        assert_eq!(
            unsafe {
                xanh_adblock_engine_should_block(
                    engine,
                    url.as_ptr(),
                    source.as_ptr(),
                    kind.as_ptr(),
                    method.as_ptr(),
                )
            },
            1
        );
        unsafe { xanh_adblock_engine_free(engine) };
    }

    #[test]
    fn c_abi_bounds_strings_before_copying_them() {
        let engine = xanh_adblock_engine_create_default();
        assert!(!engine.is_null());
        let oversized_url =
            CString::new(format!("https://example.com/{}", "a".repeat(MAX_URL_BYTES))).unwrap();
        let source = CString::new("https://example.com/").unwrap();
        let kind = CString::new("script").unwrap();
        let method = CString::new("GET").unwrap();

        assert_eq!(
            unsafe {
                xanh_adblock_engine_should_block(
                    engine,
                    oversized_url.as_ptr(),
                    source.as_ptr(),
                    kind.as_ptr(),
                    method.as_ptr(),
                )
            },
            -1
        );
        let error = xanh_adblock_last_error();
        assert!(!error.is_null());
        let message = unsafe { CStr::from_ptr(error) }.to_string_lossy();
        assert!(message.contains("url_utf8 exceeds"));
        unsafe {
            xanh_adblock_string_free(error);
            xanh_adblock_engine_free(engine);
        }
    }

    #[test]
    fn c_abi_compiles_webkit_json() {
        let rules = CString::new("||ads.example^\nexample.com##.sponsored").unwrap();
        let json = unsafe { xanh_adblock_compile_webkit_json(rules.as_ptr()) };
        assert!(!json.is_null());
        let parsed: serde_json::Value =
            serde_json::from_str(unsafe { CStr::from_ptr(json) }.to_str().unwrap()).unwrap();
        assert!(parsed.as_array().is_some_and(|rules| !rules.is_empty()));
        unsafe { xanh_adblock_string_free(json) };
    }

    #[test]
    fn version_pointer_is_static() {
        let version = unsafe { CStr::from_ptr(xanh_adblock_core_version()) };
        assert_eq!(version.to_str().unwrap(), XANH_ADBLOCK_CORE_VERSION);
    }
}
