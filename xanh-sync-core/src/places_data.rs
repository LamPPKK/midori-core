#![cfg_attr(not(feature = "mozilla"), allow(dead_code))]

use serde::{Deserialize, Serialize};

use crate::{canonical_web_url, SyncError};

pub(crate) const MAX_BOOKMARK_ITEMS: usize = 10_000;
pub(crate) const MAX_BOOKMARK_JSON_BYTES: usize = 16 * 1_024 * 1_024;
pub(crate) const MAX_BOOKMARK_MUTATION_JSON_BYTES: usize = 64 * 1_024;
pub(crate) const MAX_LEGACY_BOOKMARK_BATCH: usize = 10_000;
pub(crate) const MAX_LEGACY_BOOKMARK_JSON_BYTES: usize = 16 * 1_024 * 1_024;
pub(crate) const MAX_HISTORY_BATCH: usize = 1_000;
pub(crate) const MAX_HISTORY_INPUT_JSON_BYTES: usize = 8 * 1_024 * 1_024;
pub(crate) const MAX_HISTORY_RESULTS: u32 = 500;
pub(crate) const MAX_HISTORY_OUTPUT_JSON_BYTES: usize = 8 * 1_024 * 1_024;
pub(crate) const MAX_PLACES_TITLE_BYTES: usize = 4_096;
pub(crate) const MAX_PLACES_URL_LENGTH: usize = 8_192;
const SYNC_GUID_LENGTH: usize = 12;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "kebab-case")]
pub enum BookmarkRoot {
    Menu,
    Toolbar,
    Unfiled,
    Mobile,
}

#[uniffi::export]
pub fn bookmark_root_guid(root: BookmarkRoot) -> String {
    match root {
        BookmarkRoot::Menu => "menu________",
        BookmarkRoot::Toolbar => "toolbar_____",
        BookmarkRoot::Unfiled => "unfiled_____",
        BookmarkRoot::Mobile => "mobile______",
    }
    .to_owned()
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "kebab-case")]
pub enum BookmarkKind {
    Bookmark,
    Folder,
    Separator,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(deny_unknown_fields)]
pub struct NewBookmark {
    pub parent_guid: String,
    pub position: Option<u32>,
    pub kind: BookmarkKind,
    pub title: Option<String>,
    pub url: Option<String>,
    pub date_added_epoch_millis: Option<i64>,
    pub last_modified_epoch_millis: Option<i64>,
    pub is_private: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(deny_unknown_fields)]
