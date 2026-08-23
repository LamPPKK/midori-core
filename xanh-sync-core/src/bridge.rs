use serde::{Deserialize, Serialize};
use url::Url;

use crate::{has_explicit_url_userinfo, SyncError};

pub const MAX_BRIDGE_TAB_ID_BYTES: usize = 256;
pub const MAX_BRIDGE_NONCE_BYTES: usize = 256;
pub const MAX_BRIDGE_ORIGIN_BYTES: usize = 8_192;
pub const MAX_BRIDGE_MESSAGE_TYPE_BYTES: usize = 128;
pub const MAX_BRIDGE_PAYLOAD_BYTES: usize = 64 * 1_024;
pub const MAX_BRIDGE_ALLOWED_MESSAGE_TYPES: usize = 32;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(deny_unknown_fields)]
pub struct BridgeEnvelope {
    pub tab_id: String,
    pub navigation_nonce: String,
    pub claimed_origin: String,
    pub message_type: String,
    pub payload_json: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(deny_unknown_fields)]
pub struct BridgeExpectation {
    pub tab_id: String,
    pub navigation_nonce: String,
    pub committed_url: String,
    pub allowed_message_types: Vec<String>,
}

pub fn validate_bridge_message(
    message: &BridgeEnvelope,
    expected: &BridgeExpectation,
) -> Result<(), SyncError> {
    if !valid_bridge_token(&message.tab_id, MAX_BRIDGE_TAB_ID_BYTES)
        || !valid_bridge_token(&expected.tab_id, MAX_BRIDGE_TAB_ID_BYTES)
        || !valid_bridge_token(&message.navigation_nonce, MAX_BRIDGE_NONCE_BYTES)
        || !valid_bridge_token(&expected.navigation_nonce, MAX_BRIDGE_NONCE_BYTES)
    {
        return Err(SyncError::InvalidBridgeMessage(
            "tab or navigation identity is invalid".into(),
        ));
    }
    if message.tab_id != expected.tab_id || message.navigation_nonce != expected.navigation_nonce {
        return Err(SyncError::InvalidBridgeMessage(
            "stale tab or navigation nonce".into(),
        ));
    }
    if expected.allowed_message_types.is_empty()
        || expected.allowed_message_types.len() > MAX_BRIDGE_ALLOWED_MESSAGE_TYPES
        || expected
            .allowed_message_types
            .iter()
            .any(|value| !valid_message_type(value))
        || !valid_message_type(&message.message_type)
    {
        return Err(SyncError::InvalidBridgeMessage(
            "message type policy is invalid".into(),
        ));
    }
    if !expected
        .allowed_message_types
        .iter()
        .any(|allowed| allowed == &message.message_type)
    {
        return Err(SyncError::InvalidBridgeMessage(
            "message type is not allowed".into(),
        ));
    }
    if message.payload_json.len() > MAX_BRIDGE_PAYLOAD_BYTES {
        return Err(SyncError::InvalidBridgeMessage(
            "payload exceeds the bridge size limit".into(),
        ));
    }
    serde_json::from_str::<serde_json::Value>(&message.payload_json)
        .map_err(|_| SyncError::InvalidBridgeMessage("payload is not valid JSON".into()))?;
    let committed_origin = canonical_https_origin(&expected.committed_url, false)?;
    let claimed_origin = canonical_https_origin(&message.claimed_origin, true)?;
    if committed_origin != claimed_origin {
        return Err(SyncError::InvalidBridgeMessage("origin mismatch".into()));
    }
    Ok(())
}

