/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * The scene as live 3D geometry for a volumetric window on Apple Vision Pro, which RealityKit
 * draws beside the editor.
 *
 * After the depsgraph updates, the visible evaluated meshes are gathered into flat arrays ready
 * for the GPU: positions, normals and triangle indices. A mesh is sent only when it is new or
 * its geometry changed, which Blender stamps on each object; instances of the same mesh share
 * it. Each frame also lists every instance, with its transform, color and selection, which is
 * small. The native side takes a frame whole, without copying, when it is ready to draw.
 */

#include <atomic>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "BKE_context.hh"
#include "BKE_layer.hh"
#include "BKE_lib_id.hh"
#include "BKE_material.hh"
#include "BKE_mesh.hh"
#include "BKE_mesh_wrapper.hh"
#include "BKE_object.hh"
#include "BKE_object_types.hh"

#include "BLI_hash.hh"
#include "BLI_math_vector.h"
#include "BLI_math_vector_types.hh"
#include "BLI_vector.hh"
#include "BLI_math_matrix.h"
#include "BLI_string.h"

#include "DEG_depsgraph.hh"
#include "DEG_depsgraph_query.hh"

#include "DNA_material_types.h"
#include "DNA_mesh_types.h"
#include "DNA_object_types.h"
#include "DNA_scene_types.h"

#include "ED_object.hh"
#include "ED_undo.hh"

#include "WM_api.hh"
#include "WM_types.hh"

#include "wm_apple_ios_volume.h"

