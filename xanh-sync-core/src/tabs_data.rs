#![cfg_attr(not(feature = "mozilla"), allow(dead_code))]

use serde::{Deserialize, Serialize};
use url::Url;

use crate::SyncError;

pub(crate) const MAX_LOCAL_TABS: usize = 500;
pub(crate) const MAX_LOCAL_TABS_JSON_BYTES: usize = 4 * 1_024 * 1_024;
pub(crate) const MAX_REMOTE_DEVICES: usize = 100;
pub(crate) const MAX_REMOTE_TABS_PER_DEVICE: usize = 500;
pub(crate) const MAX_REMOTE_TABS_TOTAL: usize = 500;
pub(crate) const MAX_REMOTE_TABS_JSON_BYTES: usize = 8 * 1_024 * 1_024;
pub(crate) const MAX_URL_HISTORY: usize = 10;
pub(crate) const MAX_URL_LENGTH: usize = 8_192;
pub(crate) const MAX_TITLE_LENGTH: usize = 4_096;
pub(crate) const MAX_ICON_URL_LENGTH: usize = 8_192;
pub(crate) const MAX_DEVICE_ID_LENGTH: usize = 512;
pub(crate) const MAX_DEVICE_NAME_LENGTH: usize = 512;

/// A regular or private tab supplied by a platform host before a Tabs sync.
/// Private tabs are deliberately represented at this boundary so the shared
/// core, rather than every host implementation, enforces their exclusion.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(deny_unknown_fields)]
pub struct LocalTab {
    pub title: String,
    pub url_history: Vec<String>,
    pub icon_url: Option<String>,
    pub last_used_epoch_millis: i64,
    pub is_private: bool,
    pub is_pinned: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct LocalTabsUpdateResult {
    pub accepted_count: u32,
    pub skipped_private_count: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "kebab-case")]
pub enum RemoteDeviceKind {
    Desktop,
    Mobile,
    Tablet,
    Tv,
    Vr,
    Unknown,
}

