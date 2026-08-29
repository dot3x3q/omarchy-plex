# PlexMpv — compiled QML module wrapping libmpv via KDE's MpvQt.
#
# Builds ONE shared library that is both the QML backing library and its plugin,
# so the deployed module is just `libplexmpv.so` + `qmldir` + `plexmpv.qmltypes`
# in a directory named PlexMpv. That matters because Quickshell loads this at
# runtime through the QML engine's import path — there is no application to link
# the backing library into.
#
# Build:   cmake -B build && cmake --build build
# Dev run: QML2_IMPORT_PATH=$PWD/build/qml quickshell ...
# Install: see the install() rules at the bottom (needs root for /usr).

cmake_minimum_required(VERSION 3.21)

project(PlexMpv VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Qml Quick)
find_package(MpvQt REQUIRED)

qt_standard_project_setup(REQUIRES 6.5)

# QTP0001 NEW puts the module under a `qml/` subdirectory of the build tree and
# adds it to the engine's import path automatically, which is what makes the
# QML2_IMPORT_PATH dev workflow above work without extra plumbing.
qt_policy(SET QTP0001 NEW)

qt_add_qml_module(plexmpv
    URI PlexMpv
    VERSION 1.0
    # Lay the build tree out exactly as the deployed tree looks (a PlexMpv/
    # directory under an import root), so build/qml can be used as-is via
    # QML2_IMPORT_PATH and qmllint resolves the module.
    OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/qml/PlexMpv"
    # Same target for library and plugin: one .so to install, and the generated
    # qmldir gets the `classname` entry the engine needs to find the registrar.
    PLUGIN_TARGET plexmpv
    # The engine must load the plugin to get the C++ types — there is no QML-only
    # fallback here, so the plugin is not optional.
    NO_PLUGIN_OPTIONAL
    SOURCES
        mpvvideo.h
        mpvvideo.cpp
)

target_link_libraries(plexmpv
    PRIVATE
        Qt6::Core
        Qt6::Gui
        Qt6::Qml
        Qt6::Quick
        MpvQt::MpvQt
)

# ---- install ----
# Default to the Qt installation's own QML dir (/usr/lib/qt6/qml on Arch), which
# is on the engine's default import path so no env var is needed. Overridable
# with -DQML_INSTALL_DIR=... for a non-root dev install; never hard-code a path.
if(NOT DEFINED QML_INSTALL_DIR)
    set(QML_INSTALL_DIR "${QT6_INSTALL_PREFIX}/${QT6_INSTALL_QML}")
endif()
set(PLEXMPV_MODULE_DIR "${QML_INSTALL_DIR}/PlexMpv")

install(TARGETS plexmpv
    LIBRARY DESTINATION "${PLEXMPV_MODULE_DIR}"
    RUNTIME DESTINATION "${PLEXMPV_MODULE_DIR}"
)
install(FILES
    "${CMAKE_CURRENT_BINARY_DIR}/qml/PlexMpv/qmldir"
    "${CMAKE_CURRENT_BINARY_DIR}/qml/PlexMpv/plexmpv.qmltypes"
    DESTINATION "${PLEXMPV_MODULE_DIR}"
)
