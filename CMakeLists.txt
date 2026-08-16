cmake_minimum_required(VERSION 3.24)
project(xanh-browser VERSION 1.0.0 LANGUAGES C)

include(GNUInstallDirs)
include(CTest)
find_package(PkgConfig REQUIRED)
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
find_package(Vala REQUIRED)
vala_require("0.56.0")
include(ValaPrecompile)

pkg_check_modules(XANH REQUIRED IMPORTED_TARGET
    glib-2.0>=2.74
    gio-2.0>=2.74
    gtk4>=4.10
    webkitgtk-6.0>=2.52.0
    javascriptcoregtk-6.0>=2.52.0
    libsoup-3.0
    sqlite3
    libpeas-2>=2.0
    gcr-4
    json-glib-1.0)

set(XANH_VALA_PACKAGES
    gio-2.0
    gtk4
    webkitgtk-6.0
    javascriptcoregtk-6.0
    libsoup-3.0
    sqlite3
    libpeas-2
    gcr-4
    json-glib-1.0)
set(XANH_VALA_OPTIONS
    --target-glib=2.74
    --fatal-warnings
    --enable-checking)
set(XANH_PLUGIN_DIR "${CMAKE_INSTALL_FULL_LIBDIR}/xanh-browser")
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/desktop")
configure_file(
    desktop/plugin-api.vala.in
    "${CMAKE_CURRENT_BINARY_DIR}/desktop/plugin-api.vala"
    @ONLY)

add_compile_options(
    -Wall -Wextra -Werror
    -Wno-unused-parameter
    -Wno-unused-variable
    -Wno-unused-but-set-variable)
if(CMAKE_C_COMPILER_ID MATCHES "Clang")
    add_compile_options(-Wno-tautological-pointer-compare)
endif()
if(CMAKE_C_COMPILER_ID STREQUAL "GNU")
    # Vala 0.56 emits these constructs for automatic string properties and
    # sqlite3_exec's optional error-message out parameter. Keep every other
    # compiler warning fatal.
    add_compile_options(-Wno-discarded-qualifiers -Wno-address)
endif()
include_directories(
    "${CMAKE_CURRENT_SOURCE_DIR}/desktop"
    "${CMAKE_CURRENT_BINARY_DIR}/desktop"
    ${XANH_INCLUDE_DIRS})

vala_precompile(XANH_CORE_C xanh-browser-core
    "${CMAKE_CURRENT_BINARY_DIR}/desktop/plugin-api.vala"
    desktop/database.vala
PACKAGES ${XANH_VALA_PACKAGES}
OPTIONS ${XANH_VALA_OPTIONS}
DIRECTORY desktop
GENERATE_VAPI xanh-browser-core
GENERATE_HEADER xanh-browser-core)

add_library(xanh-browser-core SHARED ${XANH_CORE_C})
set_target_properties(xanh-browser-core PROPERTIES
    VERSION 2.0.0
    SOVERSION 2
    OUTPUT_NAME xanh-browser-core)
target_link_libraries(xanh-browser-core PRIVATE PkgConfig::XANH)

vala_precompile(XANH_APP_C xanh-browser
    desktop/address-resolver.vala
    desktop/profile-importer.vala
    desktop/plugin-manager.vala
    desktop/web-extension-bridge.vala
    desktop/browser-window.vala
    desktop/application.vala
    desktop/main.vala
PACKAGES ${XANH_VALA_PACKAGES}
OPTIONS ${XANH_VALA_OPTIONS}
DIRECTORY desktop-app
CUSTOM_VAPIS "${CMAKE_CURRENT_BINARY_DIR}/desktop/xanh-browser-core.vapi")

