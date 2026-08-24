cmake_minimum_required(VERSION 3.25)
project(XanhPortableBackupTests LANGUAGES CXX)

enable_testing()

add_executable(XanhPortableBackupTests
    ../../src/XanhPortableBackup.cpp
    XanhPortableBackupTest.cpp
)
target_compile_features(XanhPortableBackupTests PRIVATE cxx_std_17)
target_compile_definitions(XanhPortableBackupTests PRIVATE
    NOMINMAX
    UNICODE
    _UNICODE
    XANH_PORTABLE_BACKUP_TESTING
)
if(MSVC)
    target_compile_options(XanhPortableBackupTests PRIVATE /W4 /WX /permissive-)
else()
    target_compile_options(XanhPortableBackupTests PRIVATE -Wall -Wextra -Werror)
endif()
target_link_libraries(XanhPortableBackupTests PRIVATE bcrypt crypt32 normaliz)

add_test(NAME XanhPortableBackupTests COMMAND XanhPortableBackupTests)
