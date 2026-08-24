cmake_minimum_required(VERSION 3.21)
project(XanhNativeSyncLibraryContract LANGUAGES CXX)

if(NOT WIN32 OR NOT MSVC)
    message(FATAL_ERROR "The Xanh native Sync loader contract requires MSVC on Windows.")
endif()

enable_testing()

function(add_fake_sync_core target output_directory)
    add_library(${target} SHARED FakeXanhSyncCore.cpp)
    target_compile_features(${target} PRIVATE cxx_std_17)
    target_compile_definitions(${target} PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN UNICODE _UNICODE ${ARGN})
    target_compile_options(${target} PRIVATE /W4 /WX /permissive-)
    set_target_properties(${target} PROPERTIES
        OUTPUT_NAME xanh_sync_core
        ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/${output_directory}"
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/${output_directory}"
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/${output_directory}"
    )
endfunction()

add_fake_sync_core(XanhFakeSyncCoreValid valid)
add_fake_sync_core(XanhFakeSyncCoreBadVersion bad-version XANH_FAKE_BAD_VERSION=1)
add_fake_sync_core(XanhFakeSyncCoreNoMozilla no-mozilla XANH_FAKE_NO_MOZILLA=1)
add_fake_sync_core(XanhFakeSyncCoreMissingExport missing-export XANH_FAKE_OMIT_TOUCH=1)

add_executable(XanhNativeSyncLibraryContractTest
    ../../src/XanhNativeSyncLibrary.cpp
    ../../src/XanhNativeSyncRuntime.cpp
    XanhNativeSyncLibraryContractTest.cpp
)
target_include_directories(XanhNativeSyncLibraryContractTest PRIVATE ../../src)
target_include_directories(XanhNativeSyncLibraryContractTest PRIVATE ../../../../xanh-sync-core/include)
target_compile_features(XanhNativeSyncLibraryContractTest PRIVATE cxx_std_17)
target_compile_definitions(XanhNativeSyncLibraryContractTest PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN UNICODE _UNICODE XANH_NATIVE_SYNC_TESTING=1)
target_compile_options(XanhNativeSyncLibraryContractTest PRIVATE /W4 /WX /permissive-)
target_link_libraries(XanhNativeSyncLibraryContractTest PRIVATE wintrust)

add_test(NAME XanhNativeSyncLibraryContractTest COMMAND XanhNativeSyncLibraryContractTest
    "$<TARGET_FILE:XanhFakeSyncCoreValid>"
    "$<TARGET_FILE:XanhFakeSyncCoreBadVersion>"
    "$<TARGET_FILE:XanhFakeSyncCoreNoMozilla>"
    "$<TARGET_FILE:XanhFakeSyncCoreMissingExport>"
)
