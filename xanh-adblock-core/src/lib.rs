// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

mod ffi;

use adblock::lists::{parse_filter, ParseOptions, ParsedLine, RuleTypes};
use adblock::request::Request;
use adblock::{Engine, FilterSet};

pub const XANH_ADBLOCK_CORE_VERSION: &str = env!("CARGO_PKG_VERSION");
pub const ADBLOCK_RUST_VERSION: &str = "0.13.3";
pub const ADBLOCK_RUST_REVISION: &str = "886d45dcf5283ce8eddc6d961e7dd27966ab23f2";
pub const XANH_BASELINE_FILTER_LIST: &str = include_str!("../filters/xanh-baseline.txt");

pub const MAX_FILTER_LIST_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_FILTER_LINE_BYTES: usize = 64 * 1024;
pub const MAX_FILTER_RULES: usize = 500_000;
pub const MAX_URL_BYTES: usize = 8 * 1024;
pub const MAX_REQUEST_TYPE_BYTES: usize = 32;
pub const MAX_METHOD_BYTES: usize = 16;
pub const MAX_CONTENT_BLOCKING_RULES: usize = 150_000;
pub const MAX_CONTENT_BLOCKING_JSON_BYTES: usize = 64 * 1024 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AdblockDecision {
    pub should_block: bool,
    pub important: bool,
    pub redirect: Option<String>,
    pub rewritten_url: Option<String>,
}

#[derive(Debug, thiserror::Error, Eq, PartialEq)]
pub enum AdblockError {
    #[error("filter input contains no rules")]
    FilterInputEmpty,
    #[error("filter input exceeds {MAX_FILTER_LIST_BYTES} bytes")]
    FilterInputTooLarge,
    #[error("filter line exceeds {MAX_FILTER_LINE_BYTES} bytes")]
    FilterLineTooLarge,
    #[error("filter input exceeds {MAX_FILTER_RULES} rules")]
    TooManyFilterRules,
    #[error("request URL is empty, invalid, unsupported or exceeds {MAX_URL_BYTES} bytes")]
    InvalidRequestUrl,
    #[error("source URL is empty, invalid, unsupported or exceeds {MAX_URL_BYTES} bytes")]
    InvalidSourceUrl,
    #[error("request type is empty or exceeds {MAX_REQUEST_TYPE_BYTES} bytes")]
    InvalidRequestType,
    #[error("request method is empty or exceeds {MAX_METHOD_BYTES} bytes")]
    InvalidMethod,
    #[error("invalid network request: {0}")]
    InvalidRequest(String),
    #[error("filter input contains no successfully parsed network rules")]
    NoEffectiveNetworkRules,
    #[error("filter list cannot be converted to WebKit content-blocking rules")]
    ContentBlockingConversion,
    #[error("converted filter contains too many rules")]
    TooManyContentBlockingRules,
    #[error("converted content-blocking JSON is too large")]
    ContentBlockingJsonTooLarge,
    #[error("content-blocking JSON encoding failed: {0}")]
    ContentBlockingEncoding(String),
}

/// Immutable, thread-safe network blocker. Build a replacement engine when lists change.
pub struct AdblockEngine {
    engine: Engine,
}

impl AdblockEngine {
    pub fn from_xanh_baseline() -> Result<Self, AdblockError> {
        Self::from_filter_list(XANH_BASELINE_FILTER_LIST)
    }

    pub fn from_filter_list(filter_list: &str) -> Result<Self, AdblockError> {
        validate_filter_list(filter_list)?;
        validate_effective_network_rules(filter_list)?;
        let mut set = FilterSet::new(false);
        set.add_filter_list(
            filter_list.to_owned(),
            ParseOptions {
                rule_types: RuleTypes::NetworkOnly,
                ..ParseOptions::default()
            },
        );
        Ok(Self {
            engine: Engine::new_with_filter_set(set),
        })
    }

    pub fn check(
        &self,
        url: &str,
        source_url: &str,
        request_type: &str,
        method: &str,
    ) -> Result<AdblockDecision, AdblockError> {
        validate_web_url(url, false)?;
        validate_web_url(source_url, true)?;
        validate_bounded_token(
            request_type,
            MAX_REQUEST_TYPE_BYTES,
            AdblockError::InvalidRequestType,
        )?;
        validate_bounded_token(method, MAX_METHOD_BYTES, AdblockError::InvalidMethod)?;

        let request = Request::new(url, source_url, request_type, method)
            .map_err(|error| AdblockError::InvalidRequest(error.to_string()))?;
        let result = self.engine.check_network_request(&request);
        Ok(AdblockDecision {
            should_block: result.should_block(),
            important: result.important,
            redirect: result.redirect,
            rewritten_url: result.rewritten_url,
        })
    }
}

