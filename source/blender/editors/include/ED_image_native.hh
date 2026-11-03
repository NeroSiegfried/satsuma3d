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
/** The active mesh's UV edges, two points each, in UV space. */
std::vector<float> native_image_uvs(bContext *C);

}  // namespace blender::ed::image