/// A sanitized remote tab. Hosts display these records for an explicit user
/// choice; receiving a record never navigates or opens a local tab.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct RemoteTab {
    pub title: String,
    pub url_history: Vec<String>,
    pub icon_url: Option<String>,
    pub last_used_epoch_millis: i64,
    pub is_pinned: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct RemoteTabsDevice {
    pub device_id: String,
    pub device_name: String,
    pub device_kind: RemoteDeviceKind,
    pub last_modified_epoch_millis: i64,
    pub tabs: Vec<RemoteTab>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ValidatedLocalTab {
    pub title: String,
    pub url_history: Vec<String>,
    pub icon_url: Option<String>,
    pub last_used_epoch_millis: i64,
    pub is_pinned: bool,
    pub index: u32,
}

pub(crate) fn validate_local_tabs(
    tabs: Vec<LocalTab>,
) -> Result<(Vec<ValidatedLocalTab>, LocalTabsUpdateResult), SyncError> {
    if tabs.len() > MAX_LOCAL_TABS {
        return Err(SyncError::InvalidConfig(format!(
            "local tab payload exceeds {MAX_LOCAL_TABS} records"
        )));
    }

    let mut accepted = Vec::with_capacity(tabs.len());
    let mut skipped_private_count = 0u32;
    for tab in tabs {
        if tab.is_private {
            skipped_private_count += 1;
            continue;
        }
        if tab.title.chars().count() > MAX_TITLE_LENGTH {
            return Err(SyncError::InvalidConfig(format!(
                "tab title exceeds {MAX_TITLE_LENGTH} characters"
            )));
        }
        if tab.url_history.is_empty() || tab.url_history.len() > MAX_URL_HISTORY {
            return Err(SyncError::InvalidConfig(format!(
                "tab URL history must contain 1 to {MAX_URL_HISTORY} entries"
            )));
        }
        let url_history = tab
            .url_history
            .iter()
            .map(|url| canonical_web_url(url, MAX_URL_LENGTH, "tab URL"))
            .collect::<Result<Vec<_>, _>>()?;
        let icon_url = tab
            .icon_url
            .as_deref()
            .map(|url| canonical_web_url(url, MAX_ICON_URL_LENGTH, "tab icon URL"))
            .transpose()?;
        if tab.last_used_epoch_millis < 0 {
            return Err(SyncError::InvalidConfig(
                "tab last-used timestamp cannot be negative".into(),
            ));
        }
        let index = u32::try_from(accepted.len())
            .map_err(|_| SyncError::InvalidConfig("too many local tabs".into()))?;
        accepted.push(ValidatedLocalTab {
            title: tab.title,
            url_history,
            icon_url,
            last_used_epoch_millis: tab.last_used_epoch_millis,
            is_pinned: tab.is_pinned,
            index,
        });
    }

    let accepted_count = u32::try_from(accepted.len())
        .map_err(|_| SyncError::InvalidConfig("too many local tabs".into()))?;
    Ok((
        accepted,
        LocalTabsUpdateResult {
            accepted_count,
            skipped_private_count,
        },
    ))
}

pub(crate) fn sanitized_web_url(value: &str, max_length: usize) -> Option<String> {
    canonical_web_url(value, max_length, "URL").ok()
}

pub(crate) fn truncate(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

fn canonical_web_url(value: &str, max_length: usize, label: &str) -> Result<String, SyncError> {
    if value.len() > max_length {
        return Err(SyncError::InvalidConfig(format!(
            "{label} exceeds {max_length} bytes"
        )));
    }
    let parsed =
        Url::parse(value).map_err(|_| SyncError::InvalidConfig(format!("{label} is invalid")))?;
    if !matches!(parsed.scheme(), "http" | "https")
        || parsed.host_str().is_none()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
    {
        return Err(SyncError::InvalidConfig(format!(
            "{label} must be an HTTP(S) URL without userinfo"
        )));
    }
    let canonical = parsed.to_string();
    if canonical.len() > max_length {
        return Err(SyncError::InvalidConfig(format!(
            "canonical {label} exceeds {max_length} bytes"
        )));
    }
    Ok(canonical)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tab(url: &str) -> LocalTab {
        LocalTab {
            title: "Example".into(),
            url_history: vec![url.into()],
            icon_url: Some("https://example.com/favicon.ico".into()),
            last_used_epoch_millis: 1_700_000_000_000,
            is_private: false,
            is_pinned: false,
        }
    }

    #[test]
    fn private_tabs_are_excluded_by_the_shared_boundary() {
        let regular = tab("https://example.com/regular");
        let mut private = tab("https://example.com/private");
        private.is_private = true;

        let (accepted, result) = validate_local_tabs(vec![private, regular]).unwrap();

        assert_eq!(accepted.len(), 1);
        assert_eq!(accepted[0].index, 0);
        assert_eq!(result.accepted_count, 1);
        assert_eq!(result.skipped_private_count, 1);
        assert_eq!(accepted[0].url_history, ["https://example.com/regular"]);
    }

    #[test]
    fn unsafe_or_ambiguous_urls_are_rejected() {
        for url in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "https://user:secret@example.com/",
            "https://?missing-host",
        ] {
            assert!(
                validate_local_tabs(vec![tab(url)]).is_err(),
                "accepted {url}"
            );
        }
    }

    #[test]
    fn payload_and_history_are_bounded_before_upstream_storage() {
        let too_many_tabs = vec![tab("https://example.com"); MAX_LOCAL_TABS + 1];
        assert!(validate_local_tabs(too_many_tabs).is_err());

        let mut too_much_history = tab("https://example.com");
        too_much_history.url_history = vec!["https://example.com".into(); MAX_URL_HISTORY + 1];
        assert!(validate_local_tabs(vec![too_much_history]).is_err());
    }

    #[test]
    fn remote_urls_use_the_same_fail_closed_policy() {
        assert_eq!(
            sanitized_web_url("https://example.com/path", MAX_URL_LENGTH),
            Some("https://example.com/path".into())
        );
        assert_eq!(
            sanitized_web_url("data:text/html,secret", MAX_URL_LENGTH),
            None
        );
    }

    #[test]
    fn parser_differentials_are_replaced_with_the_canonical_url() {
        let (tabs, _) =
            validate_local_tabs(vec![tab("https://ex\nample.com\\folder/../safe?name=a\tb")])
                .unwrap();
        let canonical = &tabs[0].url_history[0];
        assert_eq!(canonical, "https://example.com/safe?name=ab");
        assert!(!canonical.contains(['\n', '\r', '\t', '\\']));

        assert_eq!(
            sanitized_web_url("https://éxample.com/", MAX_URL_LENGTH),
            Some("https://xn--xample-9ua.com/".into())
        );
    }

    #[test]
    fn c_json_contract_is_explicit_and_rejects_ambiguous_privacy_fields() {
        let encoded = serde_json::to_value(tab("https://example.com")).unwrap();
        assert_eq!(encoded["is_private"], false);
        assert_eq!(encoded["is_pinned"], false);
        assert_eq!(encoded["last_used_epoch_millis"], 1_700_000_000_000i64);

        let mut ambiguous = encoded;
        ambiguous["private"] = serde_json::Value::Bool(true);
        assert!(serde_json::from_value::<LocalTab>(ambiguous).is_err());
    }
}