namespace blender {

/* -------------------------------------------------------------------- */
/** \name Frames
 * \{ */

struct VolumeMesh {
  uint64_t key = 0;
  /* Interleaved position and normal, six floats a vertex. */
  Vector<float> vertices;
  Vector<uint32_t> indices;
  float bounds_min[3] = {0, 0, 0};
  float bounds_max[3] = {0, 0, 0};
};

struct VolumeInstance {
  WMVolumeInstance info;
  char name[MAX_ID_NAME];
};

struct VolumeFrame {
  Vector<std::unique_ptr<VolumeMesh>> meshes;
  Vector<VolumeInstance> instances;
  float bounds_min[3] = {0, 0, 0};
  float bounds_max[3] = {0, 0, 0};
  /** Everything is sent again: the native side starts over. */
  bool reset = false;
};

static std::mutex volume_mutex;
static std::unique_ptr<VolumeFrame> volume_pending;
static std::atomic<bool> volume_ready{false};
static std::atomic<bool> volume_visible{false};
static std::atomic<bool> volume_reset{true};

/** \} */

/* -------------------------------------------------------------------- */
/** \name Gathering
 * \{ */

/** Bounds of the meshes sent, which instances of them still use. */
struct SentMesh {
  float bounds_min[3];
  float bounds_max[3];
};

static std::unordered_map<uint64_t, SentMesh> volume_sent;
static uint64_t volume_update_count = UINT64_MAX;

/** A mesh as triangles, flat- or smooth-shaded as Blender shades it. */
static std::unique_ptr<VolumeMesh> volume_mesh_build(const Mesh &mesh, const uint64_t key)
{
  const Span<float3> positions = mesh.vert_positions();
  const Span<int> corner_verts = mesh.corner_verts();
  const Span<int3> tris = mesh.corner_tris();
  if (positions.is_empty() || tris.is_empty()) {
    return nullptr;
  }
  auto result = std::make_unique<VolumeMesh>();
  result->key = key;
  result->indices.resize(tris.size() * 3);

  const bke::MeshNormalDomain domain = mesh.normals_domain();
  if (domain == bke::MeshNormalDomain::Point) {
    /* Smooth: the vertices as they are, shared by their triangles. */
    const Span<float3> normals = mesh.vert_normals();
    result->vertices.resize(positions.size() * 6);
    float *dst = result->vertices.data();
    for (const int i : positions.index_range()) {
      copy_v3_v3(dst + i * 6, positions[i]);
      copy_v3_v3(dst + i * 6 + 3, normals[i]);
    }
    uint32_t *index = result->indices.data();
    for (const int3 &tri : tris) {
      *index++ = uint32_t(corner_verts[tri[0]]);
      *index++ = uint32_t(corner_verts[tri[1]]);
      *index++ = uint32_t(corner_verts[tri[2]]);
    }
  }
  else {
    /* Flat or split normals: a vertex for each face corner. */
    const int corners = corner_verts.size();
    result->vertices.resize(corners * 6);
    float *dst = result->vertices.data();
    if (domain == bke::MeshNormalDomain::Face) {
      const Span<float3> face_normals = mesh.face_normals();
      const Span<int> corner_faces = mesh.corner_to_face_map();
      for (const int c : IndexRange(corners)) {
        copy_v3_v3(dst + c * 6, positions[corner_verts[c]]);
        copy_v3_v3(dst + c * 6 + 3, face_normals[corner_faces[c]]);
      }
    }
    else {
      const Span<float3> corner_normals = mesh.corner_normals();
      for (const int c : IndexRange(corners)) {
        copy_v3_v3(dst + c * 6, positions[corner_verts[c]]);
        copy_v3_v3(dst + c * 6 + 3, corner_normals[c]);
      }
    }
    uint32_t *index = result->indices.data();
    for (const int3 &tri : tris) {
      *index++ = uint32_t(tri[0]);
      *index++ = uint32_t(tri[1]);
      *index++ = uint32_t(tri[2]);
    }
  }

  INIT_MINMAX(result->bounds_min, result->bounds_max);
  for (const float3 &position : positions) {
    minmax_v3v3_v3(result->bounds_min, result->bounds_max, position);
  }
  return result;
}

static void volume_color(const Object *ob, float r_color[4])
{
  const Material *material = BKE_object_material_get_eval(const_cast<Object *>(ob), 1);
  if (material) {
    r_color[0] = material->r;
    r_color[1] = material->g;
    r_color[2] = material->b;
    r_color[3] = material->a;
  }
  else {
    r_color[0] = r_color[1] = r_color[2] = 0.8f;
    r_color[3] = 1.0f;
  }
}

/** Gathers a frame when the scene changed; the last one stays pending until it is taken. */
void ios_volume_build(bContext *C)
{
  if (!volume_visible.load()) {
    return;
  }
  Depsgraph *depsgraph = CTX_data_depsgraph_pointer(C);
  if (!depsgraph || !DEG_is_fully_evaluated(depsgraph)) {
    return;
  }
  const bool reset = volume_reset.exchange(false);
  const uint64_t update_count = DEG_get_update_count(depsgraph);
  if (!reset && update_count == volume_update_count) {
    return;
  }
  volume_update_count = update_count;
  if (reset) {
    volume_sent.clear();
  }

  auto frame = std::make_unique<VolumeFrame>();
  frame->reset = reset;
  std::unordered_set<uint64_t> used;
  INIT_MINMAX(frame->bounds_min, frame->bounds_max);

  DEGObjectIterSettings settings = {nullptr};
  settings.depsgraph = depsgraph;
  settings.flags = DEG_ITER_OBJECT_FLAG_LINKED_DIRECTLY | DEG_ITER_OBJECT_FLAG_LINKED_VIA_SET |
                   DEG_ITER_OBJECT_FLAG_VISIBLE | DEG_ITER_OBJECT_FLAG_DUPLI;
  DEG_OBJECT_ITER_BEGIN (&settings, ob) {
    Mesh *mesh = BKE_object_get_evaluated_mesh(ob);
    if (!mesh) {
      continue;
    }
    /* The edit-mode mesh is drawn from the edit data: make the arrays it is read from. */
    BKE_mesh_wrapper_ensure_mdata(mesh);
    const DupliObject *dupli = data_.dupli_object_current;
    const Object *owner = dupli ? data_.dupli_parent : ob;
    const Object *owner_orig = DEG_get_original(owner);

    /* A mesh changes with its object's geometry; instances share their source's. */
    uint64_t key;
    if (dupli) {
      key = get_default_hash(uint64_t(uintptr_t(mesh)), uint64_t(uintptr_t(mesh->vert_positions().data())),
                             mesh->verts_num, mesh->corners_num);
    }
    else {
      key = get_default_hash(owner_orig->id.session_uid, ob->runtime->last_update_geometry);
    }
    if (used.insert(key).second && volume_sent.find(key) == volume_sent.end()) {
      std::unique_ptr<VolumeMesh> built = volume_mesh_build(*mesh, key);
      if (!built) {
        continue;
      }
      SentMesh sent;
      copy_v3_v3(sent.bounds_min, built->bounds_min);
      copy_v3_v3(sent.bounds_max, built->bounds_max);
      volume_sent[key] = sent;
      frame->meshes.append(std::move(built));
    }
    const auto sent = volume_sent.find(key);
    if (sent == volume_sent.end()) {
      continue;
    }

    VolumeInstance instance{};
    instance.info.mesh = key;
    instance.info.id = dupli ? get_default_hash(owner_orig->id.session_uid,
                                                uint64_t(dupli->persistent_id[0]),
                                                uint64_t(dupli->persistent_id[1])) :
                               uint64_t(owner_orig->id.session_uid);
    memcpy(instance.info.matrix, ob->object_to_world().ptr(), sizeof(float[16]));
    volume_color(ob, instance.info.color);
    instance.info.selected = (owner->base_flag & BASE_SELECTED) != 0;
    STRNCPY(instance.name, owner_orig->id.name + 2);

    /* The scene's bounds, from each instance's box. */
    for (int corner = 0; corner < 8; corner++) {
      const float local[3] = {(corner & 1) ? sent->second.bounds_max[0] : sent->second.bounds_min[0],
                              (corner & 2) ? sent->second.bounds_max[1] : sent->second.bounds_min[1],
                              (corner & 4) ? sent->second.bounds_max[2] : sent->second.bounds_min[2]};
      float world[3];
      mul_v3_m4v3(world, reinterpret_cast<const float(*)[4]>(instance.info.matrix), local);
      minmax_v3v3_v3(frame->bounds_min, frame->bounds_max, world);
    }
    frame->instances.append(instance);
  }
  DEG_OBJECT_ITER_END;

  /* Meshes no instance uses any more are forgotten; one coming back is sent again. */
  for (auto it = volume_sent.begin(); it != volume_sent.end();) {
    it = used.count(it->first) ? std::next(it) : volume_sent.erase(it);
  }

  std::lock_guard lock(volume_mutex);
  if (volume_pending) {
    /* Not taken yet: its meshes still go, unless a newer one replaced them. */
    for (std::unique_ptr<VolumeMesh> &mesh : volume_pending->meshes) {
      if (used.count(mesh->key)) {
        frame->meshes.append(std::move(mesh));
      }
    }
    frame->reset |= volume_pending->reset;
  }
  volume_pending = std::move(frame);
  volume_ready.store(true);
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Commands
 * \{ */

static Object *volume_object(bContext *C, const char *name)
{
  Main *bmain = CTX_data_main(C);
  return reinterpret_cast<Object *>(BKE_libblock_find_name(bmain, ID_OB, name));
}

/** Where a move began, so each step moves from there. */
static float volume_move_start[4][4];

bool ios_volume_command(bContext *C, const StringRef setting, const StringRef value)
{
  if (setting == "volume_visible") {
    const bool visible = value == "1";
    if (visible && !volume_visible.load()) {
      volume_reset.store(true);
    }
    volume_visible.store(visible);
    return true;
  }
  Scene *scene = CTX_data_scene(C);
  ViewLayer *view_layer = CTX_data_view_layer(C);
  if (setting == "volume_select") {
    /* "name" selects only it, "+name" toggles it in the selection, "" deselects all. */
    const bool extend = value.startswith("+");
    const std::string name(extend ? value.drop_prefix(1) : value);
    BKE_view_layer_synced_ensure(scene, view_layer);
    if (!extend) {
      BKE_view_layer_base_deselect_all(scene, view_layer);
    }
    if (Object *ob = name.empty() ? nullptr : volume_object(C, name.c_str())) {
      if (Base *base = BKE_view_layer_base_find(view_layer, ob)) {
        const bool select = !(extend && (base->flag & BASE_SELECTED));
        ed::object::base_select(base, select ? ed::object::BA_SELECT : ed::object::BA_DESELECT);
        if (select) {
          ed::object::base_activate(C, base);
        }
      }
    }
    DEG_id_tag_update(&scene->id, ID_RECALC_SELECT);
    WM_event_add_notifier(C, NC_SCENE | ND_OB_SELECT, scene);
    ED_undo_push(C, "Select");
    return true;
  }
  if (setting == "volume_move") {
    /* "name|phase|dx|dy|dz": a move in world space from where it began. */
    char name[MAX_ID_NAME], phase[16];
    float delta[3];
    if (sscanf(std::string(value).c_str(), "%63[^|]|%15[^|]|%f|%f|%f", name, phase, &delta[0],
               &delta[1], &delta[2]) != 5)
    {
      return true;
    }
    Object *ob = volume_object(C, name);
    if (!ob || !BKE_id_is_editable(CTX_data_main(C), &ob->id)) {
      return true;
    }
    if (STREQ(phase, "begin")) {
      copy_m4_m4(volume_move_start, ob->object_to_world().ptr());
      return true;
    }
    float matrix[4][4];
    copy_m4_m4(matrix, volume_move_start);
    add_v3_v3(matrix[3], delta);
    BKE_object_apply_mat4(ob, matrix, true, true);
    DEG_id_tag_update(&ob->id, ID_RECALC_TRANSFORM);
    WM_event_add_notifier(C, NC_OBJECT | ND_TRANSFORM, ob);
    if (STREQ(phase, "end")) {
      ED_undo_push(C, "Move");
    }
    return true;
  }
  return false;
}

/** \} */

}  // namespace blender

/* -------------------------------------------------------------------- */
/** \name Native API
 * \{ */

using namespace blender;

extern "C" WMVolumeFrame *WM_apple_ios_volume_take()
{
  if (!volume_ready.load()) {
    return nullptr;
  }
  std::lock_guard lock(volume_mutex);
  volume_ready.store(false);
  return reinterpret_cast<WMVolumeFrame *>(volume_pending.release());
}

extern "C" void WM_apple_ios_volume_free(WMVolumeFrame *frame)
{
  delete reinterpret_cast<VolumeFrame *>(frame);
}

extern "C" void WM_apple_ios_volume_info(const WMVolumeFrame *frame, WMVolumeFrameInfo *r_info)
{
  const VolumeFrame &data = *reinterpret_cast<const VolumeFrame *>(frame);
  r_info->mesh_count = int(data.meshes.size());
  r_info->instance_count = int(data.instances.size());
  r_info->reset = data.reset;
  copy_v3_v3(r_info->bounds_min, data.bounds_min);
  copy_v3_v3(r_info->bounds_max, data.bounds_max);
}

extern "C" void WM_apple_ios_volume_mesh(const WMVolumeFrame *frame, int index, WMVolumeMesh *r_mesh)
{
  const VolumeMesh &mesh = *reinterpret_cast<const VolumeFrame *>(frame)->meshes[index];
  r_mesh->key = mesh.key;
  r_mesh->vertices = mesh.vertices.data();
  r_mesh->vertex_count = int(mesh.vertices.size() / 6);
  r_mesh->indices = mesh.indices.data();
  r_mesh->index_count = int(mesh.indices.size());
  copy_v3_v3(r_mesh->bounds_min, mesh.bounds_min);
  copy_v3_v3(r_mesh->bounds_max, mesh.bounds_max);
}

extern "C" const WMVolumeInstance *WM_apple_ios_volume_instance(const WMVolumeFrame *frame,
                                                                 int index,
                                                                 const char **r_name)
{
  const VolumeInstance &instance = reinterpret_cast<const VolumeFrame *>(frame)->instances[index];
  *r_name = instance.name;
  return &instance.info;
}

/** \} */
