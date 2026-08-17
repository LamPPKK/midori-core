use serde::{Deserialize, Serialize};
use url::Url;

use crate::SyncError;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "kebab-case", tag = "kind")]
pub enum AccountServer {
    Mozilla,
    SelfHosted {
        accounts_url: String,
        token_server_url: String,
    },
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct SyncConfig {
    pub server: AccountServer,
    pub client_id: String,
    pub redirect_uri: String,
    pub device_name: String,
    pub device_kind: DeviceKind,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "kebab-case")]
pub enum DeviceKind {
    Desktop,
    Mobile,
    Tablet,
    Tv,
    Vr,
}

impl SyncConfig {
    pub fn validate(&self) -> Result<(), SyncError> {
        if self.client_id.trim().is_empty() {
            return Err(SyncError::InvalidConfig("client_id is empty".into()));
        }
        if self.device_name.trim().is_empty() {
            return Err(SyncError::InvalidConfig("device_name is empty".into()));
        }
        let redirect = Url::parse(&self.redirect_uri)
            .map_err(|_| SyncError::InvalidConfig("redirect_uri is invalid".into()))?;
        if redirect.scheme() == "http"
            || redirect.host_str().is_none()
            || !redirect.username().is_empty()
            || redirect.password().is_some()
            || redirect.fragment().is_some()
        {
            return Err(SyncError::InvalidConfig(
                "redirect_uri must be an absolute non-cleartext callback without userinfo or a fragment"
                    .into(),
            ));
        }
        if let AccountServer::SelfHosted {
            accounts_url,
            token_server_url,
        } = &self.server
        {
            validate_https_endpoint("accounts_url", accounts_url)?;
            validate_https_endpoint("token_server_url", token_server_url)?;
        }
        Ok(())
    }

    pub fn displayed_domain(&self) -> Result<String, SyncError> {
        let endpoint = match &self.server {
            AccountServer::Mozilla => "https://accounts.firefox.com",
            AccountServer::SelfHosted { accounts_url, .. } => accounts_url,
        };
        Url::parse(endpoint)
            .ok()
            .and_then(|url| url.host_str().map(ToOwned::to_owned))
            .ok_or_else(|| SyncError::InvalidConfig("account server has no domain".into()))
    }
}

fn validate_https_endpoint(name: &str, value: &str) -> Result<(), SyncError> {
    let url =
        Url::parse(value).map_err(|_| SyncError::InvalidConfig(format!("{name} is invalid")))?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err(SyncError::InvalidConfig(format!(
            "{name} must be an HTTPS origin without userinfo"
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(server: AccountServer) -> SyncConfig {
        SyncConfig {
            server,
            client_id: "client".into(),
            redirect_uri: "xanh-browser://accounts/oauth".into(),
            device_name: "Xanh Browser".into(),
            device_kind: DeviceKind::Desktop,
        }
    }

    #[test]
    fn self_hosted_requires_https() {
        let bad = config(AccountServer::SelfHosted {
            accounts_url: "http://accounts.example".into(),
            token_server_url: "https://sync.example/token".into(),
        });
        assert!(bad.validate().is_err());
        let userinfo = config(AccountServer::SelfHosted {
            accounts_url: "https://:secret@accounts.example".into(),
            token_server_url: "https://sync.example/token".into(),
        });
        assert!(userinfo.validate().is_err());
    }

    #[test]
    fn reports_account_domain_before_oauth() {
        let value = config(AccountServer::SelfHosted {
            accounts_url: "https://accounts.example.org".into(),
            token_server_url: "https://sync.example.org/token".into(),
        });
        assert_eq!(value.displayed_domain().unwrap(), "accounts.example.org");
    }

    #[test]
    fn oauth_redirect_is_restricted_to_an_absolute_safe_callback() {
        assert!(config(AccountServer::Mozilla).validate().is_ok());
        for redirect in [
            "http://example.test/oauth",
            "javascript:alert(1)",
            "xanh-browser://user@accounts/oauth",
            "xanh-browser://accounts/oauth#secret",
        ] {
            let mut value = config(AccountServer::Mozilla);
            value.redirect_uri = redirect.into();
            assert!(value.validate().is_err(), "accepted {redirect}");
        }
    }
}
