cmake_minimum_required(VERSION 3.24)
project(XanhWindowsHelloContract LANGUAGES CXX)

if(NOT WIN32)
    message(FATAL_ERROR "The Xanh Windows Hello contract test requires Windows")
endif()

enable_testing()

add_executable(XanhWindowsHelloContractTest
    ../../src/XanhWindowsHello.cpp
    XanhWindowsHelloContractTest.cpp
)
target_include_directories(XanhWindowsHelloContractTest PRIVATE ../../src)
target_compile_features(XanhWindowsHelloContractTest PRIVATE cxx_std_20)
target_compile_definitions(XanhWindowsHelloContractTest PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_compile_options(XanhWindowsHelloContractTest PRIVATE /W4 /WX /permissive-)
target_link_libraries(XanhWindowsHelloContractTest PRIVATE windowsapp)

add_test(NAME XanhWindowsHelloContractTest COMMAND XanhWindowsHelloContractTest)
