/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup spseq
 *
 * The storyboard for a native interface: the workspace's sequencer scene and the shots in it,
 * each a scene strip with a small picture of its first frame, and edits on them. A hidden
 * Sequencer stands in for the one the native interface draws, so its operators run as they do
 * there, and moving its playhead switches the window to the shot under it, as Blender's
 * Storyboarding workspace does.
 */

#include <algorithm>
#include <chrono>
#include <map>
#include <optional>
#include <string>

#include "MEM_guardedalloc.h"

#include "BLI_fileops.h"
#include "BLI_listbase.h"
#include "BLI_math_base.h"
#include "BLI_math_vector.h"
#include "BLI_serialize.hh"
#include "BLI_string.h"
#include "BLI_string_ref.hh"
#include "BLI_set.hh"
#include "BLI_vector.hh"

#include "DNA_grease_pencil_types.h"
#include "DNA_object_types.h"
#include "DNA_scene_types.h"
#include "DNA_screen_types.h"
#include "DNA_sequence_types.h"
#include "DNA_space_types.h"
#include "DNA_userdef_types.h"
#include "DNA_workspace_types.h"

#include "BKE_appdir.hh"
#include "BLT_translation.hh"
#include "BKE_collection.hh"
#include "BKE_curves.hh"
#include "BKE_context.hh"
#include "BKE_global.hh"
#include "BKE_grease_pencil.hh"
#include "BKE_layer.hh"
#include "BKE_lib_id.hh"
#include "BKE_main.hh"
#include "BKE_paint.hh"
#include "BKE_scene.hh"
#include "BKE_screen.hh"
#include "BKE_undo_system.hh"
#include "BKE_wm_runtime.hh"

#include "AS_asset_library.hh"
#include "AS_asset_representation.hh"

#include "ED_asset.hh"
#include "ED_object.hh"
#include "ED_screen.hh"
#include "ED_sequencer.hh"
#include "ED_undo.hh"

#include "GPU_framebuffer.hh"

#include "IMB_imbuf.hh"
#include "IMB_imbuf_types.hh"

#include "RNA_access.hh"
#include "RNA_prototypes.hh"

#include "SEQ_add.hh"
#include "SEQ_relations.hh"
#include "SEQ_render.hh"
#include "SEQ_select.hh"
#include "SEQ_sequencer.hh"
#include "SEQ_transform.hh"

#include "WM_api.hh"
#include "WM_toolsystem.hh"
#include "WM_types.hh"

#include "DEG_depsgraph.hh"
#include "DEG_depsgraph_build.hh"

namespace blender::ed::vse {

using namespace io::serialize;

namespace {

/** Kept for the session, as Blender's own would be. */
ScrArea *native_sequencer_area(bContext *C)
{
  static ScrArea *area = nullptr;
  if (area == nullptr) {
    area = MEM_new<ScrArea>("native sequencer");
    area->spacetype = SPACE_SEQ;
    /* On no screen, as Blender's own off-screen areas: an operator run in it shows no redo panel
     * there (ROUND6 EDIT-1: a registered operator crashed placing one). */
    area->flag |= AREA_FLAG_OFFSCREEN;
    area->type = BKE_spacetype_from_id(SPACE_SEQ);
    SpaceLink *link = area->type->create(area, CTX_data_scene(C));
    BLI_addtail(&area->spacedata, link);
    std::swap(area->regionbase, link->regionbase);
    for (ARegion &region : area->regionbase) {
      region.runtime->type = BKE_regiontype_from_id(area->type, region.regiontype);
    }
    reinterpret_cast<SpaceSeq *>(link)->view = SEQ_VIEW_SEQUENCE;
  }
  return area;
}

/** The hidden Sequencer as the context's area while shots are read or edited. */
struct SequencerSpaceContext {
  bContext *C;
  ScrArea *previous_area;
  ARegion *previous_region;

  explicit SequencerSpaceContext(bContext *context) : C(context)
  {
    previous_area = CTX_wm_area(C);
    previous_region = CTX_wm_region(C);
    ScrArea *area = native_sequencer_area(C);
    CTX_wm_area_set(C, area);
    CTX_wm_region_set(C, BKE_area_find_region_type(area, RGN_TYPE_WINDOW));
  }

