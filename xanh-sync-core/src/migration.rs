use serde::{Deserialize, Serialize};

use crate::SyncError;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "kebab-case")]
pub enum MigrationState {
    NotStarted,
    BackupCreated,
    Imported,
    Committed,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct MigrationMarker {
    pub version: u32,
    pub state: MigrationState,
    pub source_bookmark_count: u64,
    pub source_history_count: u64,
    pub imported_bookmark_count: u64,
    pub imported_history_count: u64,
    pub source_backup_sha256: Option<String>,
}

impl Default for MigrationMarker {
    fn default() -> Self {
        Self {
            version: 1,
            state: MigrationState::NotStarted,
            source_bookmark_count: 0,
            source_history_count: 0,
            imported_bookmark_count: 0,
            imported_history_count: 0,
            source_backup_sha256: None,
        }
    }
}

impl MigrationMarker {
    pub fn mark_backup_created(
        &mut self,
        checksum: String,
        bookmark_count: u64,
        history_count: u64,
    ) -> Result<(), SyncError> {
        if checksum.len() != 64 || !checksum.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(SyncError::Migration(
                "backup checksum is not SHA-256".into(),
            ));
        }
        if self.state == MigrationState::Committed {
            return Ok(());
        }
        self.source_backup_sha256 = Some(checksum.to_ascii_lowercase());
        self.source_bookmark_count = bookmark_count;
        self.source_history_count = history_count;
        self.state = MigrationState::BackupCreated;
        Ok(())
    }

    pub fn mark_imported(&mut self, bookmarks: u64, history: u64) -> Result<(), SyncError> {
        if self.state != MigrationState::BackupCreated && self.state != MigrationState::Imported {
            return Err(SyncError::Migration(
                "a verified backup is required before import".into(),
            ));
        }
        self.imported_bookmark_count = bookmarks;
        self.imported_history_count = history;
        self.state = MigrationState::Imported;
        Ok(())
    }

    pub fn commit(&mut self) -> Result<(), SyncError> {
        if self.state == MigrationState::Committed {
            return Ok(());
        }
        if self.state != MigrationState::Imported
            || self.source_backup_sha256.is_none()
            || self.imported_bookmark_count < self.source_bookmark_count
            || self.imported_history_count < self.source_history_count
        {
            return Err(SyncError::Migration(
                "import counts do not cover the source data".into(),
            ));
        }
        self.state = MigrationState::Committed;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migration_is_verified_and_idempotent() {
        let mut marker = MigrationMarker::default();
        marker.mark_backup_created("a".repeat(64), 2, 3).unwrap();
        marker.mark_imported(2, 2).unwrap();
        assert!(marker.commit().is_err());
        marker.mark_imported(2, 3).unwrap();
        marker.commit().unwrap();
        marker.commit().unwrap();
        assert_eq!(marker.state, MigrationState::Committed);
    }
}