pub fn compile_webkit_content_blocker(filter_list: &str) -> Result<String, AdblockError> {
    validate_filter_list(filter_list)?;
    let mut set = FilterSet::new(true);
    set.add_filter_list(filter_list.to_owned(), ParseOptions::default());
    let (rules, _) = set
        .into_content_blocking()
        .map_err(|_| AdblockError::ContentBlockingConversion)?;
    if rules.is_empty() {
        return Err(AdblockError::ContentBlockingConversion);
    }
    if rules.len() > MAX_CONTENT_BLOCKING_RULES {
        return Err(AdblockError::TooManyContentBlockingRules);
    }
    let json = serde_json::to_string(&rules)
        .map_err(|error| AdblockError::ContentBlockingEncoding(error.to_string()))?;
    if json.len() > MAX_CONTENT_BLOCKING_JSON_BYTES {
        return Err(AdblockError::ContentBlockingJsonTooLarge);
    }
    Ok(json)
}

pub fn compile_xanh_baseline_for_webkit() -> Result<String, AdblockError> {
    compile_webkit_content_blocker(XANH_BASELINE_FILTER_LIST)
}

fn validate_filter_list(filter_list: &str) -> Result<(), AdblockError> {
    if filter_list.len() > MAX_FILTER_LIST_BYTES {
        return Err(AdblockError::FilterInputTooLarge);
    }
    let mut rules = 0_usize;
    for line in filter_list.lines() {
        if line.len() > MAX_FILTER_LINE_BYTES {
            return Err(AdblockError::FilterLineTooLarge);
        }
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('!') || trimmed.starts_with('[') {
            continue;
        }
        rules = rules.saturating_add(1);
        if rules > MAX_FILTER_RULES {
            return Err(AdblockError::TooManyFilterRules);
        }
    }
    if rules == 0 {
        return Err(AdblockError::FilterInputEmpty);
    }
    Ok(())
}

fn validate_effective_network_rules(filter_list: &str) -> Result<(), AdblockError> {
    let options = ParseOptions {
        rule_types: RuleTypes::NetworkOnly,
        ..ParseOptions::default()
    };
    let has_network_rule = filter_list.lines().any(|line| {
        matches!(
            parse_filter(line, false, options),
            Ok(ParsedLine::Network(filter)) if !filter.is_badfilter()
        )
    });
    if has_network_rule {
        Ok(())
    } else {
        Err(AdblockError::NoEffectiveNetworkRules)
    }
}

fn validate_web_url(value: &str, source: bool) -> Result<(), AdblockError> {
    let error = || {
        if source {
            AdblockError::InvalidSourceUrl
        } else {
            AdblockError::InvalidRequestUrl
        }
    };
    validate_bounded_nonempty(value, MAX_URL_BYTES, error())?;
    let parsed = Request::new(value, value, "document", "GET").map_err(|_| error())?;
    if !parsed.is_supported || !(parsed.is_http || parsed.is_https) {
        return Err(error());
    }
    Ok(())
}

fn validate_bounded_token(
    value: &str,
    maximum: usize,
    error: AdblockError,
) -> Result<(), AdblockError> {
    validate_bounded_nonempty(value, maximum, error)?;
    if value.bytes().all(|byte| (b'!'..=b'~').contains(&byte)) {
        Ok(())
    } else if maximum == MAX_REQUEST_TYPE_BYTES {
        Err(AdblockError::InvalidRequestType)
    } else {
        Err(AdblockError::InvalidMethod)
    }
}