add_executable(xanh-browser ${XANH_APP_C})
target_include_directories(xanh-browser PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/desktop")
target_link_libraries(xanh-browser PRIVATE xanh-browser-core PkgConfig::XANH)

function(add_xanh_plugin target source manifest)
    vala_precompile(${target}_C ${target}
        ${source}
    PACKAGES ${XANH_VALA_PACKAGES}
    OPTIONS ${XANH_VALA_OPTIONS}
    DIRECTORY "plugins/${target}"
    CUSTOM_VAPIS "${CMAKE_CURRENT_BINARY_DIR}/desktop/xanh-browser-core.vapi")
    add_library(${target} MODULE ${${target}_C})
    target_include_directories(${target} PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/desktop")
    target_link_libraries(${target} PRIVATE xanh-browser-core PkgConfig::XANH)
    configure_file(${manifest} "${CMAKE_CURRENT_BINARY_DIR}/${target}.plugin" COPYONLY)
    install(TARGETS ${target} LIBRARY DESTINATION "${XANH_PLUGIN_DIR}")
    install(FILES ${manifest} DESTINATION "${XANH_PLUGIN_DIR}")
endfunction()

add_xanh_plugin(xanh-adblock plugins2/adblock.vala plugins2/xanh-adblock.plugin)
add_xanh_plugin(xanh-bookmarks plugins2/bookmarks.vala plugins2/xanh-bookmarks.plugin)
add_xanh_plugin(xanh-session plugins2/session.vala plugins2/xanh-session.plugin)
add_xanh_plugin(xanh-colorful-tabs plugins2/colorful-tabs.vala plugins2/xanh-colorful-tabs.plugin)
add_xanh_plugin(xanh-status-clock plugins2/status-clock.vala plugins2/xanh-status-clock.plugin)
add_xanh_plugin(xanh-status-features plugins2/status-features.vala plugins2/xanh-status-features.plugin)

function(add_xanh_test target)
    set(options WEB_EXTENSION)
    set(oneValueArgs SOURCE)
    set(multiValueArgs SUPPORT)
    cmake_parse_arguments(TEST "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})
    set(test_sources ${TEST_SOURCE})
    if(TEST_SUPPORT)
        list(APPEND test_sources ${TEST_SUPPORT})
    endif()
    vala_precompile(${target}_C ${target}
        ${test_sources}
    PACKAGES ${XANH_VALA_PACKAGES}
    OPTIONS ${XANH_VALA_OPTIONS}
    DIRECTORY "tests/${target}"
    CUSTOM_VAPIS "${CMAKE_CURRENT_BINARY_DIR}/desktop/xanh-browser-core.vapi")
    add_executable(${target} ${${target}_C})
    target_include_directories(${target} PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/desktop")
    target_link_libraries(${target} PRIVATE xanh-browser-core PkgConfig::XANH)
    add_test(NAME ${target} COMMAND ${target})
endfunction()

if(BUILD_TESTING)
    add_xanh_test(database-test SOURCE tests-modern/database-test.vala)
    add_xanh_test(address-resolver-test SOURCE tests-modern/address-resolver-test.vala
        SUPPORT desktop/address-resolver.vala)
    add_xanh_test(importer-test SOURCE tests-modern/importer-test.vala
        SUPPORT desktop/profile-importer.vala)
    add_xanh_test(web-extension-test SOURCE tests-modern/web-extension-test.vala
        SUPPORT desktop/web-extension-bridge.vala)
    add_xanh_test(plugin-test SOURCE tests-modern/plugin-test.vala
        SUPPORT desktop/plugin-manager.vala)
    add_dependencies(plugin-test
        xanh-adblock xanh-bookmarks xanh-session xanh-colorful-tabs
        xanh-status-clock xanh-status-features)
    set_tests_properties(plugin-test PROPERTIES
        ENVIRONMENT "XANH_TEST_PLUGIN_DIR=${CMAKE_CURRENT_BINARY_DIR}")
    add_xanh_test(application-smoke-test SOURCE tests-modern/application-smoke-test.vala
        SUPPORT
            desktop/address-resolver.vala
            desktop/profile-importer.vala
            desktop/plugin-manager.vala
            desktop/web-extension-bridge.vala
            desktop/browser-window.vala
            desktop/application.vala)
    add_dependencies(application-smoke-test
        xanh-adblock xanh-bookmarks xanh-session xanh-colorful-tabs
        xanh-status-clock xanh-status-features)
    set_tests_properties(application-smoke-test PROPERTIES
        ENVIRONMENT "XANH_PLUGIN_DIR=${CMAKE_CURRENT_BINARY_DIR}"
        TIMEOUT 20)
endif()

configure_file(
    data-xanh/io.github.lamppkk.xanhbrowser.service
    "${CMAKE_CURRENT_BINARY_DIR}/io.github.lamppkk.xanhbrowser.service"
    @ONLY)

install(TARGETS xanh-browser xanh-browser-core
    RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}"
    LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}")
install(FILES data-xanh/io.github.lamppkk.xanhbrowser.desktop
    DESTINATION "${CMAKE_INSTALL_DATADIR}/applications")
install(FILES data-xanh/io.github.lamppkk.xanhbrowser.metainfo.xml
    DESTINATION "${CMAKE_INSTALL_DATADIR}/metainfo")
install(FILES data-xanh/io.github.lamppkk.xanhbrowser.gschema.xml
    DESTINATION "${CMAKE_INSTALL_DATADIR}/glib-2.0/schemas")
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/io.github.lamppkk.xanhbrowser.service"
    DESTINATION "${CMAKE_INSTALL_DATADIR}/dbus-1/services")
install(FILES data-xanh/io.github.lamppkk.xanhbrowser.svg
    DESTINATION "${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps")
install(FILES COPYING README.md RELEASING.md
    DESTINATION "${CMAKE_INSTALL_DOCDIR}")

add_custom_target(validate-metadata
    COMMAND glib-compile-schemas --strict --dry-run "${CMAKE_CURRENT_SOURCE_DIR}/data-xanh"
    COMMAND appstreamcli validate --no-net "${CMAKE_CURRENT_SOURCE_DIR}/data-xanh/io.github.lamppkk.xanhbrowser.metainfo.xml"
    VERBATIM)