pub struct BookmarkUpdate {
    pub guid: String,
    pub title: Option<String>,
    pub url: Option<String>,
    pub parent_guid: Option<String>,
    pub position: Option<u32>,
    pub is_private: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct BookmarkRecord {
    pub guid: String,
    pub parent_guid: Option<String>,
    pub position: u32,
    pub kind: BookmarkKind,
    pub title: Option<String>,
    pub url: Option<String>,
    /// True only when the URL is safe for an Xanh web view to open. Places can
    /// contain Firefox bookmarklets and other non-web URLs; they remain
    /// manageable but must not be navigated by a platform host.
    pub is_openable: bool,
    pub date_added_epoch_millis: i64,
    pub last_modified_epoch_millis: i64,
}

/// A bookmark from Xanh's pre-Places compatibility database. Migration uses
/// a dedicated record so hosts cannot accidentally omit the private-browsing
/// context required by ordinary bookmark mutations.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(deny_unknown_fields)]
pub struct LegacyBookmark {
    pub url: String,
    pub title: String,
    pub created_at_epoch_millis: i64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct LegacyBookmarkImportResult {
    pub accepted_count: u32,
    pub existing_count: u32,
    pub created_count: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "kebab-case")]
pub enum HistoryTransition {
    Link,
    Typed,
    Bookmark,
    RedirectPermanent,
    RedirectTemporary,
    Download,
    Reload,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(deny_unknown_fields)]
pub struct LocalHistoryVisit {
    pub url: String,
    pub title: Option<String>,
    pub visited_at_epoch_millis: i64,
    pub transition: HistoryTransition,
    pub is_private: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct LocalHistoryUpdateResult {
    pub accepted_count: u32,
    pub skipped_private_count: u32,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct HistoryVisitRecord {
    pub url: String,
    pub title: Option<String>,
    pub visited_at_epoch_millis: i64,
    pub transition: HistoryTransition,
    pub is_remote: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ValidatedBookmarkInsert {
    pub parent_guid: String,
    pub position: Option<u32>,
    pub kind: BookmarkKind,
    pub title: Option<String>,
    pub url: Option<String>,
    pub date_added_epoch_millis: Option<u64>,
    pub last_modified_epoch_millis: Option<u64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ValidatedBookmarkUpdate {
    pub guid: String,
    pub title: Option<String>,
    pub url: Option<String>,
    pub parent_guid: Option<String>,
    pub position: Option<u32>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ValidatedHistoryVisit {
    pub url: String,
    pub title: Option<String>,
    pub visited_at_epoch_millis: u64,
    pub transition: HistoryTransition,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ValidatedLegacyBookmark {
    pub url: String,
    pub title: String,
    pub created_at_epoch_millis: u64,
}

pub(crate) fn validate_new_bookmark(
    item: NewBookmark,
) -> Result<ValidatedBookmarkInsert, SyncError> {
    if item.is_private {
        return Err(SyncError::InvalidConfig(
            "bookmarks cannot be created from private browsing".into(),
        ));
    }
    let parent_guid = validate_sync_guid(&item.parent_guid, "bookmark parent GUID")?;
    let title = item
        .title
        .map(|title| validate_title(title, "bookmark title"))
        .transpose()?;
    let url = item
        .url
        .as_deref()
        .map(|url| canonical_web_url(url, MAX_PLACES_URL_LENGTH, "bookmark URL"))
        .transpose()?;

    match item.kind {
        BookmarkKind::Bookmark if url.is_none() => {
            return Err(SyncError::InvalidConfig(
                "a bookmark requires an HTTP(S) URL".into(),
            ));
        }
        BookmarkKind::Folder if url.is_some() => {
            return Err(SyncError::InvalidConfig(
                "a bookmark folder cannot contain a URL".into(),
            ));
        }
        BookmarkKind::Separator if title.is_some() || url.is_some() => {
            return Err(SyncError::InvalidConfig(
                "a bookmark separator cannot contain a title or URL".into(),
            ));
        }
        _ => {}
    }

    let date_added_epoch_millis =
        validate_optional_timestamp(item.date_added_epoch_millis, "bookmark creation timestamp")?;
    let last_modified_epoch_millis = validate_optional_timestamp(
        item.last_modified_epoch_millis,
        "bookmark modification timestamp",
    )?;
    if matches!(
        (date_added_epoch_millis, last_modified_epoch_millis),
        (Some(created), Some(modified)) if modified < created
    ) {
        return Err(SyncError::InvalidConfig(
            "bookmark modification timestamp precedes creation".into(),
        ));
    }

    Ok(ValidatedBookmarkInsert {
        parent_guid,
        position: item.position,
        kind: item.kind,
        title,
        url,
        date_added_epoch_millis,
        last_modified_epoch_millis,
    })
}

pub(crate) fn validate_bookmark_update(
    update: BookmarkUpdate,
) -> Result<ValidatedBookmarkUpdate, SyncError> {
    if update.is_private {
        return Err(SyncError::InvalidConfig(
            "bookmarks cannot be updated from private browsing".into(),
        ));
    }
    Ok(ValidatedBookmarkUpdate {
        guid: validate_sync_guid(&update.guid, "bookmark GUID")?,
        title: update
            .title
            .map(|title| validate_title(title, "bookmark title"))
            .transpose()?,
        url: update
            .url
            .as_deref()
            .map(|url| canonical_web_url(url, MAX_PLACES_URL_LENGTH, "bookmark URL"))
            .transpose()?,
        parent_guid: update
            .parent_guid
            .as_deref()
            .map(|guid| validate_sync_guid(guid, "bookmark parent GUID"))
            .transpose()?,
        position: update.position,
    })
}

pub(crate) fn validate_bookmark_delete(guid: &str, is_private: bool) -> Result<String, SyncError> {
    if is_private {
        return Err(SyncError::InvalidConfig(
            "bookmarks cannot be deleted from private browsing".into(),
        ));
    }
    validate_sync_guid(guid, "bookmark GUID")
}

pub(crate) fn validate_local_history(
    visits: Vec<LocalHistoryVisit>,
) -> Result<(Vec<ValidatedHistoryVisit>, LocalHistoryUpdateResult), SyncError> {
    if visits.len() > MAX_HISTORY_BATCH {
        return Err(SyncError::InvalidConfig(format!(
            "local history payload exceeds {MAX_HISTORY_BATCH} records"
        )));
    }

    let mut accepted = Vec::with_capacity(visits.len());
    let mut skipped_private_count = 0u32;
    for visit in visits {
        if visit.is_private {
            skipped_private_count += 1;
            continue;
        }
        accepted.push(ValidatedHistoryVisit {
            url: canonical_web_url(&visit.url, MAX_PLACES_URL_LENGTH, "history URL")?,
            title: visit
                .title
                .map(|title| validate_title(title, "history title"))
                .transpose()?,
            visited_at_epoch_millis: validate_timestamp(
                visit.visited_at_epoch_millis,
                "history visit timestamp",
            )?,
            transition: visit.transition,
        });
    }

    let accepted_count = u32::try_from(accepted.len())
        .map_err(|_| SyncError::InvalidConfig("too many history visits".into()))?;
    Ok((
        accepted,
        LocalHistoryUpdateResult {
            accepted_count,
            skipped_private_count,
        },
    ))
}

pub(crate) fn validate_history_limit(limit: u32) -> Result<u32, SyncError> {
    if limit == 0 || limit > MAX_HISTORY_RESULTS {
        return Err(SyncError::InvalidConfig(format!(
            "history result limit must be between 1 and {MAX_HISTORY_RESULTS}"
        )));
    }
    Ok(limit)
}

pub(crate) fn validate_legacy_bookmarks(
    bookmarks: Vec<LegacyBookmark>,
) -> Result<Vec<ValidatedLegacyBookmark>, SyncError> {
    if bookmarks.len() > MAX_LEGACY_BOOKMARK_BATCH {
        return Err(SyncError::Migration(format!(
            "legacy bookmark payload exceeds {MAX_LEGACY_BOOKMARK_BATCH} records"
        )));
    }
    bookmarks
        .into_iter()
        .map(|bookmark| {
            let url =
                canonical_web_url(&bookmark.url, MAX_PLACES_URL_LENGTH, "legacy bookmark URL")?;
            let title = sanitized_title(Some(bookmark.title)).unwrap_or_default();
            let created_at_epoch_millis = validate_timestamp(
                bookmark.created_at_epoch_millis,
                "legacy bookmark creation timestamp",
            )?;
            Ok(ValidatedLegacyBookmark {
                url,
                title,
                created_at_epoch_millis,
            })
        })
        .collect()
}

pub(crate) fn validate_history_delete(
    url: &str,
    visited_at_epoch_millis: i64,
) -> Result<(String, u64), SyncError> {
    Ok((
        canonical_web_url(url, MAX_PLACES_URL_LENGTH, "history URL")?,
        validate_timestamp(visited_at_epoch_millis, "history visit timestamp")?,
    ))
}

pub(crate) fn sanitized_title(value: Option<String>) -> Option<String> {
    value.map(|value| {
        let mut sanitized = String::with_capacity(value.len().min(MAX_PLACES_TITLE_BYTES));
        for character in value.chars().filter(|character| !character.is_control()) {
            if sanitized.len() + character.len_utf8() > MAX_PLACES_TITLE_BYTES {
                break;
            }
            sanitized.push(character);
        }
        sanitized
    })
}

fn validate_title(value: String, label: &str) -> Result<String, SyncError> {
    if value.len() > MAX_PLACES_TITLE_BYTES {
        return Err(SyncError::InvalidConfig(format!(
            "{label} exceeds {MAX_PLACES_TITLE_BYTES} UTF-8 bytes"
        )));
    }
    if value.chars().any(char::is_control) {
        return Err(SyncError::InvalidConfig(format!(
            "{label} contains control characters"
        )));
    }
    Ok(value)
}

fn validate_sync_guid(value: &str, label: &str) -> Result<String, SyncError> {
    if value.len() != SYNC_GUID_LENGTH
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    {
        return Err(SyncError::InvalidConfig(format!(
            "{label} must be a 12-character base64url identifier"
        )));
    }
    Ok(value.to_owned())
}

fn validate_optional_timestamp(value: Option<i64>, label: &str) -> Result<Option<u64>, SyncError> {
    value
        .map(|value| validate_timestamp(value, label))
        .transpose()
}

fn validate_timestamp(value: i64, label: &str) -> Result<u64, SyncError> {
    u64::try_from(value)
        .ok()
        .filter(|value| *value > 0)
        .ok_or_else(|| SyncError::InvalidConfig(format!("{label} must be positive")))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bookmark(kind: BookmarkKind) -> NewBookmark {
        NewBookmark {
            parent_guid: "unfiled_____".into(),
            position: None,
            kind,
            title: Some("Example".into()),
            url: Some("https://example.com/path".into()),
            date_added_epoch_millis: Some(1_700_000_000_000),
            last_modified_epoch_millis: Some(1_700_000_000_001),
            is_private: false,
        }
    }

    fn history(url: &str) -> LocalHistoryVisit {
        LocalHistoryVisit {
            url: url.into(),
            title: Some("Example".into()),
            visited_at_epoch_millis: 1_700_000_000_000,
            transition: HistoryTransition::Typed,
            is_private: false,
        }
    }

    #[test]
    fn bookmark_shape_and_guid_are_validated_before_places() {
        assert!(validate_new_bookmark(bookmark(BookmarkKind::Bookmark)).is_ok());

        let mut folder = bookmark(BookmarkKind::Folder);
        folder.url = None;
        assert!(validate_new_bookmark(folder).is_ok());

        let mut separator = bookmark(BookmarkKind::Separator);
        separator.title = None;
        separator.url = None;
        assert!(validate_new_bookmark(separator).is_ok());

        let mut bad = bookmark(BookmarkKind::Bookmark);
        bad.parent_guid = "not-a-guid".into();
        assert!(validate_new_bookmark(bad).is_err());

        let mut reversed_time = bookmark(BookmarkKind::Bookmark);
        reversed_time.last_modified_epoch_millis = Some(1_699_999_999_999);
        assert!(validate_new_bookmark(reversed_time).is_err());

        let mut private = bookmark(BookmarkKind::Bookmark);
        private.is_private = true;
        assert!(validate_new_bookmark(private).is_err());

        let mut exact_multibyte = bookmark(BookmarkKind::Bookmark);
        exact_multibyte.title = Some("😀".repeat(1_024));
        assert!(validate_new_bookmark(exact_multibyte).is_ok());
        let mut oversized_multibyte = bookmark(BookmarkKind::Bookmark);
        oversized_multibyte.title = Some("😀".repeat(1_025));
        assert!(validate_new_bookmark(oversized_multibyte).is_err());
        let sanitized = sanitized_title(Some("😀".repeat(1_025))).unwrap();
        assert_eq!(sanitized.len(), MAX_PLACES_TITLE_BYTES);
        assert_eq!(sanitized.chars().count(), 1_024);

        assert!(validate_bookmark_delete("bookmark1234", false).is_ok());
        assert!(validate_bookmark_delete("bookmark1234", true).is_err());

        assert_eq!(bookmark_root_guid(BookmarkRoot::Menu), "menu________");
        assert_eq!(bookmark_root_guid(BookmarkRoot::Toolbar), "toolbar_____");
        assert_eq!(bookmark_root_guid(BookmarkRoot::Unfiled), "unfiled_____");
        assert_eq!(bookmark_root_guid(BookmarkRoot::Mobile), "mobile______");
    }

    #[test]
    fn places_urls_are_canonical_and_unsafe_urls_fail_closed() {
        let mut item = bookmark(BookmarkKind::Bookmark);
        item.url = Some("https://ex\nample.com\\folder/../safe?name=a\tb".into());
        assert_eq!(
            validate_new_bookmark(item).unwrap().url.as_deref(),
            Some("https://example.com/safe?name=ab")
        );

        for url in [
            "file:///tmp/private",
            "javascript:alert(1)",
            "https://u:p@example.com/",
        ] {
            let mut item = bookmark(BookmarkKind::Bookmark);
            item.url = Some(url.into());
            assert!(validate_new_bookmark(item).is_err(), "accepted {url}");
        }
    }

    #[test]
    fn private_history_is_excluded_by_the_shared_boundary() {
        let regular = history("https://example.com/regular");
        let mut private = history("https://example.com/private");
        private.is_private = true;

        let (visits, result) = validate_local_history(vec![private, regular]).unwrap();

        assert_eq!(visits.len(), 1);
        assert_eq!(result.accepted_count, 1);
        assert_eq!(result.skipped_private_count, 1);
        assert_eq!(visits[0].url, "https://example.com/regular");
    }

    #[test]
    fn history_payload_timestamp_and_result_limit_are_bounded() {
        assert!(validate_local_history(vec![
            history("https://example.com");
            MAX_HISTORY_BATCH + 1
        ])
        .is_err());
        let mut invalid_time = history("https://example.com");
        invalid_time.visited_at_epoch_millis = 0;
        assert!(validate_local_history(vec![invalid_time]).is_err());
        let mut oversized_title = history("https://example.com");
        oversized_title.title = Some("😀".repeat(1_025));
        assert!(validate_local_history(vec![oversized_title]).is_err());
        assert!(validate_history_limit(0).is_err());
        assert!(validate_history_limit(MAX_HISTORY_RESULTS + 1).is_err());
    }

    #[test]
    fn c_json_contract_rejects_ambiguous_privacy_fields() {
        let mut bookmark_value = serde_json::to_value(bookmark(BookmarkKind::Bookmark)).unwrap();
        assert_eq!(bookmark_value["is_private"], false);
        bookmark_value.as_object_mut().unwrap().remove("is_private");
        assert!(serde_json::from_value::<NewBookmark>(bookmark_value).is_err());

        let encoded = serde_json::to_value(history("https://example.com")).unwrap();
        assert_eq!(encoded["is_private"], false);
        let mut ambiguous = encoded;
        ambiguous["private"] = serde_json::Value::Bool(true);
        assert!(serde_json::from_value::<LocalHistoryVisit>(ambiguous).is_err());
    }

    #[test]
    fn legacy_bookmarks_are_bounded_canonical_and_title_safe() {
        let migrated = validate_legacy_bookmarks(vec![LegacyBookmark {
            url: "https://ex\nample.com\\folder/../safe".into(),
            title: "😀".repeat(1_025),
            created_at_epoch_millis: 1_700_000_000_000,
        }])
        .unwrap();
        assert_eq!(migrated[0].url, "https://example.com/safe");
        assert_eq!(migrated[0].title.len(), MAX_PLACES_TITLE_BYTES);
        assert!(validate_legacy_bookmarks(vec![LegacyBookmark {
            url: "https://user:secret@example.com/".into(),
            title: "unsafe".into(),
            created_at_epoch_millis: 1,
        }])
        .is_err());
    }
}
