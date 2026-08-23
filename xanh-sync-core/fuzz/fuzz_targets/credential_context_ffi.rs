#![no_main]

use std::ffi::CString;
use std::os::raw::c_char;

use libfuzzer_sys::fuzz_target;
use xanh_sync_core::{credential_origin, CredentialContext, VaultState};

unsafe extern "C" {
    fn xanh_sync_credential_access_allowed(
        context_json: *const c_char,
        vault_unlocked: bool,
    ) -> bool;
}

fuzz_target!(|data: &[u8]| {
    if data.len() > 256 * 1_024 || data.contains(&0) {
        return;
    }
    let Ok(input) = CString::new(data) else {
        return;
    };
    // SAFETY: `input` is a live NUL-terminated allocation for the duration of
    // the call and the exported C ABI never retains the pointer.
    let accepted = unsafe { xanh_sync_credential_access_allowed(input.as_ptr(), true) };
    if !accepted {
        return;
    }

    let context: CredentialContext = serde_json::from_slice(data).unwrap();
    let origin = credential_origin(
        &context,
        VaultState::Unlocked {
            last_activity_epoch_seconds: 0,
        },
    );
    assert!(origin.is_ok());
});