  ~SequencerSpaceContext()
  {
    CTX_wm_area_set(C, previous_area);
    CTX_wm_region_set(C, previous_region);
  }
};

/** A picture of one frame of a shot's scene, and the version of the scene it shows. */
struct Picture {
  std::string path;
  /** The one before, still on disk: the native interface may not have shown its successor yet,
   * and a picture gone from under it would leave a gap for a moment. */
  std::string previous;
  int version = -1;
};
/** By scene and frame of its content, so moving or trimming a shot keeps its pictures. */
std::map<std::string, Picture> pictures;
/** Counts each scene's changes: a picture of an older version is drawn again. */
std::map<std::string, int> scene_versions;
/** The undo step last seen: a new one means the shot drawn in may look different. */
const void *last_undo_step = nullptr;
/** When the shot drawn in last changed: its pictures wait for a pause in the drawing. */
std::chrono::steady_clock::time_point last_change;
int picture_count = 0;

/** The Grease Pencil the shot shown is drawn on: the active object, or none. */
GreasePencil *shown_grease_pencil(bContext *C)
{
  Object *object = CTX_data_active_object(C);
  return object && object->type == OB_GREASE_PENCIL ? reinterpret_cast<GreasePencil *>(object->data) :
                                                      nullptr;
}

/** Its layers, the top one first as Blender's layer list shows them. */
void append_layers(bContext *C, DictionaryValue &result)
{
  GreasePencil *grease_pencil = shown_grease_pencil(C);
  if (!grease_pencil) {
    return;
  }
  result.append_str("layers_owner", grease_pencil->id.name + 2);
  auto layers = result.append_array("layers");
  const bke::greasepencil::Layer *active = grease_pencil->get_active_layer();
  const Span<const bke::greasepencil::Layer *> all = grease_pencil->layers();
  for (int i = all.size() - 1; i >= 0; i--) {
    const bke::greasepencil::Layer &layer = *all[i];
    auto item = layers->append_dict();
    item->append_str("name", layer.name());
    item->append_int("visible", layer.is_visible());
    item->append_int("locked", layer.is_locked());
    item->append_int("active", &layer == active);
    /* Where its drawings begin, in its scene's frames. */
    auto keys = item->append_array("keys");
    for (const int frame : layer.sorted_keys()) {
      keys->append_int(frame);
    }
  }
}

/** A flag sent as a number or as true or false. */
bool lookup_flag(const DictionaryValue &query, const StringRef key, const bool fallback)
{
  if (const std::optional<int64_t> number = query.lookup_int(key)) {
    return *number != 0;
  }
  if (const auto *value = query.lookup(key)) {
    if (const BooleanValue *flag = (*value)->as_boolean_value()) {
      return flag->value();
    }
  }
  return fallback;
}

bke::greasepencil::Layer *find_layer(GreasePencil &grease_pencil, const std::string &name)
{
  bke::greasepencil::TreeNode *node = grease_pencil.find_node_by_name(name);
  return node && node->is_layer() ? &node->as_layer() : nullptr;
}

/** Where the shot's drawings begin: the keys of the Grease Pencil in its scene, in the edit's
 * time, within the shot. */
Vector<int> drawing_starts(const Scene &edit, const Strip &strip)
{
  Set<int> frames;
  const Scene &shot = *strip.scene;
  FOREACH_SCENE_OBJECT_BEGIN (const_cast<Scene *>(&shot), object) {
    if (object->type != OB_GREASE_PENCIL) {
      continue;
    }
    const GreasePencil &grease_pencil = *reinterpret_cast<const GreasePencil *>(object->data);
    for (const bke::greasepencil::Layer *layer : grease_pencil.layers()) {
      for (const int key : layer->sorted_keys()) {
        frames.add(strip.start + key - shot.r.sfra - strip.anim_startofs);
      }
    }
  }
  FOREACH_SCENE_OBJECT_END;
  const int left = strip.left_handle();
  const int right = strip.right_handle(&edit);
  Vector<int> result;
  for (const int frame : frames) {
    if (frame >= left && frame < right) {
      result.append(frame);
    }
  }
  std::sort(result.begin(), result.end());
  return result;
}

/** A layer's drawings at these frames moved by some frames: those landing on others replace
 * them, as keys do. */
void move_frames(GreasePencil &grease_pencil,
                 bke::greasepencil::Layer &layer,
                 Span<int> frames_in,
                 const int delta)
{
  Vector<int> frames;
  for (const int frame : frames_in) {
    if (layer.frames().contains(frame)) {
      frames.append(frame);
    }
  }
  if (delta == 0 || frames.is_empty()) {
    return;
  }
  std::sort(frames.begin(), frames.end());
  if (delta > 0) {
    std::reverse(frames.begin(), frames.end());
  }
  const Set<int> moving(frames);
  for (const int frame : frames) {
    const int target = frame + delta;
    if (!moving.contains(target) && layer.frames().contains(target)) {
      grease_pencil.remove_frames(layer, {target});
    }
  }
  for (const int frame : frames) {
    grease_pencil.insert_duplicate_frame(layer, frame, frame + delta, true);
    grease_pencil.remove_frames(layer, {frame});
  }
}

/** Frames sent as a list of numbers. */
Vector<int> lookup_frames(const DictionaryValue &query)
{
  Vector<int> frames;
  if (const ArrayValue *list = query.lookup_array("frames")) {
    for (const std::shared_ptr<Value> &element : list->elements()) {
      if (const IntValue *number = element->as_int_value()) {
        frames.append(int(number->value()));
      }
    }
  }
  return frames;
}

/** Undo steps of the storyboard's own edits, which change no shot's pictures. */
bool storyboard_step(const char *name)
{
  const StringRef step = name;
  return step.endswith(" Shot") || step.startswith("Trim Shot") || step.startswith("Select") ||
         step.startswith("Move") || step.startswith("Add Strip") || step.startswith("Delete") ||
         step.startswith("Duplicate");
}

std::string picture_key(const Strip &strip, const int timeline_frame)
{
  return std::string(strip.scene->id.name + 2) + "#" + std::to_string(timeline_frame - strip.start);
}

/** Draws one frame of a shot as the Sequencer's preview shows it, `height` pixels high, at the
 * size it is shown rather than the scene's own. */
std::string render_picture(bContext *C, Scene *sequencer_scene, Strip *strip,
                           const int timeline_frame, const int height)
{
  Scene *shot = strip->scene;
  Main *bmain = CTX_data_main(C);
  Depsgraph *depsgraph = CTX_data_expect_evaluated_depsgraph(C);
  const float aspect = float(shot->r.xsch * shot->r.xasp) /
                       float(max_ff(1.0f, shot->r.ysch * shot->r.yasp));
  const int width = max_ii(1, int(height * aspect));
  seq::RenderData context = {};
  seq::render_new_render_data(
      bmain, depsgraph, sequencer_scene, width, height, SEQ_RENDER_SIZE_SCENE, nullptr, &context);
  context.skip_cache = true;
  /* Rendering moves the shot's scene to the frame, and draws it at its own resolution: both put
   * back after, so the scene being drawn in is not disturbed. */
  const int frame = shot->r.cfra;
  const float subframe = shot->r.subframe;
  const short size = shot->r.size;
  shot->r.size = short(clamp_i(int(ceilf(100.0f * height / max_ii(1, shot->r.ysch))), 1, 100));
  const short is_break = G.is_break;
  G.is_break = false;
  /* Drawn offscreen; the window's own frame-buffer is bound again after, untouched. */
  gpu::FrameBuffer *framebuffer = GPU_framebuffer_active_get();
  ImBuf *ibuf = seq::render_give_ibuf_direct(&context, float(timeline_frame), strip);
  if (framebuffer) {
    GPU_framebuffer_bind(framebuffer);
  }
  G.is_break = is_break;
  shot->r.size = size;
  shot->r.cfra = frame;
  shot->r.subframe = subframe;
  if (!ibuf) {
    return "";
  }
  if (ibuf->float_buffer.data) {
    seq::render_imbuf_from_sequencer_space(sequencer_scene, ibuf);
    IMB_byte_from_float(ibuf);
  }
  ibuf->planes = 24;
  ibuf->ftype = IMB_FTYPE_JPG;
  ibuf->foptions.quality = 85;
  /* A new name for each version, so UIKit does not show an image it cached. */
  const std::string path = std::string(BKE_tempdir_session()) + "storyboard_" +
                           std::to_string(++picture_count) + ".jpg";
  const bool saved = IMB_save_image(ibuf, path.c_str(), IB_byte_data);
  IMB_freeImBuf(ibuf);
  return saved ? path : "";
}

std::shared_ptr<DictionaryValue> read_storyboard(bContext *C,
                                                 const DictionaryValue *state,
                                                 const bool draw)
{
  auto read = std::make_shared<DictionaryValue>();
  DictionaryValue &result = *read;
  Scene *scene = CTX_data_sequencer_scene(C);
  WorkSpace *workspace = CTX_wm_workspace(C);
  Editing *ed = scene ? seq::editing_get(scene) : nullptr;
  result.append_int("available", scene != nullptr);
  if (!scene) {
    return read;
  }
  result.append_str("scene", scene->id.name + 2);
  result.append_int("start", scene->r.sfra);
  result.append_int("end", scene->r.efra);
  result.append_int("frame", scene->r.cfra);
  result.append_double("fps", double(scene->r.frs_sec) / double(max_ff(scene->r.frs_sec_base, 1e-6f)));
  result.append_int("sync", workspace && (workspace->flags & WORKSPACE_SYNC_SCENE_TIME));
  result.append_int("playing", ED_screen_animation_playing(CTX_wm_manager(C)) != nullptr);
  /* Playing loops within the preview range, which the storyboard sets to the frames in view. */
  result.append_int("loop", (scene->r.flag & SCER_PRV_RANGE) != 0);
  result.append_int("loop_start", scene->r.psfra);
  result.append_int("loop_end", scene->r.pefra);
  const Scene *window_scene = CTX_data_scene(C);
  result.append_str("shown", window_scene ? window_scene->id.name + 2 : "");
  /* The scenes a shot can show instead, all but the edit's own. */
  auto scenes = result.append_array("scenes");
  for (const Scene &other : CTX_data_main(C)->scenes) {
    if (&other != scene) {
      scenes->append_str(other.id.name + 2);
    }
  }

  /* The scene templates a new shot can start from: the scene assets of every library, loaded
   * in the background, listed once they are. */
  const AssetLibraryReference all_library = asset_system::all_library_reference();
  asset::list::storage_fetch(&all_library, C);
  auto templates = result.append_array("templates");
  asset::list::iterate(all_library, [&](asset_system::AssetRepresentation &asset) {
    if (asset.get_id_type() == ID_SCE) {
      auto item = templates->append_dict();
      item->append_str("name", asset.get_name());
      item->append_str("id", asset.full_path());
    }
    return true;
  });

  /* A new undo step, other than the storyboard's own: the shot being drawn in may look
   * different now. */
  const wmWindowManager *wm = CTX_wm_manager(C);
  const UndoStep *undo_step = wm->runtime->undo_stack ? wm->runtime->undo_stack->step_active :
                                                         nullptr;
  if (undo_step != last_undo_step) {
    last_undo_step = undo_step;
    if (window_scene && !(undo_step && storyboard_step(undo_step->name))) {
      scene_versions[window_scene->id.name + 2]++;
      last_change = std::chrono::steady_clock::now();
    }
  }

  append_layers(C, result);

  /* Pictures every so many frames along each shot, as many as fit side by side where the native
   * interface shows them, `height` pixels high. */
  const int step = state ? max_ii(1, int(state->lookup_int("step").value_or(12))) : 12;
  const int height = state ? clamp_i(int(state->lookup_int("height").value_or(96)), 16, 256) : 96;

  struct Wanted {
    Strip *strip;
    int frame;
    std::string key;
    /** Drawn first: the shot drawn in, then those nearest the playhead. */
    int priority;
  };
  Vector<Wanted> wanted;
  auto strips = result.append_array("strips");
  const Strip *active = seq::select_active_get(scene);
  if (ed) {
    for (Strip &strip : *seq::active_seqbase_get(ed)) {
      const int left = strip.left_handle();
      const int right = strip.right_handle(scene);
      auto item = strips->append_dict();
      /* Sound and effect strips, which the storyboard does not edit: drawn as locked blocks
       * where they are, moved with the rest when shots make room (ROUND6 EDIT-10, D17). */
      if (strip.is_effect() || strip.type == STRIP_TYPE_SOUND) {
        PointerRNA ptr = RNA_pointer_create_discrete(&scene->id, RNA_Strip, &strip);
        PropertyRNA *type = RNA_struct_find_property(&ptr, "type");
        const char *kind = nullptr;
        if (type) {
          RNA_property_enum_name_gettexted(C, &ptr, type, RNA_property_enum_get(&ptr, type), &kind);
        }
        item->append_str("name", strip.name + 2);
        item->append_int("channel", strip.channel);
        item->append_int("start", left);
        item->append_int("end", right);
        item->append_int("locked", 1);
        item->append_str("kind", kind ? kind : IFACE_("Strip"));
        item->append_int("muted", (strip.flag & SEQ_MUTE) != 0);
        item->append_int("color", strip.color_tag);
        continue;
      }
      item->append_str("name", strip.name + 2);
      item->append_int("channel", strip.channel);
      item->append_int("start", left);
      item->append_int("end", right);
      item->append_int("scene_strip", strip.type == STRIP_TYPE_SCENE);
      item->append_str("scene", strip.scene ? strip.scene->id.name + 2 : "");
      item->append_int("template", strip.scene && strip.scene->id.asset_data);
      item->append_int("selected", (strip.flag & SEQ_SELECT) != 0);
      item->append_int("active", &strip == active);
      item->append_int("muted", (strip.flag & SEQ_MUTE) != 0);
      item->append_int("color", strip.color_tag);
      if (strip.type != STRIP_TYPE_SCENE || !strip.scene) {
        continue;
      }
      const Scene &shot = *strip.scene;
      /* Its scene's frames in the edit's: plus this. */
      item->append_int("offset", strip.start - shot.r.sfra - strip.anim_startofs);
      item->append_double("aspect", double(shot.r.xsch * shot.r.xasp) /
                                        double(max_ff(1.0f, shot.r.ysch * shot.r.yasp)));
      const int version = scene_versions[shot.id.name + 2];
      /* Where each drawing starts, marked on the shot, and pictured there whatever the step. */
      const Vector<int> starts = drawing_starts(*scene, strip);
      auto keys = item->append_array("keys");
      for (const int start : starts) {
        keys->append_int(start);
      }
      auto list = item->append_array("pictures");
      /* At whole steps of the shot's content, the first before or at its start, and at each
       * drawing's start, steps just before one left out. */
      Vector<int> frames;
      const int content = strip.start;
      for (int frame = content + int(floorf(float(left - content) / step)) * step; frame < right;
           frame += step)
      {
        const bool crowded = std::any_of(starts.begin(), starts.end(), [&](const int start) {
          return start > frame && start - frame < step / 2;
        });
        if (!crowded) {
          frames.append(frame);
        }
      }
      for (const int start : starts) {
        if (!frames.contains(start)) {
          frames.append(start);
        }
      }
      std::sort(frames.begin(), frames.end());
      for (const int frame : frames) {
        const int at = max_ii(frame, left);
        const std::string key = picture_key(strip, frame);
        const auto found = pictures.find(key);
        if (found != pictures.end() && !found->second.path.empty()) {
          /* An older picture shows until the new one replaces it. */
          auto pair = list->append_array();
          pair->append_int(frame);
          pair->append_str(found->second.path);
        }
        if (found == pictures.end() || found->second.version != version) {
          const int distance = abs(at - scene->r.cfra);
          wanted.append({&strip, at, key, (strip.scene == window_scene ? 0 : 100000) + distance});
        }
      }
    }
  }
  /* A few at a time, as long as the window keeps its frame rate, once drawing pauses. */
  const bool drawing = std::chrono::steady_clock::now() - last_change < std::chrono::milliseconds(600);
  if (draw && !drawing && !wanted.is_empty()) {
    std::sort(wanted.begin(), wanted.end(),
              [](const Wanted &a, const Wanted &b) { return a.priority < b.priority; });
    const auto begin = std::chrono::steady_clock::now();
    for (const Wanted &item : wanted) {
      if (std::chrono::steady_clock::now() - begin > std::chrono::milliseconds(12)) {
        break;
      }
      Picture &picture = pictures[item.key];
      const std::string path = render_picture(C, scene, item.strip, item.frame, height);
      if (!path.empty()) {
        if (!picture.previous.empty()) {
          BLI_delete(picture.previous.c_str(), false, false);
        }
        picture.previous = picture.path;
        picture.path = path;
      }
      /* Tried for this version, drawn or not, so a shot that cannot be drawn is not tried
       * over and over. */
      picture.version = scene_versions[item.strip->scene->id.name + 2];
    }
  }
  result.append_int("pending", !wanted.is_empty());
  return read;
}

Strip *find_strip(Scene *scene, const DictionaryValue &query)
{
  Editing *ed = seq::editing_get(scene);
  const std::string name = query.lookup_str("name").value_or("");
  return ed && !name.empty() ? seq::lookup_strip_by_name(ed, name.c_str()) : nullptr;
}

void set_int(bContext *C, Scene *scene, Strip *strip, const char *property, const int value)
{
  PointerRNA ptr = RNA_pointer_create_discrete(&scene->id, RNA_Strip, strip);
  PropertyRNA *prop = RNA_struct_find_property(&ptr, property);
  if (prop && RNA_property_int_get(&ptr, prop) != value) {
    RNA_property_int_set(&ptr, prop, value);
    RNA_property_update(C, &ptr, prop);
  }
}

void select_only(Scene *scene, Strip *strip)
{
  if (Editing *ed = seq::editing_get(scene)) {
    for (Strip &other : *seq::active_seqbase_get(ed)) {
      other.flag &= ~STRIP_ALLSEL;
    }
  }
  if (strip) {
    strip->flag |= SEQ_SELECT;
  }
  seq::select_active_set(scene, strip);
}

/** The scene new shots are copies of: one no shot shows, as the Storyboarding template keeps for
 * a blank panel, or else the shot under the playhead. */
Scene *new_shot_template(bContext *C, Scene *sequencer_scene)
{
  Main *bmain = CTX_data_main(C);
  Editing *ed = seq::editing_get(sequencer_scene);
  for (Scene &candidate : bmain->scenes) {
    if (&candidate == sequencer_scene || candidate.camera == nullptr) {
      continue;
    }
    bool used = false;
    if (ed) {
      for (Strip &strip : *seq::active_seqbase_get(ed)) {
        used |= strip.scene == &candidate;
      }
    }
    if (!used) {
      return &candidate;
    }
  }
  return nullptr;
}

/** A new shot's scene, copied whole from another: its drawings emptied, and everything but its
 * camera and drawings taken out, a blank panel to draw in. */
void clear_drawings(Main &bmain, Scene &shot)
{
  Vector<std::pair<Collection *, Object *>> others;
  FOREACH_SCENE_COLLECTION_BEGIN (&shot, collection) {
    for (CollectionObject &item : collection->gobject) {
      Object *object = item.ob;
      if (object && object != shot.camera && object->type != OB_GREASE_PENCIL) {
        others.append({collection, object});
      }
    }
  }
  FOREACH_SCENE_COLLECTION_END;
  for (const auto &[collection, object] : others) {
    BKE_collection_object_remove(&bmain, collection, object, true);
  }
  FOREACH_SCENE_OBJECT_BEGIN (&shot, object) {
    if (object->type != OB_GREASE_PENCIL) {
      continue;
    }
    GreasePencil &grease_pencil = *reinterpret_cast<GreasePencil *>(object->data);
    for (GreasePencilDrawingBase *base : grease_pencil.drawings()) {
      if (base->type == GP_DRAWING) {
        bke::greasepencil::Drawing &drawing = reinterpret_cast<GreasePencilDrawing *>(base)->wrap();
        drawing.strokes_for_write() = bke::CurvesGeometry();
        drawing.tag_topology_changed();
      }
    }
    DEG_id_tag_update(&grease_pencil.id, ID_RECALC_GEOMETRY);
  }
  FOREACH_SCENE_OBJECT_END;
}

/** Makes room at `frame`, moving every strip starting there or later, on every channel, and the
 * markers, later by `length` (a negative one closes it again): Blender's own shift, as its gap
 * removal does, so sound and effects stay in step with the shots (ROUND6 EDIT-10, D17). Moving
 * one channel left them behind. */
void make_room(Scene *scene, const int frame, const int length)
{
  Editing *ed = seq::editing_get(scene);
  if (!ed || length == 0) {
    return;
  }
  seq::transform_offset_after_frame(scene, seq::active_seqbase_get(ed), length, frame);
  DEG_id_tag_update(&scene->id, ID_RECALC_SEQUENCER_STRIPS);
}

/** Runs one of Blender's operators for an edit; whether it finished. Nested, as a button's call
 * is: it makes no undo step of its own, the edit makes one for all it changed, before and after
 * the operator (ROUND6 EDIT-10, D17). */
bool run_operator(bContext *C, const char *idname, PointerRNA *properties)
{
  wmWindowManager *wm = CTX_wm_manager(C);
  wm->op_undo_depth++;
  const wmOperatorStatus status = WM_operator_name_call(
      C, idname, wm::OpCallContext::ExecDefault, properties, nullptr);
  wm->op_undo_depth--;
  return (status & OPERATOR_FINISHED) != 0;
}

/** A new shot at `frame` on `channel`: a copy of `source` (its world, settings, camera and
 * layers), selected and active. The copy is of `source` itself: the Sequencer's Add New Scene
 * copies the window's scene, which is not always the shot a new one follows (found by the
 * harness, ROUND6 EDIT-10). */
Strip *add_shot(bContext *C, Scene *scene, Scene *source, const eSceneCopyMethod method,
                const int frame, const int channel)
{
  Main *bmain = CTX_data_main(C);
  Scene *shot = BKE_scene_duplicate(bmain,
                                    source,
                                    method,
                                    eDupli_ID_Flags(U.dupflag | USER_DUP_OBJECT),
                                    LIB_ID_DUPLICATE_IS_ROOT_ID);
  if (!shot) {
    return nullptr;
  }
  Editing *ed = seq::editing_ensure(scene);
  seq::LoadData load_data;
  seq::add_load_data_init(&load_data, shot->id.name + 2, nullptr, frame, channel);
  load_data.scene = shot;
  Strip *added = seq::add_scene_strip(scene, ed->current_strips(), &load_data);
  select_only(scene, added);
  DEG_id_tag_update(&scene->id, ID_RECALC_SEQUENCER_STRIPS);
  DEG_relations_tag_update(bmain);
  WM_event_add_notifier(C, NC_SCENE | ND_SEQUENCER, scene);
  return added;
}

/** Shows the shot under the edit's playhead, as Blender's storyboard does, keeping the tool as it
 * was set: each shot's scene has tool settings of its own, which would change the brush, its
 * size and strength, and the mode drawn in, from one shot to the next. */
/** The 3D Viewport's tool for the window's mode now, and that mode. */
std::pair<std::string, int> viewport_tool(bContext *C)
{
  WorkSpace *workspace = CTX_wm_workspace(C);
  Scene *scene = CTX_data_scene(C);
  ViewLayer *view_layer = CTX_data_view_layer(C);
  if (!workspace || !scene || !view_layer) {
    return {"", -1};
  }
  bToolKey key = {SPACE_VIEW3D,
                  WM_toolsystem_mode_from_spacetype(scene, view_layer, nullptr, SPACE_VIEW3D)};
  const bToolRef *tool = WM_toolsystem_ref_find(workspace, &key);
  return {tool ? tool->idname : "", key.mode};
}

void sync_scene(bContext *C)
{
  wmWindow *win = CTX_wm_window(C);
  Scene *before = win ? WM_window_get_active_scene(win) : nullptr;
  /* The tool picked, which is the user's: kept from shot to shot, whatever it is. */
  const std::pair<std::string, int> tool_before = viewport_tool(C);
  const Object *object_before = CTX_data_active_object(C);
  const eObjectMode mode = object_before ? eObjectMode(object_before->mode) : OB_MODE_OBJECT;
  sync_active_scene_and_time_with_scene_strip(*C);
  Scene *after = win ? WM_window_get_active_scene(win) : nullptr;

  /* First the shot's drawing in the mode drawn in before, or Draw Mode: a storyboard is drawn,
   * never left in Object Mode with its tools. Entering a mode can pick its own brush, so the
   * brush is set after. */
  Object *object = CTX_data_active_object(C);
  if (!object || object->type != OB_GREASE_PENCIL) {
    /* Its drawing, even with nothing or its camera active: otherwise the window is left in Object
     * Mode, with Object Mode's tool. */
    if (ViewLayer *view_layer = after ? CTX_data_view_layer(C) : nullptr) {
      BKE_view_layer_synced_ensure(after, view_layer);
      for (Base &base : *BKE_view_layer_object_bases_get(view_layer)) {
        if (base.object->type == OB_GREASE_PENCIL && (base.flag & BASE_SELECTABLE)) {
          object::base_activate(C, &base);
          object = base.object;
          break;
        }
      }
    }
  }
  const eObjectMode drawing_mode = object_before && object_before->type == OB_GREASE_PENCIL &&
                                           mode != OB_MODE_OBJECT ?
                                       mode :
                                       OB_MODE_PAINT_GREASE_PENCIL;
  if (object && object->type == OB_GREASE_PENCIL && object->mode != drawing_mode) {
    object::mode_set(C, drawing_mode);
  }
  if (WorkSpace *workspace = CTX_wm_workspace(C); workspace && !tool_before.first.empty()) {
    const std::pair<std::string, int> tool_after = viewport_tool(C);
    if (tool_after.second == tool_before.second && tool_after.first != tool_before.first) {
      bToolKey key = {SPACE_VIEW3D, tool_after.second};
      WM_toolsystem_ref_set_by_id_ex(C, workspace, &key, tool_before.first.c_str(), false);
    }
  }
  if (!before || !after || before == after || !before->toolsettings || !after->toolsettings) {
    return;
  }
  /* Then the brush, its size, strength and color, and the color mode, as they were set. */
  GpPaint *from = before->toolsettings->gp_paint;
  GpPaint *to = after->toolsettings->gp_paint;
  if (from && to) {
    if (from->paint.brush_asset_reference) {
      BKE_paint_brush_set(CTX_data_main(C), &to->paint, *from->paint.brush_asset_reference);
    }
    else if (Brush *brush = BKE_paint_brush(&from->paint)) {
      BKE_paint_brush_set(&to->paint, brush);
    }
    to->mode = from->mode;
    const UnifiedPaintSettings &unified = from->paint.unified_paint_settings;
    UnifiedPaintSettings &into = to->paint.unified_paint_settings;
    into.size = unified.size;
    into.unprojected_size = unified.unprojected_size;
    into.alpha = unified.alpha;
    into.weight = unified.weight;
    copy_v3_v3(into.color, unified.color);
    copy_v3_v3(into.secondary_color, unified.secondary_color);
    into.flag = unified.flag;
  }
  WM_event_add_notifier(C, NC_SCENE | ND_TOOLSETTINGS, after);
}

/** Applies an edit; the undo step's name, empty for none, or nothing when it failed. */
/** A sequencer scene for a file without one, as its first shot is added: with the scene's size
 * and frame rate, the window keeping its scene and following the shot under the playhead. */
Scene *new_story_scene(bContext *C)
{
  WorkSpace *workspace = CTX_wm_workspace(C);
  const Scene *shown = CTX_data_scene(C);
  if (!workspace) {
    return nullptr;
  }
  Scene *story = BKE_scene_add(CTX_data_main(C), DATA_("Story"));
  if (shown) {
    story->r.xsch = shown->r.xsch;
    story->r.ysch = shown->r.ysch;
    story->r.xasp = shown->r.xasp;
    story->r.yasp = shown->r.yasp;
    story->r.frs_sec = shown->r.frs_sec;
    story->r.frs_sec_base = shown->r.frs_sec_base;
  }
  seq::editing_ensure(story);
  workspace->sequencer_scene = story;
  workspace->flags |= WORKSPACE_SYNC_SCENE_TIME;
  WM_event_add_notifier(C, NC_WINDOW, nullptr);
  return story;
}

/** Why the edit being applied failed, where there is more to say than that it did: said instead of
 * the general refusal. Three of these were returned as successes, and became undo steps named
 * "No shot" (ROUND6 EDIT-3, D7). */
std::string edit_failure;

std::optional<std::string> apply_edit(bContext *C, const DictionaryValue &query)
{
  const std::string action = query.lookup_str("action").value_or("");
  Scene *scene = CTX_data_sequencer_scene(C);
  if (!scene && action == "add") {
    scene = new_story_scene(C);
  }
  if (!scene) {
    return std::nullopt;
  }
  Strip *strip = find_strip(scene, query);

  if (action == "frame") {
    scene->r.cfra = int(query.lookup_int("frame").value_or(scene->r.cfra));
    scene->r.subframe = 0.0f;
    DEG_id_tag_update(&scene->id, ID_RECALC_FRAME_CHANGE);
    sync_scene(C);
    WM_event_add_notifier(C, NC_SCENE | ND_FRAME, scene);
    return "";
  }
  if (action == "loop") {
    /* Within the frames in view: as the preview range, which playback loops within. */
    if (lookup_flag(query, "enabled", true)) {
      const int start = int(query.lookup_int("start").value_or(scene->r.sfra));
      const int end = int(query.lookup_int("end").value_or(scene->r.efra));
      scene->r.flag |= SCER_PRV_RANGE;
      scene->r.psfra = max_ii(MINFRAME, start);
      scene->r.pefra = max_ii(scene->r.psfra, end);
    }
    else {
      scene->r.flag &= ~SCER_PRV_RANGE;
    }
    WM_event_add_notifier(C, NC_SCENE | ND_FRAME_RANGE, scene);
    return "";
  }
  if (action == "play") {
    WM_operator_name_call(C, "SCREEN_OT_animation_play", wm::OpCallContext::InvokeDefault,
                          nullptr, nullptr);
    return "";
  }
  if (action == "sync") {
    if (WorkSpace *workspace = CTX_wm_workspace(C)) {
      SET_FLAG_FROM_TEST(workspace->flags, query.lookup_int("value").value_or(1),
                         WORKSPACE_SYNC_SCENE_TIME);
      sync_scene(C);
    }
    return "";
  }
  if (action == "select") {
    if (!strip) {
      return std::nullopt;
    }
    select_only(scene, strip);
    WM_event_add_notifier(C, NC_SCENE | ND_SEQUENCER | NA_SELECTED, scene);
    return "Select Shot";
  }
  if (action == "shot_keys_move" || action == "shot_keys_delete") {
    /* A shot's drawings, all its layers' starting at these frames of the edit, moved or gone. */
    if (!strip || !strip->scene) {
      return std::nullopt;
    }
    Scene *shot = strip->scene;
    Vector<int> frames;
    for (const int frame : lookup_frames(query)) {
      frames.append(frame - int(strip->start) + shot->r.sfra + strip->anim_startofs);
    }
    const int delta = int(query.lookup_int("delta").value_or(0));
    const bool remove = action == "shot_keys_delete";
    FOREACH_SCENE_OBJECT_BEGIN (shot, object) {
      if (object->type != OB_GREASE_PENCIL) {
        continue;
      }
      GreasePencil &grease_pencil = *reinterpret_cast<GreasePencil *>(object->data);
      for (bke::greasepencil::Layer *layer : grease_pencil.layers_for_write()) {
        if (remove) {
          Vector<int> present;
          for (const int frame : frames) {
            if (layer->frames().contains(frame)) {
              present.append(frame);
            }
          }
          grease_pencil.remove_frames(*layer, present);
        }
        else {
          move_frames(grease_pencil, *layer, frames, delta);
        }
      }
      DEG_id_tag_update(&grease_pencil.id, ID_RECALC_GEOMETRY);
    }
    FOREACH_SCENE_OBJECT_END;
    WM_event_add_notifier(C, NC_GPENCIL | NA_EDITED, nullptr);
    return remove ? "Delete Drawings" : "Move Drawings";
  }
  if (action == "move") {
    if (!strip) {
      return std::nullopt;
    }
    const int start = int(query.lookup_int("start").value_or(strip->left_handle()));
    const int channel = int(query.lookup_int("channel").value_or(strip->channel));
    seq::transform_translate_strip(scene, strip, start - strip->left_handle());
    seq::strip_channel_set(strip, max_ii(1, channel));
    if (seq::transform_test_overlap(scene, seq::active_seqbase_get(seq::editing_get(scene)), strip))
    {
      seq::transform_seqbase_shuffle(seq::active_seqbase_get(seq::editing_get(scene)), strip,
                                     scene);
    }
    DEG_id_tag_update(&scene->id, ID_RECALC_SEQUENCER_STRIPS);
    sync_scene(C);
    WM_event_add_notifier(C, NC_SCENE | ND_SEQUENCER, scene);
    return "Move Shot";
  }
  if (action == "trim") {
    if (!strip) {
      return std::nullopt;
    }
    const bool left = query.lookup_str("side").value_or("") == "left";
    set_int(C, scene, strip, left ? "frame_final_start" : "frame_final_end",
            int(query.lookup_int("frame").value_or(0)));
    if (strip->type == STRIP_TYPE_SCENE && strip->scene) {
      /* The shot's scene covers what the shot shows, its frame range following, the shot's
       * frames where they were in the edit. */
      Scene *shot = strip->scene;
      const int first_frame = strip->left_handle();
      const int last_frame = strip->right_handle(scene);
      const int first = shot->r.sfra + strip->anim_startofs + (first_frame - int(strip->start));
      shot->r.sfra = first;
      shot->r.efra = first + max_ii(1, last_frame - first_frame) - 1;
      strip->anim_startofs = 0;
      strip->anim_endofs = 0;
      seq::add_reload_new_file(CTX_data_main(C), scene, strip, false);
      strip->start = float(first_frame);
      strip->startofs = 0.0f;
      strip->endofs = 0.0f;
      seq::relations_invalidate_cache(scene, strip);
      DEG_id_tag_update(&shot->id, ID_RECALC_FRAME_CHANGE);
      DEG_id_tag_update(&scene->id, ID_RECALC_SEQUENCER_STRIPS);
      WM_event_add_notifier(C, NC_SCENE | ND_FRAME_RANGE, shot);
    }
    sync_scene(C);
    return left ? "Trim Shot Start" : "Trim Shot End";
  }
  if (action == "layer_delete" || action == "layer_duplicate" || action == "layer_clear" ||
      action == "layer_lock" || action == "layer_rename" || action == "layer_keys_move" ||
      action == "layer_keys_delete")
  {
    GreasePencil *grease_pencil = shown_grease_pencil(C);
    bke::greasepencil::Layer *layer = grease_pencil ?
                                          find_layer(*grease_pencil, query.lookup_str("layer").value_or("")) :
                                          nullptr;
    if (!layer) {
      return std::nullopt;
    }
    if (action == "layer_keys_move" || action == "layer_keys_delete") {
      /* A layer's drawings moved by some frames: those landing on others replace them, as keys
       * do. */
      const int delta = int(query.lookup_int("delta").value_or(0));
      Vector<int> frames;
      for (const int frame : lookup_frames(query)) {
        if (layer->frames().contains(frame)) {
          frames.append(frame);
        }
      }
      if (action == "layer_keys_delete") {
        if (frames.is_empty()) {
          return std::nullopt;
        }
        grease_pencil->remove_frames(*layer, frames);
        DEG_id_tag_update(&grease_pencil->id, ID_RECALC_GEOMETRY);
        WM_event_add_notifier(C, NC_GPENCIL | NA_EDITED, nullptr);
        return "Delete Drawings";
      }
      if (delta == 0 || frames.is_empty()) {
        return std::nullopt;
      }
      move_frames(*grease_pencil, *layer, frames, delta);
      DEG_id_tag_update(&grease_pencil->id, ID_RECALC_GEOMETRY);
      WM_event_add_notifier(C, NC_GPENCIL | NA_EDITED, nullptr);
      return "Move Drawings";
    }
    if (action == "layer_lock") {
      layer->set_locked(lookup_flag(query, "value", !layer->is_locked()));
      WM_event_add_notifier(C, NC_GPENCIL | NA_EDITED, nullptr);
      return "Lock Layer";
    }
    if (action == "layer_rename") {
      const std::string name = query.lookup_str("value").value_or("");
      if (name.empty()) {
        return std::nullopt;
      }
      grease_pencil->rename_node(*CTX_data_main(C), layer->as_node(), name);
      WM_event_add_notifier(C, NC_GPENCIL | NA_EDITED, nullptr);
      return "Rename Layer";
    }
    if (action == "layer_clear") {
      /* The drawing shown now: its strokes gone, its key kept, to draw it again. */
      bke::greasepencil::Drawing *drawing = grease_pencil->get_editable_drawing_at(
          *layer, CTX_data_scene(C)->r.cfra);
      if (!drawing) {
        return std::nullopt;
      }
      drawing->strokes_for_write() = bke::CurvesGeometry();
      drawing->tag_topology_changed();
      DEG_id_tag_update(&grease_pencil->id, ID_RECALC_GEOMETRY);
      WM_event_add_notifier(C, NC_GPENCIL | NA_EDITED, nullptr);
      return "Clear Drawing";
    }
    /* Blender's own operators, on the layer made active. */
    grease_pencil->set_active_layer(layer);
    const bool remove = action == "layer_delete";
    if (!run_operator(C,
                      remove ? "GREASE_PENCIL_OT_layer_remove" : "GREASE_PENCIL_OT_layer_duplicate",
                      nullptr))
    {
      return std::nullopt;
    }
    return remove ? "Remove Layer" : "Duplicate Layer";
  }
  if (action == "layer_active" || action == "layer_visible" || action == "layer_move") {
    GreasePencil *grease_pencil = shown_grease_pencil(C);
    bke::greasepencil::Layer *layer = grease_pencil ?
                                          find_layer(*grease_pencil, query.lookup_str("layer").value_or("")) :
                                          nullptr;
    if (!layer) {
      return std::nullopt;
    }
    std::string undo;
    if (action == "layer_active") {
      grease_pencil->set_active_layer(layer);
      undo = "Set Active Layer";
    }
    else if (action == "layer_visible") {
      layer->set_visible(lookup_flag(query, "value", true));
      undo = "Show Layer";
    }
    else {
      /* Dropped above another layer in the list, which shows the top one first: after it in
       * Blender's order, drawn over it. */
      bke::greasepencil::Layer *target = find_layer(*grease_pencil,
                                                    query.lookup_str("target").value_or(""));
      if (!target || target == layer) {
        return std::nullopt;
      }
      if (lookup_flag(query, "above", true)) {
        grease_pencil->move_node_after(layer->as_node(), target->as_node());
      }
      else {
        grease_pencil->move_node_before(layer->as_node(), target->as_node());
      }
      undo = "Move Layer";
    }
    DEG_id_tag_update(&grease_pencil->id, ID_RECALC_GEOMETRY);
    WM_event_add_notifier(C, NC_GPENCIL | NA_EDITED, nullptr);
    return undo;
  }
  if (action == "layer_add") {
    if (!run_operator(C, "GREASE_PENCIL_OT_layer_add", nullptr)) {
      return std::nullopt;
    }
    return "Add Layer";
  }
  if (action == "set_scene") {
    if (!strip || strip->type != STRIP_TYPE_SCENE) {
      return std::nullopt;
    }
    const std::string name = query.lookup_str("value").value_or("");
    ID *id = BKE_libblock_find_name(CTX_data_main(C), ID_SCE, name.c_str());
    if (!id || id == &scene->id) {
      return std::nullopt;
    }
    PointerRNA ptr = RNA_pointer_create_discrete(&scene->id, RNA_Strip, strip);
    PointerRNA value = RNA_id_pointer_create(id);
    PropertyRNA *prop = RNA_struct_find_property(&ptr, "scene");
    RNA_property_pointer_set(&ptr, prop, value, nullptr);
    RNA_property_update(C, &ptr, prop);
    sync_scene(C);
    return "Change Shot Scene";
  }
  if (action == "rename") {
    if (!strip) {
      return std::nullopt;
    }
    PointerRNA ptr = RNA_pointer_create_discrete(&scene->id, RNA_Strip, strip);
    const std::string name = query.lookup_str("value").value_or("");
    RNA_string_set(&ptr, "name", name.c_str());
    WM_event_add_notifier(C, NC_SCENE | ND_SEQUENCER, scene);
    return "Rename Shot";
  }
  if (action == "delete" || action == "duplicate") {
    if (!strip) {
      return std::nullopt;
    }
    /* Checked before anything changes: only a shot has a scene to copy (D17). */
    if (action == "duplicate" && (strip->type != STRIP_TYPE_SCENE || !strip->scene)) {
      edit_failure = IFACE_("Only a shot can be duplicated here");
      return std::nullopt;
    }
    select_only(scene, strip);
    if (action == "delete") {
      PointerRNA properties = WM_operator_properties_create("SEQUENCER_OT_delete");
      RNA_boolean_set(&properties, "delete_data", false);
      const bool done = run_operator(C, "SEQUENCER_OT_delete", &properties);
      WM_operator_properties_free(&properties);
      if (!done) {
        return std::nullopt;
      }
      sync_scene(C);
      return "Delete Shot";
    }
    /* A copy of the shot and its scene, right after it, every later strip making room. */
    const int length = strip->right_handle(scene) - strip->left_handle();
    const int after = strip->right_handle(scene);
    const int channel = strip->channel;
    Scene *shot_scene = strip->scene;
    make_room(scene, after, length);
    if (!add_shot(C, scene, shot_scene, SCE_COPY_FULL, after, channel)) {
      /* Nothing added: the room closed again, as it was. */
      make_room(scene, after, -length);
      return std::nullopt;
    }
    sync_scene(C);
    return "Duplicate Shot";
  }
  if (action == "template") {
    /* A shot's scene kept as a template new shots can start from, or no longer. */
    Strip *strip = find_strip(scene, query);
    if (!strip || !strip->scene) {
      edit_failure = IFACE_("This strip is not a shot");
      return std::nullopt;
    }
    ID *id = &strip->scene->id;
    const bool keep = lookup_flag(query, "value", true);
    if (keep) {
      if (asset::mark_id(id)) {
        asset::generate_preview(C, id);
      }
    }
    else {
      asset::clear_id(id);
    }
    asset::list::storage_tag_main_data_dirty();
    WM_main_add_notifier(NC_ASSET | NA_EDITED, nullptr);
    /* A change to the file, undone as one step (D17). */
    return keep ? "Save as Template" : "Remove Template";
  }
  if (action == "add") {
    /* After the selected shot, or the shot under the playhead, or at the end. */
    Editing *ed = seq::editing_ensure(scene);
    Strip *after = seq::select_active_get(scene);
    if (!after) {
      after = const_cast<Strip *>(get_scene_strip_for_time_sync(scene));
    }
    int frame = scene->r.sfra;
    int channel = 1;
    if (after) {
      frame = after->right_handle(scene);
      channel = after->channel;
    }
    else {
      for (Strip &other : *seq::active_seqbase_get(ed)) {
        frame = max_ii(frame, other.right_handle(scene));
      }
    }
    /* From a scene template: a copy of it, appended from its library or duplicated here. */
    if (const std::optional<StringRefNull> id = query.lookup_str("template")) {
      const asset_system::AssetRepresentation *found = nullptr;
      asset::list::iterate(asset_system::all_library_reference(),
                           [&](asset_system::AssetRepresentation &asset) {
                             if (asset.get_id_type() == ID_SCE && asset.full_path() == *id) {
                               found = &asset;
                               return false;
                             }
                             return true;
                           });
      if (!found) {
        edit_failure = IFACE_("This template is gone");
        return std::nullopt;
      }
      Main *bmain = CTX_data_main(C);
      Scene *shot = reinterpret_cast<Scene *>(
          asset::asset_local_id_ensure_imported(*bmain, *found, ASSET_IMPORT_APPEND));
      if (shot && found->is_local_id()) {
        shot = BKE_scene_duplicate(bmain,
                                   shot,
                                   SCE_COPY_FULL,
                                   eDupli_ID_Flags(U.dupflag | USER_DUP_OBJECT),
                                   LIB_ID_DUPLICATE_IS_ROOT_ID);
      }
      if (!shot) {
        edit_failure = IFACE_("The template could not be added");
        return std::nullopt;
      }
      /* A shot of its own, not another template. */
      asset::clear_id(&shot->id);
      make_room(scene, frame, shot->r.efra - shot->r.sfra + 1);
      seq::LoadData load_data;
      seq::add_load_data_init(&load_data, shot->id.name + 2, nullptr, frame, channel);
      load_data.scene = shot;
      Strip *added = seq::add_scene_strip(scene, ed->current_strips(), &load_data);
      seq::select_active_set(scene, added);
      DEG_id_tag_update(&scene->id, ID_RECALC_SEQUENCER_STRIPS);
      DEG_relations_tag_update(bmain);
      scene->r.cfra = frame;
      DEG_id_tag_update(&scene->id, ID_RECALC_FRAME_CHANGE);
      sync_scene(C);
      WM_event_add_notifier(C, NC_SCENE | ND_SEQUENCER, scene);
      /* No operator made a step for it: one here, the template, the room and the shot (D17). */
      return "Add Shot";
    }
    /* A copy of the shot it follows, to fit the sequence: its world, render settings, camera and
     * layers, its contents then taken out. A blank panel the file keeps, without one. */
    Scene *template_scene = new_shot_template(C, scene);
    Scene *source = after && after->scene ? after->scene :
                    template_scene      ? template_scene :
                                          CTX_data_scene(C);
    const int length = source ? source->r.efra - source->r.sfra + 1 : 48;
    if (!source) {
      edit_failure = IFACE_("There is no scene to start a shot from");
      return std::nullopt;
    }
    make_room(scene, frame, length);
    /* A copy whole, camera, layers and settings, its drawings then emptied. */
    if (!add_shot(C, scene, source, SCE_COPY_FULL, frame, channel)) {
      make_room(scene, frame, -length);
      return std::nullopt;
    }
    if (Strip *added = seq::select_active_get(scene); added && added->scene && added->scene != source) {
      clear_drawings(*CTX_data_main(C), *added->scene);
      DEG_relations_tag_update(CTX_data_main(C));
    }
    /* The playhead on the new shot, showing it to draw in. */
    scene->r.cfra = frame;
    DEG_id_tag_update(&scene->id, ID_RECALC_FRAME_CHANGE);
    sync_scene(C);
    WM_event_add_notifier(C, NC_SCENE | ND_FRAME, scene);
    /* One step for the room, the copy and its emptied drawings: made after the operator, the
     * drawings would come back on Redo. */
    return "Add Shot";
  }
  return std::nullopt;
}

}  // namespace

std::shared_ptr<DictionaryValue> native_storyboard_read(bContext *C, const DictionaryValue &state)
{
  SequencerSpaceContext space(C);
  /* Pictures are drawn by #native_storyboard_draw, as the window draws. */
  return read_storyboard(C, &state, false);
}

std::string native_storyboard_edit(bContext *C, const DictionaryValue &edit)
{
  SequencerSpaceContext space(C);
  edit_failure.clear();
  /* Nested, as an operator's own calls are: what it runs makes no undo step of its own (the
   * shot's Draw Mode, entered as it shows, made one after the edit's, so Undo undid nothing).
   * The edit makes one for all it changed (ROUND6 EDIT-10, D17). */
  wmWindowManager *wm = CTX_wm_manager(C);
  wm->op_undo_depth++;
  const std::optional<std::string> undo = apply_edit(C, edit);
  wm->op_undo_depth--;
  if (!undo) {
    return edit_failure.empty() ? IFACE_("This storyboard change could not be made.") :
                                  edit_failure;
  }
  if (!undo->empty()) {
    ED_undo_push(C, undo->c_str());
  }
  return "";
}

bool native_storyboard_draw(bContext *C, const DictionaryValue &state)
{
  if (ED_screen_animation_playing(CTX_wm_manager(C))) {
    return false;
  }
  SequencerSpaceContext space(C);
  return read_storyboard(C, &state, true)->lookup_int("pending").value_or(0);
}

}  // namespace blender::ed::vse
