#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

class XanhDpapiSecretStore {
public:
    enum class Secret : std::uint32_t {
        accountState = 1,
        syncState,
        loginsKey,
        schedule,
        engineSelection,
        disconnectIntent,
    };

    enum class Status {
        success,
        notFound,
        invalidInput,
        ioError,
        protectionError,
        corruptData,
    };

    struct ReadResult {
        Status status { Status::ioError };
        std::string value;
    };

    static constexpr std::size_t maximumPlaintextBytes = 4 * 1024 * 1024;

    // Resolves the per-user production directory below FOLDERID_LocalAppData.
    // An empty result means the Windows known-folder lookup failed.
    static std::wstring defaultStorageRoot();

    // The explicit root is primarily for isolated tests. Production callers
    // must pass defaultStorageRoot(); secret names are never caller-controlled.
    explicit XanhDpapiSecretStore(std::wstring storageRoot);

    ReadResult read(Secret) const;
    Status write(Secret, std::string_view) const;
    Status remove(Secret) const;
    Status removeAll() const;

private:
    std::wstring m_storageRoot;
};
