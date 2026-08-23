cmake_minimum_required(VERSION 3.24)
project(XanhNativeCredentialPickerContract LANGUAGES CXX)

if(NOT WIN32 OR NOT MSVC)
    message(FATAL_ERROR "The Xanh native credential-picker contract requires MSVC on Windows.")
endif()

enable_testing()

add_executable(XanhNativeCredentialPickerContractTest
    ../../src/XanhCredentialRecords.cpp
    ../../src/XanhDpapiSecretStore.cpp
    ../../src/XanhNativeCredentialPicker.cpp
    ../../src/XanhNativeSyncLibrary.cpp
    ../../src/XanhNativeSyncRuntime.cpp
    ../../src/XanhWindowsHello.cpp
    XanhNativeCredentialPickerContractTest.cpp
)
target_include_directories(XanhNativeCredentialPickerContractTest PRIVATE
    ../../src
    ../../../../xanh-sync-core/include
)
target_compile_features(XanhNativeCredentialPickerContractTest PRIVATE cxx_std_20)
target_compile_definitions(XanhNativeCredentialPickerContractTest PRIVATE
    NOMINMAX
    WIN32_LEAN_AND_MEAN
    UNICODE
    _UNICODE
)
target_compile_options(XanhNativeCredentialPickerContractTest PRIVATE /W4 /WX /permissive-)
target_link_libraries(XanhNativeCredentialPickerContractTest PRIVATE
    bcrypt
    comctl32
    crypt32
    normaliz
    shell32
    uuid
    wintrust
    windowsapp
)

add_test(NAME XanhNativeCredentialPickerContractTest
    COMMAND XanhNativeCredentialPickerContractTest)
