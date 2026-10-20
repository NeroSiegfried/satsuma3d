/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * The scene as live 3D geometry for a volumetric window, see `wm_apple_ios_volume.cc`. Plain C,
 * for the native side's bridging header.
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** A frame of the scene, taken whole by the native side and freed when it is done with it. */
typedef struct WMVolumeFrame WMVolumeFrame;

typedef struct WMVolumeFrameInfo {
  int mesh_count;
  int instance_count;
  /** Everything was sent again: what was shown before is gone. */
  bool reset;
  float bounds_min[3];
  float bounds_max[3];
} WMVolumeFrameInfo;

/** A mesh new to the native side or changed: triangles, six floats a vertex (position, normal),
 * in its object's space. The arrays belong to the frame. */
typedef struct WMVolumeMesh {
  uint64_t key;
  const float *vertices;
  int vertex_count;
  const uint32_t *indices;
  int index_count;
  float bounds_min[3];
  float bounds_max[3];
} WMVolumeMesh;

/** Something drawn: a mesh, sent in this frame or before, where and how it shows. */
typedef struct WMVolumeInstance {
  uint64_t id;
  uint64_t mesh;
  /** Object to world, column-major, in Blender's Z-up meters. */
  float matrix[16];
  float color[4];
  bool selected;
} WMVolumeInstance;

/** The newest frame, or none when nothing changed since the last was taken. */
WMVolumeFrame *WM_apple_ios_volume_take(void);
void WM_apple_ios_volume_free(WMVolumeFrame *frame);
void WM_apple_ios_volume_info(const WMVolumeFrame *frame, WMVolumeFrameInfo *r_info);
void WM_apple_ios_volume_mesh(const WMVolumeFrame *frame, int index, WMVolumeMesh *r_mesh);
/** `r_name` names the object to select or move, the instancer's for an instance. */
const WMVolumeInstance *WM_apple_ios_volume_instance(const WMVolumeFrame *frame,
                                                     int index,
                                                     const char **r_name);

#ifdef __cplusplus
}
#endif
