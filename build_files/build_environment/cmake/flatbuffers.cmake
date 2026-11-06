# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

# The C++ runtime (headers only), the schema compiler `flatc`, and the Swift runtime's sources,
# which the iOS app builds with its own code. Cross-compiled libraries build no `flatc`: the
# host's is added to them, as the build runs it.
if(WITH_APPLE_CROSSPLATFORM)
  set(FLATBUFFERS_FLATC OFF)
else()
  set(FLATBUFFERS_FLATC ON)
endif()

set(FLATBUFFERS_EXTRA_ARGS
  -DFLATBUFFERS_BUILD_TESTS=OFF
  -DFLATBUFFERS_BUILD_FLATLIB=OFF
  -DFLATBUFFERS_BUILD_FLATHASH=OFF
  -DFLATBUFFERS_BUILD_FLATC=${FLATBUFFERS_FLATC}
)

ExternalProject_Add(external_flatbuffers
  URL file://${PACKAGE_DIR}/${FLATBUFFERS_FILE}
  DOWNLOAD_DIR ${DOWNLOAD_DIR}
  URL_HASH ${FLATBUFFERS_HASH_TYPE}=${FLATBUFFERS_HASH}
  PREFIX ${BUILD_DIR}/flatbuffers

  CMAKE_ARGS
    -DCMAKE_INSTALL_PREFIX=${LIBDIR}/flatbuffers
    ${DEFAULT_CMAKE_FLAGS}
    ${FLATBUFFERS_EXTRA_ARGS}

  INSTALL_DIR ${LIBDIR}/flatbuffers
)

ExternalProject_Add_Step(external_flatbuffers after_install
  COMMAND ${CMAKE_COMMAND} -E copy_directory
    ${BUILD_DIR}/flatbuffers/src/external_flatbuffers/swift/Sources/FlatBuffers
    ${LIBDIR}/flatbuffers/swift

  DEPENDEES install
)

if(WIN32)
  ExternalProject_Add_Step(external_flatbuffers after_install_harvest
    COMMAND ${CMAKE_COMMAND} -E copy_directory
      ${LIBDIR}/flatbuffers/
      ${HARVEST_TARGET}/flatbuffers

    DEPENDEES after_install
  )
else()
  harvest(external_flatbuffers flatbuffers/include flatbuffers/include "*.h")
  harvest(external_flatbuffers flatbuffers/swift flatbuffers/swift "*.swift")
  if(FLATBUFFERS_FLATC)
    harvest(external_flatbuffers flatbuffers/bin flatbuffers/bin "flatc")
  endif()
endif()
