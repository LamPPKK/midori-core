#![no_main]

use libfuzzer_sys::fuzz_target;
use serde::Deserialize;
use url::Url;
use xanh_sync_core::{
    validate_bridge_message, BridgeEnvelope, BridgeExpectation, MAX_BRIDGE_ALLOWED_MESSAGE_TYPES,
    MAX_BRIDGE_MESSAGE_TYPE_BYTES, MAX_BRIDGE_NONCE_BYTES, MAX_BRIDGE_ORIGIN_BYTES,
    MAX_BRIDGE_PAYLOAD_BYTES, MAX_BRIDGE_TAB_ID_BYTES,
};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BridgeCase {
    message: BridgeEnvelope,
    expected: BridgeExpectation,
}

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
    let Ok(case) = serde_json::from_slice::<BridgeCase>(data) else {
        return;
    };
    if validate_bridge_message(&case.message, &case.expected).is_err() {
        return;
    }

    assert_eq!(case.message.tab_id, case.expected.tab_id);
    assert_eq!(
        case.message.navigation_nonce,
        case.expected.navigation_nonce
    );
    assert!(case
        .expected
        .allowed_message_types
        .contains(&case.message.message_type));
    assert!(case.message.tab_id.len() <= MAX_BRIDGE_TAB_ID_BYTES);
    assert!(case.message.navigation_nonce.len() <= MAX_BRIDGE_NONCE_BYTES);
    assert!(case.message.claimed_origin.len() <= MAX_BRIDGE_ORIGIN_BYTES);
    assert!(case.message.message_type.len() <= MAX_BRIDGE_MESSAGE_TYPE_BYTES);
    assert!(case.message.payload_json.len() <= MAX_BRIDGE_PAYLOAD_BYTES);
    assert!(case.expected.allowed_message_types.len() <= MAX_BRIDGE_ALLOWED_MESSAGE_TYPES);
    assert!(serde_json::from_str::<serde_json::Value>(&case.message.payload_json).is_ok());

    let committed = Url::parse(&case.expected.committed_url).unwrap();
    let claimed = Url::parse(&case.message.claimed_origin).unwrap();
    assert_eq!(committed.scheme(), "https");
    assert_eq!(claimed.scheme(), "https");
    assert!(committed.username().is_empty() && committed.password().is_none());
    assert!(claimed.username().is_empty() && claimed.password().is_none());
    assert!(!authority_has_userinfo(&case.expected.committed_url));
    assert!(!authority_has_userinfo(&case.message.claimed_origin));
    assert_eq!(claimed.path(), "/");
    assert!(claimed.query().is_none() && claimed.fragment().is_none());
    assert_eq!(
        committed.origin().ascii_serialization(),
        claimed.origin().ascii_serialization()
    );
});