fn valid_bridge_token(value: &str, maximum: usize) -> bool {
    !value.is_empty()
        && value.len() <= maximum
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn valid_message_type(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_BRIDGE_MESSAGE_TYPE_BYTES
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
}

fn canonical_https_origin(value: &str, require_origin_only: bool) -> Result<String, SyncError> {
    if value.len() > MAX_BRIDGE_ORIGIN_BYTES {
        return Err(SyncError::InvalidBridgeMessage(
            "bridge URL exceeds the shared size limit".into(),
        ));
    }
    let parsed = Url::parse(value)
        .map_err(|_| SyncError::InvalidBridgeMessage("bridge URL is invalid".into()))?;
    if parsed.scheme() != "https"
        || parsed.host_str().is_none()
        || has_explicit_url_userinfo(value)
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || (require_origin_only
            && (parsed.path() != "/" || parsed.query().is_some() || parsed.fragment().is_some()))
    {
        return Err(SyncError::InvalidBridgeMessage(
            "bridge URL is not a canonical HTTPS origin".into(),
        ));
    }
    Ok(parsed.origin().ascii_serialization())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forged_and_stale_messages_are_rejected() {
        let expected = BridgeExpectation {
            tab_id: "7".into(),
            navigation_nonce: "fresh".into(),
            committed_url: "https://example.org/login".into(),
            allowed_message_types: vec!["credential-request".into()],
        };
        let mut message = BridgeEnvelope {
            tab_id: "7".into(),
            navigation_nonce: "fresh".into(),
            claimed_origin: "https://example.org".into(),
            message_type: "credential-request".into(),
            payload_json: "{}".into(),
        };
        assert!(validate_bridge_message(&message, &expected).is_ok());
        message.navigation_nonce = "stale".into();
        assert!(validate_bridge_message(&message, &expected).is_err());
        message.navigation_nonce = "fresh".into();
        message.claimed_origin = "https://evil.example".into();
        assert!(validate_bridge_message(&message, &expected).is_err());
    }

    #[test]
    fn bridge_fields_are_bounded_and_claimed_origin_is_origin_only() {
        let expected = BridgeExpectation {
            tab_id: "tab-7".into(),
            navigation_nonce: "fresh_nonce".into(),
            committed_url: "https://example.org/login".into(),
            allowed_message_types: vec!["credential-request".into()],
        };
        let message = BridgeEnvelope {
            tab_id: expected.tab_id.clone(),
            navigation_nonce: expected.navigation_nonce.clone(),
            claimed_origin: "https://example.org".into(),
            message_type: "credential-request".into(),
            payload_json: "{}".into(),
        };
        assert!(validate_bridge_message(&message, &expected).is_ok());

        let mut invalid_message = message.clone();
        invalid_message.claimed_origin = "https://example.org/path".into();
        assert!(validate_bridge_message(&invalid_message, &expected).is_err());
        invalid_message.claimed_origin = "https://example.org/?query=1".into();
        assert!(validate_bridge_message(&invalid_message, &expected).is_err());
        invalid_message.claimed_origin = "https://user@example.org".into();
        assert!(validate_bridge_message(&invalid_message, &expected).is_err());
        invalid_message.claimed_origin = "https://@example.org".into();
        assert!(validate_bridge_message(&invalid_message, &expected).is_err());

        let mut invalid_expected = expected.clone();
        invalid_expected.committed_url = "https://user:secret@example.org/login".into();
        assert!(validate_bridge_message(&message, &invalid_expected).is_err());
        invalid_expected = expected.clone();
        invalid_expected.allowed_message_types =
            vec!["credential-request".into(); MAX_BRIDGE_ALLOWED_MESSAGE_TYPES + 1];
        assert!(validate_bridge_message(&message, &invalid_expected).is_err());

        invalid_message = message.clone();
        invalid_message.payload_json = "x".repeat(MAX_BRIDGE_PAYLOAD_BYTES + 1);
        assert!(validate_bridge_message(&invalid_message, &expected).is_err());
        invalid_message = message.clone();
        invalid_message.navigation_nonce = "n".repeat(MAX_BRIDGE_NONCE_BYTES + 1);
        assert!(validate_bridge_message(&invalid_message, &expected).is_err());

        let mut ambiguous = serde_json::to_value(&message).unwrap();
        ambiguous["origin"] = serde_json::json!("https://evil.example");
        assert!(serde_json::from_value::<BridgeEnvelope>(ambiguous).is_err());
    }
}
