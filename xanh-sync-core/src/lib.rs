// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

mod bridge;
mod config;
mod controller;
mod ffi;
mod migration;
mod scheduler;
mod tabs_data;
mod vault;

#[cfg(feature = "mozilla")]
pub mod mozilla;

pub use bridge::*;
pub use config::*;
pub use controller::*;
pub use migration::*;
pub use scheduler::*;
pub use tabs_data::*;
pub use vault::*;

pub const XANH_SYNC_CORE_VERSION: &str = env!("CARGO_PKG_VERSION");
pub const APPLICATION_SERVICES_VERSION: &str = "155.0";
pub const APPLICATION_SERVICES_REVISION: &str = "c0fd8cea40c9b5dafc6604831f7bd7a8c096d313";

uniffi::setup_scaffolding!();