fn validate_bounded_nonempty(
    value: &str,
    maximum: usize,
    error: AdblockError,
) -> Result<(), AdblockError> {
    if value.is_empty() || value.len() > maximum {
        return Err(error);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::thread;

    use static_assertions::assert_impl_all;

    use super::*;

    const RULES: &str = r#"
        ||ads.example^
        ||tracker.example^$third-party
        @@||ads.example/allowed.js$script
        example.com##.sponsored
    "#;

    #[test]
    fn engine_is_safe_to_share_across_webview_threads() {
        assert_impl_all!(AdblockEngine: Send, Sync);
        let engine = Arc::new(AdblockEngine::from_filter_list(RULES).unwrap());
        let workers: Vec<_> = (0..8)
            .map(|_| {
                let engine = Arc::clone(&engine);
                thread::spawn(move || {
                    engine
                        .check(
                            "https://ads.example/banner.js",
                            "https://news.example/article",
                            "script",
                            "GET",
                        )
                        .unwrap()
                        .should_block
                })
            })
            .collect();
        assert!(workers.into_iter().all(|worker| worker.join().unwrap()));
    }

    #[test]
    fn blocks_network_rule_and_honors_exception() {
        let engine = AdblockEngine::from_filter_list(RULES).unwrap();
        assert!(
            engine
                .check(
                    "https://ads.example/banner.js",
                    "https://news.example/article",
                    "script",
                    "GET",
                )
                .unwrap()
                .should_block
        );
        assert!(
            !engine
                .check(
                    "https://ads.example/allowed.js",
                    "https://news.example/article",
                    "script",
                    "GET",
                )
                .unwrap()
                .should_block
        );
    }

    #[test]
    fn built_in_baseline_blocks_known_ad_hosts_but_not_first_party_content() {
        let engine = AdblockEngine::from_xanh_baseline().unwrap();
        assert!(
            engine
                .check(
                    "https://securepubads.g.doubleclick.net/tag.js",
                    "https://news.example/article",
                    "script",
                    "GET",
                )
                .unwrap()
                .should_block
        );
        assert!(
            !engine
                .check(
                    "https://news.example/app.js",
                    "https://news.example/article",
                    "script",
                    "GET",
                )
                .unwrap()
                .should_block
        );
    }

    #[test]
    fn third_party_rule_uses_source_url() {
        let engine = AdblockEngine::from_filter_list(RULES).unwrap();
        assert!(
            engine
                .check(
                    "https://tracker.example/pixel.gif",
                    "https://news.example/article",
                    "image",
                    "GET",
                )
                .unwrap()
                .should_block
        );
        assert!(
            !engine
                .check(
                    "https://tracker.example/pixel.gif",
                    "https://tracker.example/home",
                    "image",
                    "GET",
                )
                .unwrap()
                .should_block
        );
    }

    #[test]
    fn validates_hot_path_inputs() {
        let engine = AdblockEngine::from_filter_list(RULES).unwrap();
        assert_eq!(
            engine.check("", "https://example.com", "other", "GET"),
            Err(AdblockError::InvalidRequestUrl)
        );
        assert_eq!(
            engine.check("https://example.com", "", "other", "GET"),
            Err(AdblockError::InvalidSourceUrl)
        );
        assert_eq!(
            engine.check("https://example.com", "not a URL", "other", "GET"),
            Err(AdblockError::InvalidSourceUrl)
        );
        assert_eq!(
            engine.check(
                "file:///tmp/page.html",
                "https://example.com",
                "other",
                "GET"
            ),
            Err(AdblockError::InvalidRequestUrl)
        );
        assert_eq!(
            engine.check(
                "https://example.com",
                "https://example.com",
                "script",
                "GET\n"
            ),
            Err(AdblockError::InvalidMethod)
        );
    }

    #[test]
    fn rejects_empty_comment_only_and_oversized_filter_input() {
        assert_eq!(
            AdblockEngine::from_filter_list("! only a comment").err(),
            Some(AdblockError::FilterInputEmpty)
        );
        let oversized_line = format!("||{}^", "a".repeat(MAX_FILTER_LINE_BYTES));
        assert_eq!(
            AdblockEngine::from_filter_list(&oversized_line).err(),
            Some(AdblockError::FilterLineTooLarge)
        );
        let too_many_rules = "a\n".repeat(MAX_FILTER_RULES + 1);
        assert_eq!(
            AdblockEngine::from_filter_list(&too_many_rules).err(),
            Some(AdblockError::TooManyFilterRules)
        );
    }

    #[test]
    fn request_engine_rejects_zero_effective_network_rules() {
        for rules in [
            "# comments only",
            "example.com##.sponsored",
            "||ads.example^$badfilter",
        ] {
            assert_eq!(
                AdblockEngine::from_filter_list(rules).err(),
                Some(AdblockError::NoEffectiveNetworkRules),
                "unexpected result for {rules:?}"
            );
        }
    }

    #[test]
    fn webkit_conversion_rejects_zero_effective_rules() {
        for rules in ["# comments only", "/[/"] {
            assert_eq!(
                compile_webkit_content_blocker(rules).err(),
                Some(AdblockError::ContentBlockingConversion),
                "unexpected result for {rules:?}"
            );
        }
    }

    #[test]
    fn converts_network_and_cosmetic_rules_for_webkit() {
        let json = compile_webkit_content_blocker(RULES).unwrap();
        let rules: serde_json::Value = serde_json::from_str(&json).unwrap();
        let rules = rules.as_array().unwrap();
        assert!(!rules.is_empty());
        assert!(rules.iter().any(|rule| rule["action"]["type"] == "block"));
        assert!(rules
            .iter()
            .any(|rule| rule["action"]["type"] == "css-display-none"));
    }
}
