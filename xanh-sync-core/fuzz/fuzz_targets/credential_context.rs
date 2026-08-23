#![no_main]

use libfuzzer_sys::fuzz_target;
use url::Url;
use xanh_sync_core::{
    credential_origin, CredentialContext, VaultState, MAX_CREDENTIAL_CONTEXT_URL_BYTES,
};

fn authority_has_userinfo(value: &str) -> bool {
    let Some(scheme_end) = value.find("://") else {
        return false;
    };
    let authority = &value[scheme_end + 3..];
    let authority_end = authority
        .find(['/', '?', '#', '\\'])
        .unwrap_or(authority.len());
    authority[..authority_end].contains('@')
}

fuzz_target!(|data: &[u8]| {
    if data.len() > 256 * 1_024 {
        return;
    }
    let Ok(context) = serde_json::from_slice::<CredentialContext>(data) else {
        return;
    };
    let unlocked = VaultState::Unlocked {
        last_activity_epoch_seconds: 0,
    };
    let Ok(origin) = credential_origin(&context, unlocked) else {
        return;
    };

    assert!(!context.is_private && context.user_selected);
    let document = Url::parse(&context.document_url).unwrap();
    let top = Url::parse(&context.top_frame_origin).unwrap();
    let frame = Url::parse(&context.frame_origin).unwrap();
    for value in [&document, &top, &frame] {
        assert_eq!(value.scheme(), "https");
        assert!(value.host_str().is_some());
        assert!(value.username().is_empty() && value.password().is_none());
    }
    for value in [
        &context.document_url,
        &context.top_frame_origin,
        &context.frame_origin,
    ] {
        assert!(value.len() <= MAX_CREDENTIAL_CONTEXT_URL_BYTES);
        assert!(!authority_has_userinfo(value));
    }
    for value in [&top, &frame] {
        assert_eq!(value.path(), "/");
        assert!(value.query().is_none() && value.fragment().is_none());
    }
    assert_eq!(document.origin(), top.origin());
    assert_eq!(top.origin(), frame.origin());
    assert_eq!(origin, document.origin().ascii_serialization());
});
