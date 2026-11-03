# SPDX-FileCopyrightText: 2026 Blender Foundation
#
# SPDX-License-Identifier: GPL-2.0-or-later

# The C++ runtime, headers only. The Swift runtime in `swift/` is built with the iOS app, see
# `source/creator/CMakeLists.txt`.
add_library(extern_flatbuffers INTERFACE)
target_include_directories(extern_flatbuffers SYSTEM INTERFACE "include")
add_library(bf::extern::flatbuffers ALIAS extern_flatbuffers)
