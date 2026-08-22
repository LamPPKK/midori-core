#![cfg_attr(not(feature = "mozilla"), allow(dead_code))]

use serde::{Deserialize, Serialize};

use crate::{credential_origin, CredentialContext, SyncError, VaultState};

pub(crate) const MAX_CREDENTIAL_INPUT_JSON_BYTES: usize = 64 * 1_024;
pub(crate) const MAX_CREDENTIAL_OUTPUT_JSON_BYTES: usize = 4 * 1_024 * 1_024;
pub const MAX_CREDENTIAL_RESULTS: usize = 100;
pub const MAX_CREDENTIAL_ORIGIN_BYTES: usize = 8_192;
pub const MAX_CREDENTIAL_ID_BYTES: usize = 128;
pub const MAX_CREDENTIAL_USERNAME_BYTES: usize = 1_024;
pub const MAX_CREDENTIAL_PASSWORD_BYTES: usize = 4_096;
pub const MAX_CREDENTIAL_FIELD_BYTES: usize = 256;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(deny_unknown_fields)]
pub struct NewCredential {
    pub context: CredentialContext,
    pub username_field: String,
    pub password_field: String,
    pub username: String,
    pub password: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(deny_unknown_fields)]
pub struct CredentialUpdate {
    pub id: String,
    pub context: CredentialContext,
    pub username_field: String,
    pub password_field: String,
    pub username: String,
    pub password: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
#[serde(deny_unknown_fields)]
pub struct CredentialRecord {
    pub id: String,
    pub origin: String,
    pub form_action_origin: String,
    pub username_field: String,
    pub password_field: String,
    pub username: String,
    pub password: String,
    pub time_created_epoch_millis: i64,
    pub time_password_changed_epoch_millis: i64,
    pub time_last_used_epoch_millis: i64,
    pub times_used: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ValidatedCredentialFields {
    pub origin: String,
    pub username_field: String,
    pub password_field: String,
    pub username: String,
    pub password: String,
}

pub(crate) fn validate_credential_context(
    context: &CredentialContext,
    vault_unlocked: bool,
) -> Result<String, SyncError> {
    let vault = if vault_unlocked {
        VaultState::Unlocked {
            last_activity_epoch_seconds: 0,
        }
    } else {
        VaultState::Locked
    };
    let origin = credential_origin(context, vault)?;
    if origin.len() > MAX_CREDENTIAL_ORIGIN_BYTES {
        return Err(SyncError::InvalidBridgeMessage(
            "credential origin exceeds the shared size limit".into(),
        ));
    }
    Ok(origin)
}

pub(crate) fn validate_new_credential(
    credential: NewCredential,
    vault_unlocked: bool,
) -> Result<ValidatedCredentialFields, SyncError> {
    let origin = validate_credential_context(&credential.context, vault_unlocked)?;
    validate_fields(
        origin,
        credential.username_field,
        credential.password_field,
        credential.username,
        credential.password,
    )
}

pub(crate) fn validate_credential_update(
    credential: CredentialUpdate,
    vault_unlocked: bool,
) -> Result<(String, ValidatedCredentialFields), SyncError> {
    let id = validate_credential_id(&credential.id)?;
    let origin = validate_credential_context(&credential.context, vault_unlocked)?;
    let fields = validate_fields(
        origin,
        credential.username_field,
        credential.password_field,
        credential.username,
        credential.password,
    )?;
    Ok((id, fields))
}

pub(crate) fn validate_credential_action(
    id: &str,
    context: &CredentialContext,
    vault_unlocked: bool,
) -> Result<(String, String), SyncError> {
    Ok((
        validate_credential_id(id)?,
        validate_credential_context(context, vault_unlocked)?,
    ))
}

pub(crate) fn sanitize_credential_records(
    records: Vec<CredentialRecord>,
    expected_origin: &str,
) -> Vec<CredentialRecord> {
    let mut records: Vec<_> = records
        .into_iter()
        .filter_map(|record| sanitize_credential_record(record, expected_origin))
        .collect();
    records.sort_by(|left, right| {
        right
            .time_last_used_epoch_millis
            .cmp(&left.time_last_used_epoch_millis)
            .then_with(|| left.id.cmp(&right.id))
    });

    let mut encoded_bytes = 2usize;
    records
        .into_iter()
        .filter(|record| {
            let Ok(record_bytes) = serde_json::to_vec(record).map(|json| json.len() + 1) else {
                return false;
            };
            let Some(next_size) = encoded_bytes.checked_add(record_bytes) else {
                return false;
            };
            if next_size > MAX_CREDENTIAL_OUTPUT_JSON_BYTES {
                return false;
            }
            encoded_bytes = next_size;
            true
        })
        .take(MAX_CREDENTIAL_RESULTS)
        .collect()
}

pub(crate) fn sanitize_credential_record(
    mut record: CredentialRecord,
    expected_origin: &str,
) -> Option<CredentialRecord> {
    validate_credential_id(&record.id).ok()?;
    let canonical_origin = canonical_stored_origin(&record.origin)?;
    let canonical_action = canonical_stored_origin(&record.form_action_origin)?;
    if canonical_origin != expected_origin || canonical_action != expected_origin {
        return None;
    }
    validate_secret(&record.username, MAX_CREDENTIAL_USERNAME_BYTES, false).ok()?;
    validate_secret(&record.password, MAX_CREDENTIAL_PASSWORD_BYTES, true).ok()?;
    validate_field_name(&record.username_field).ok()?;
    validate_field_name(&record.password_field).ok()?;
    if record.time_created_epoch_millis < 0
        || record.time_password_changed_epoch_millis < 0
        || record.time_last_used_epoch_millis < 0
        || record.times_used < 0
    {
        return None;
    }
    record.origin = canonical_origin;
    record.form_action_origin = canonical_action;
    Some(record)
}

fn validate_fields(
    origin: String,
    username_field: String,
    password_field: String,
    username: String,
    password: String,
) -> Result<ValidatedCredentialFields, SyncError> {
    validate_field_name(&username_field)?;
    validate_field_name(&password_field)?;
    validate_secret(&username, MAX_CREDENTIAL_USERNAME_BYTES, false)?;
    validate_secret(&password, MAX_CREDENTIAL_PASSWORD_BYTES, true)?;
    Ok(ValidatedCredentialFields {
        origin,
        username_field,
        password_field,
        username,
        password,
    })
}

fn validate_credential_id(value: &str) -> Result<String, SyncError> {
    if value.is_empty()
        || value.len() > MAX_CREDENTIAL_ID_BYTES
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(SyncError::InvalidBridgeMessage(
            "credential identifier is invalid".into(),
        ));
    }
    Ok(value.to_owned())
}

fn validate_field_name(value: &str) -> Result<(), SyncError> {
    if value.len() > MAX_CREDENTIAL_FIELD_BYTES || value.chars().any(char::is_control) {
        return Err(SyncError::InvalidBridgeMessage(
            "credential field name is invalid".into(),
        ));
    }
    Ok(())
}

fn validate_secret(value: &str, maximum: usize, required: bool) -> Result<(), SyncError> {
    // C ABI consumers use NUL-terminated UTF-8. Reject embedded NUL instead of
    // letting one platform observe a silently truncated username/password.
    if (required && value.is_empty()) || value.len() > maximum || value.contains('\0') {
        return Err(SyncError::InvalidBridgeMessage(
            "credential value exceeds the shared policy".into(),
        ));
    }
    Ok(())
}

fn canonical_stored_origin(value: &str) -> Option<String> {
    if value.len() > MAX_CREDENTIAL_ORIGIN_BYTES {
        return None;
    }
    let parsed = url::Url::parse(value).ok()?;
    if parsed.scheme() != "https"
        || parsed.host_str().is_none()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.path() != "/"
        || parsed.query().is_some()
        || parsed.fragment().is_some()
    {
        return None;
    }
    Some(parsed.origin().ascii_serialization())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context() -> CredentialContext {
        CredentialContext {
            document_url: "https://bücher.example/login".into(),
            top_frame_origin: "https://xn--bcher-kva.example".into(),
            frame_origin: "https://xn--bcher-kva.example".into(),
            is_private: false,
            user_selected: true,
        }
    }

    #[test]
    fn rejects_embedded_nul_across_the_c_abi_boundary() {
        let mut value = credential();
        value.username = "user\0suffix".into();
        assert!(validate_new_credential(value, true).is_err());

        let mut value = credential();
        value.password = "secret\0suffix".into();
        assert!(validate_new_credential(value, true).is_err());
    }

    fn credential() -> NewCredential {
        NewCredential {
            context: context(),
            username_field: "email".into(),
            password_field: "password".into(),
            username: "person@example.org".into(),
            password: "correct horse battery staple".into(),
        }
    }

    fn record(id: &str) -> CredentialRecord {
        CredentialRecord {
            id: id.into(),
            origin: "https://xn--bcher-kva.example".into(),
            form_action_origin: "https://xn--bcher-kva.example".into(),
            username_field: "email".into(),
            password_field: "password".into(),
            username: "person@example.org".into(),
            password: "secret".into(),
            time_created_epoch_millis: 1,
            time_password_changed_epoch_millis: 2,
            time_last_used_epoch_millis: 3,
            times_used: 1,
        }
    }

    #[test]
    fn validates_and_canonicalizes_exact_origin_writes() {
        let value = validate_new_credential(credential(), true).unwrap();
        assert_eq!(value.origin, "https://xn--bcher-kva.example");
        let mut invalid = credential();
        invalid.password.clear();
        assert!(validate_new_credential(invalid, true).is_err());
        let mut invalid = credential();
        invalid.password = "x".repeat(MAX_CREDENTIAL_PASSWORD_BYTES + 1);
        assert!(validate_new_credential(invalid, true).is_err());
        let mut invalid = credential();
        invalid.username_field = "field\nname".into();
        assert!(validate_new_credential(invalid, true).is_err());
    }

    #[test]
    fn rejects_locked_private_cross_origin_and_non_user_actions() {
        assert!(matches!(
            validate_new_credential(credential(), false),
            Err(SyncError::VaultLocked)
        ));
        let mut invalid = credential();
        invalid.context.is_private = true;
        assert!(validate_new_credential(invalid, true).is_err());
        let mut invalid = credential();
        invalid.context.frame_origin = "https://evil.example".into();
        assert!(validate_new_credential(invalid, true).is_err());
        let mut invalid = credential();
        invalid.context.user_selected = false;
        assert!(validate_new_credential(invalid, true).is_err());
    }

    #[test]
    fn filters_untrusted_records_and_bounds_the_result() {
        let mut wrong_origin = record("wrong-origin");
        wrong_origin.origin = "https://evil.example".into();
        let mut userinfo = record("userinfo");
        userinfo.form_action_origin = "https://user@xn--bcher-kva.example".into();
        let mut oversized = record("oversized");
        oversized.password = "x".repeat(MAX_CREDENTIAL_PASSWORD_BYTES + 1);
        let mut records = vec![wrong_origin, userinfo, oversized];
        records.extend((0..=MAX_CREDENTIAL_RESULTS).map(|index| {
            let mut value = record(&format!("credential-{index}"));
            value.time_last_used_epoch_millis = index as i64;
            value
        }));
        let accepted = sanitize_credential_records(records, "https://xn--bcher-kva.example");
        assert_eq!(accepted.len(), MAX_CREDENTIAL_RESULTS);
        assert_eq!(
            accepted[0].time_last_used_epoch_millis,
            MAX_CREDENTIAL_RESULTS as i64
        );
        assert!(serde_json::to_vec(&accepted).unwrap().len() <= MAX_CREDENTIAL_OUTPUT_JSON_BYTES);
    }

    #[test]
    fn strict_json_rejects_unknown_bridge_fields() {
        let mut value = serde_json::to_value(credential()).unwrap();
        value
            .as_object_mut()
            .unwrap()
            .insert("navigation_nonce".into(), serde_json::json!("stale"));
        assert!(serde_json::from_value::<NewCredential>(value).is_err());
    }
}
