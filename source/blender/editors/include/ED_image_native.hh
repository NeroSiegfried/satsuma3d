/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup editors
 *
 * The Image Editor for a native interface, see `image_native.cc`.
 */

#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace blender {
struct bContext;
namespace io::serialize {
class DictionaryValue;
}
}  // namespace blender

namespace blender::ed::image {

/** The shown image's picture, in the scene's view transform, top row first. */
struct NativeImagePixels {
  std::string name;
  /** As sent, which may be smaller than the image. */
  int width = 0;
  int height = 0;
  /** The image's own size. */
  int full_width = 0;
  int full_height = 0;
  /** Straight RGBA, 8 bits each. Empty without an image. */
  std::vector<uint8_t> rgba;
};

/** The images, and the one its view's \a state shows with its details. */
std::shared_ptr<io::serialize::DictionaryValue> native_image_read(
    bContext *C, const io::serialize::DictionaryValue &state);
/** An edit of the images: why it failed, if it did. */
std::string native_image_edit(bContext *C, const io::serialize::DictionaryValue &edit);
/** The shown image's picture, when it changed since it was last asked for. */
bool native_image_pixels(bContext *C,
                         const io::serialize::DictionaryValue &state,
                         NativeImagePixels &r_pixels);
/** What an edge of #NativeImageUVs shows (ROUND5 9G.3). */
enum NativeUVEdgeFlag : uint8_t {
  NATIVE_UV_EDGE_SELECTED = 1 << 0,
  NATIVE_UV_EDGE_SEAM = 1 << 1,
  /** Its first or second point is a selected UV vertex. */
  NATIVE_UV_EDGE_VERT_A = 1 << 2,
  NATIVE_UV_EDGE_VERT_B = 1 << 3,
};

/**
 * What the UV Editor draws over the image (ROUND5 9G.3): every edge it shows with a flag each, and
 * the selected faces' outlines for their fill, sent once. Blender's rules decide what shows: in
 * Edit Mode with UV Sync Selection every face the 3D View shows, marked by the mesh's selection;
 * without it only the selected faces, marked by the UV selection.
 */
struct NativeImageUVs {
  /** Two points each, in UV space. */
  std::vector<float> edges;
  /** One #NativeUVEdgeFlag set for each edge. */
  std::vector<uint8_t> edge_flags;
  /** The selected faces' corners, one face after the other, and how many each has. */
  std::vector<float> faces;
  std::vector<int> face_sizes;
  /** Which of #face_sizes is the active face, or -1. */
  int active_face = -1;
  /** A very large mesh was cut short: not all of it is drawn. */
  bool capped = false;

  bool operator==(const NativeImageUVs &other) const = default;
};

/** The active mesh's UVs as the UV Editor draws them. */
NativeImageUVs native_image_uvs(bContext *C);

}  // namespace blender::ed::image
