cmake_minimum_required(VERSION 3.21)
project(XanhDpapiSecretStoreContract LANGUAGES CXX)

if(NOT WIN32 OR NOT MSVC)
    message(FATAL_ERROR "The Xanh DPAPI secret-store contract requires MSVC on Windows.")
endif()

enable_testing()

add_executable(XanhDpapiSecretStoreContractTest
    ../../src/XanhDpapiSecretStore.cpp
    XanhDpapiSecretStoreContractTest.cpp
)
target_include_directories(XanhDpapiSecretStoreContractTest PRIVATE ../../src)
target_compile_features(XanhDpapiSecretStoreContractTest PRIVATE cxx_std_17)
target_compile_definitions(XanhDpapiSecretStoreContractTest PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN UNICODE _UNICODE)
target_compile_options(XanhDpapiSecretStoreContractTest PRIVATE /W4 /WX /permissive-)
target_link_libraries(XanhDpapiSecretStoreContractTest PRIVATE bcrypt crypt32 shell32 uuid)

add_test(NAME XanhDpapiSecretStoreContractTest COMMAND XanhDpapiSecretStoreContractTest)
