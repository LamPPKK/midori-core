use serde::{Deserialize, Serialize};
use url::Url;

pub const VAULT_IDLE_TIMEOUT_SECONDS: u64 = 5 * 60;

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
pub struct CredentialContext {
    pub document_url: String,
    pub top_frame_origin: String,
    pub frame_origin: String,
    pub is_private: bool,
    pub user_selected: bool,
}

pub fn credential_access_allowed(context: &CredentialContext, vault: VaultState) -> bool {
    if context.is_private || !context.user_selected || matches!(vault, VaultState::Locked) {
        return false;
    }
    let Ok(document) = Url::parse(&context.document_url) else {
        return false;
    };
    let Ok(top) = Url::parse(&context.top_frame_origin) else {
        return false;
    };
    let Ok(frame) = Url::parse(&context.frame_origin) else {
        return false;
    };
    if document.scheme() != "https"
        || top.scheme() != "https"
        || frame.scheme() != "https"
        || !document.username().is_empty()
        || document.password().is_some()
    {
        return false;
    }
    same_origin(&document, &top) && same_origin(&top, &frame)
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
