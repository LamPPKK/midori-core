use serde::{Deserialize, Serialize};
use url::Url;

use crate::SyncError;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct BridgeEnvelope {
    pub tab_id: String,
    pub navigation_nonce: String,
    pub claimed_origin: String,
    pub message_type: String,
    pub payload_json: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
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
    if message.tab_id != expected.tab_id || message.navigation_nonce != expected.navigation_nonce {
        return Err(SyncError::InvalidBridgeMessage(
            "stale tab or navigation nonce".into(),
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
    serde_json::from_str::<serde_json::Value>(&message.payload_json)
        .map_err(|_| SyncError::InvalidBridgeMessage("payload is not valid JSON".into()))?;
    let committed = Url::parse(&expected.committed_url)
        .map_err(|_| SyncError::InvalidBridgeMessage("committed URL is invalid".into()))?;
    let claimed = Url::parse(&message.claimed_origin)
        .map_err(|_| SyncError::InvalidBridgeMessage("claimed origin is invalid".into()))?;
    if committed.scheme() != "https"
        || claimed.scheme() != "https"
        || committed.host_str() != claimed.host_str()
        || committed.port_or_known_default() != claimed.port_or_known_default()
    {
        return Err(SyncError::InvalidBridgeMessage("origin mismatch".into()));
    }
    Ok(())
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
}
