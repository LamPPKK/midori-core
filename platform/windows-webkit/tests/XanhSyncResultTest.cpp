#include "XanhSyncResult.h"

#include <cstdlib>
#include <iostream>
#include <limits>
#include <string>

namespace {

unsigned assertions;

void expect(bool condition, const char* message)
{
    ++assertions;
    if (condition)
        return;
    std::cerr << message << '\n';
    std::exit(1);
}

} // namespace

int main()
{
    using XanhSyncResultParser::Status;
    expect(XanhSyncResultParser::parse(
               "{\"next_sync_allowed_epoch_seconds\":null,\"status\":\"success\"}")
            == Status::success,
        "The core's canonical key order was rejected.");
    expect(XanhSyncResultParser::parse(
               "{\"status\":\"partial\",\"next_sync_allowed_epoch_seconds\":123}")
            == Status::partial,
        "The alternate valid key order was rejected.");
    expect(XanhSyncResultParser::parse(
               "{\"status\":\"network-error\",\"next_sync_allowed_epoch_seconds\":0}")
            == Status::networkError,
        "A valid zero next-sync time was rejected.");
    expect(XanhSyncResultParser::parse(
               "{\"status\":\"auth-error\",\"next_sync_allowed_epoch_seconds\":18446744073709551615}")
            == Status::authError,
        "The maximum next-sync timestamp was rejected.");
    expect(XanhSyncResultParser::parse(
               "{\"status\":\"backed-off\",\"next_sync_allowed_epoch_seconds\":null}")
            == Status::backedOff,
        "A backed-off result was rejected.");
    expect(!XanhSyncResultParser::parse(
               "{\"status\":\"idle\",\"next_sync_allowed_epoch_seconds\":null}"),
        "A non-terminal status was accepted.");
    expect(!XanhSyncResultParser::parse(
               "{\"status\":\"success\",\"next_sync_allowed_epoch_seconds\":01}"),
        "A leading-zero timestamp was accepted.");
    expect(!XanhSyncResultParser::parse(
               "{\"status\":\"success\",\"next_sync_allowed_epoch_seconds\":18446744073709551616}"),
        "An overflowing timestamp was accepted.");
    expect(!XanhSyncResultParser::parse(
               "{\"status\":\"success\",\"next_sync_allowed_epoch_seconds\":null,\"extra\":true}"),
        "An unknown Sync-result field was accepted.");
    expect(!XanhSyncResultParser::parse(
               "{ \"status\":\"success\",\"next_sync_allowed_epoch_seconds\":null}"),
        "A non-canonical result was accepted.");

    std::cout << "Xanh Sync-result policy passed " << assertions
              << " assertions\n";
}
