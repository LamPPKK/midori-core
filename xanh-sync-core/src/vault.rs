use serde::{Deserialize, Serialize};
use url::Url;

use crate::{has_explicit_url_userinfo, SyncError};

pub const VAULT_IDLE_TIMEOUT_SECONDS: u64 = 5 * 60;
pub const MAX_CREDENTIAL_CONTEXT_URL_BYTES: usize = 8_192;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "kebab-case", tag = "state")]
pub enum VaultState {
    Locked,
    Unlocked { last_activity_epoch_seconds: u64 },
}

impl VaultState {
    pub fn is_expired(self, now: u64) -> bool {
        match self {
            Self::Locked => false,
            Self::Unlocked {
                last_activity_epoch_seconds,
            } => now.saturating_sub(last_activity_epoch_seconds) >= VAULT_IDLE_TIMEOUT_SECONDS,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(deny_unknown_fields)]
pub struct CredentialContext {
    pub document_url: String,
    pub top_frame_origin: String,
    pub frame_origin: String,
    pub is_private: bool,
    pub user_selected: bool,
}

pub fn credential_access_allowed(context: &CredentialContext, vault: VaultState) -> bool {
    credential_origin(context, vault).is_ok()
}

/// Validates the credential bridge context and returns the canonical HTTPS
/// origin that may be used for a Logins operation. The caller must still bind
/// the request to its current tab/navigation nonce before entering this core.
pub fn credential_origin(
    context: &CredentialContext,
    vault: VaultState,
) -> Result<String, SyncError> {
    if matches!(vault, VaultState::Locked) {
        return Err(SyncError::VaultLocked);
    }
    if context.is_private {
        return Err(SyncError::InvalidBridgeMessage(
            "credential access is disabled in private browsing".into(),
        ));
    }
    if !context.user_selected {
        return Err(SyncError::InvalidBridgeMessage(
            "credential access requires an explicit native user action".into(),
        ));
    }
    let document = parse_https_url(&context.document_url, false)?;
    let top = parse_https_url(&context.top_frame_origin, true)?;
    let frame = parse_https_url(&context.frame_origin, true)?;
    if !same_origin(&document, &top) || !same_origin(&top, &frame) {
        return Err(SyncError::InvalidBridgeMessage(
            "credential access requires an exact-origin top-level frame".into(),
        ));
    }
    Ok(document.origin().ascii_serialization())
}

fn parse_https_url(value: &str, origin_only: bool) -> Result<Url, SyncError> {
    if value.len() > MAX_CREDENTIAL_CONTEXT_URL_BYTES {
        return Err(SyncError::InvalidBridgeMessage(
            "credential context URL exceeds the shared size limit".into(),
        ));
    }
    let url = Url::parse(value).map_err(|_| {
        SyncError::InvalidBridgeMessage("credential context contains an invalid URL".into())
    })?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || has_explicit_url_userinfo(value)
        || !url.username().is_empty()
        || url.password().is_some()
        || (origin_only && (url.path() != "/" || url.query().is_some() || url.fragment().is_some()))
    {
        return Err(SyncError::InvalidBridgeMessage(
            "credential context is not a canonical HTTPS origin".into(),
        ));
    }
    Ok(url)
}

fn same_origin(left: &Url, right: &Url) -> bool {
    left.scheme() == right.scheme()
        && left.host_str() == right.host_str()
        && left.port_or_known_default() == right.port_or_known_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context() -> CredentialContext {
        CredentialContext {
            document_url: "https://example.org/login".into(),
            top_frame_origin: "https://example.org".into(),
            frame_origin: "https://example.org".into(),
            is_private: false,
            user_selected: true,
        }
    }

    #[test]
    fn rejects_http_private_and_cross_origin_frames() {
        let unlocked = VaultState::Unlocked {
            last_activity_epoch_seconds: 1,
        };
        assert!(credential_access_allowed(&context(), unlocked));
        let mut value = context();
        value.is_private = true;
        assert!(!credential_access_allowed(&value, unlocked));
        value = context();
        value.frame_origin = "https://evil.example".into();
        assert!(!credential_access_allowed(&value, unlocked));
        value = context();
        value.document_url = "http://example.org/login".into();
        assert!(!credential_access_allowed(&value, unlocked));
        value = context();
        value.top_frame_origin = "https://user@example.org".into();
        assert!(!credential_access_allowed(&value, unlocked));
        value = context();
        value.top_frame_origin = "https://@example.org".into();
        assert!(!credential_access_allowed(&value, unlocked));
        value = context();
        value.frame_origin = "https://example.org/path".into();
        assert!(!credential_access_allowed(&value, unlocked));
        value = context();
        value.user_selected = false;
        assert!(!credential_access_allowed(&value, unlocked));
        value = context();
        value.document_url =
            "https://example.org/".to_owned() + &"x".repeat(MAX_CREDENTIAL_CONTEXT_URL_BYTES);
        assert!(!credential_access_allowed(&value, unlocked));
        assert_eq!(
            credential_origin(&context(), unlocked).unwrap(),
            "https://example.org"
        );
    }

    #[test]
    fn vault_expires_after_five_minutes() {
        let vault = VaultState::Unlocked {
            last_activity_epoch_seconds: 100,
        };
        assert!(!vault.is_expired(399));
        assert!(vault.is_expired(400));
    }
}
