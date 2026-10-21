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
#include <sstream>
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
#include "DNA_workspace_types.h"

#include "BKE_appdir.hh"
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

#include "ED_object.hh"
#include "ED_screen.hh"
#include "ED_sequencer.hh"
#include "ED_undo.hh"

#include "GPU_framebuffer.hh"

#include "IMB_imbuf.hh"
#include "IMB_imbuf_types.hh"

#include "RNA_access.hh"
#include "RNA_prototypes.hh"

#include "SEQ_render.hh"
#include "SEQ_select.hh"
#include "SEQ_sequencer.hh"
#include "SEQ_transform.hh"

#include "WM_api.hh"
#include "WM_types.hh"

#include "DEG_depsgraph.hh"

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

std::string encode(const Value &value)
{
  std::ostringstream stream;
  JsonFormatter().serialize(stream, value);
  return stream.str();
}

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

std::string read_storyboard(bContext *C, const DictionaryValue *state, const bool draw)
{
  DictionaryValue result;
  Scene *scene = CTX_data_sequencer_scene(C);
  WorkSpace *workspace = CTX_wm_workspace(C);
  Editing *ed = scene ? seq::editing_get(scene) : nullptr;
  result.append_int("available", scene != nullptr);
  if (!scene) {
    return encode(result);
  }
  result.append_str("scene", scene->id.name + 2);
  result.append_int("start", scene->r.sfra);
  result.append_int("end", scene->r.efra);
  result.append_int("frame", scene->r.cfra);
  result.append_double("fps", double(scene->r.frs_sec) / double(max_ff(scene->r.frs_sec_base, 1e-6f)));
  result.append_int("sync", workspace && (workspace->flags & WORKSPACE_SYNC_SCENE_TIME));
  result.append_int("playing", ED_screen_animation_playing(CTX_wm_manager(C)) != nullptr);
  const Scene *window_scene = CTX_data_scene(C);
  result.append_str("shown", window_scene ? window_scene->id.name + 2 : "");
  /* The scenes a shot can show instead, all but the edit's own. */
  auto scenes = result.append_array("scenes");
  for (const Scene &other : CTX_data_main(C)->scenes) {
    if (&other != scene) {
      scenes->append_str(other.id.name + 2);
    }
  }

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
      if (strip.is_effect() || strip.type == STRIP_TYPE_SOUND) {
        continue;
      }
      const int left = strip.left_handle();
      const int right = strip.right_handle(scene);
      auto item = strips->append_dict();
      item->append_str("name", strip.name + 2);
      item->append_int("channel", strip.channel);
      item->append_int("start", left);
      item->append_int("end", right);
      item->append_int("scene_strip", strip.type == STRIP_TYPE_SCENE);
      item->append_str("scene", strip.scene ? strip.scene->id.name + 2 : "");
      item->append_int("selected", (strip.flag & SEQ_SELECT) != 0);
      item->append_int("active", &strip == active);
      item->append_int("muted", (strip.flag & SEQ_MUTE) != 0);
      item->append_int("color", strip.color_tag);
      if (strip.type != STRIP_TYPE_SCENE || !strip.scene) {
        continue;
      }
      const Scene &shot = *strip.scene;
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
  return encode(result);
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

/** Empties every drawing in a new shot's scene, copied with its camera, layers and settings
 * from another: a blank panel to draw in. */
void clear_drawings(Scene &shot)
{
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

/** Makes room after `after` on its channel, moving the shots after it later by `length`. */
void make_room(Scene *scene, const int channel, const int frame, const int length)
{
  Editing *ed = seq::editing_get(scene);
  if (!ed) {
    return;
  }
  Vector<Strip *> later;
  for (Strip &strip : *seq::active_seqbase_get(ed)) {
    if (strip.channel == channel && strip.left_handle() >= frame) {
      later.append(&strip);
    }
  }
  std::sort(later.begin(), later.end(), [](const Strip *a, const Strip *b) {
    return a->left_handle() > b->left_handle();
  });
  for (Strip *strip : later) {
    seq::transform_translate_strip(scene, strip, length);
  }
}

/** Shows the shot under the edit's playhead, as Blender's storyboard does, keeping the tool as it
 * was set: each shot's scene has tool settings of its own, which would change the brush, its
 * size and strength, and the mode drawn in, from one shot to the next. */
void sync_scene(bContext *C)
{
  wmWindow *win = CTX_wm_window(C);
  Scene *before = win ? WM_window_get_active_scene(win) : nullptr;
  const Object *object_before = CTX_data_active_object(C);
  const eObjectMode mode = object_before ? eObjectMode(object_before->mode) : OB_MODE_OBJECT;
  sync_active_scene_and_time_with_scene_strip(*C);
  Scene *after = win ? WM_window_get_active_scene(win) : nullptr;
  if (!before || !after || before == after || !before->toolsettings || !after->toolsettings) {
    return;
  }
  if (GpPaint *from = before->toolsettings->gp_paint) {
    if (GpPaint *to = after->toolsettings->gp_paint) {
      if (Brush *brush = BKE_paint_brush(&from->paint)) {
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
  }
  /* The same mode in the shot's drawing, as Draw Mode. */
  Object *object = CTX_data_active_object(C);
  if (object && object->type == OB_GREASE_PENCIL && object_before &&
      object_before->type == OB_GREASE_PENCIL && object->mode != mode)
  {
    object::mode_set(C, mode);
  }
  WM_event_add_notifier(C, NC_SCENE | ND_TOOLSETTINGS, after);
}

/** Applies an edit; the undo step's name, empty for none, or nothing when it failed. */
std::optional<std::string> apply_edit(bContext *C, const DictionaryValue &query)
{
  Scene *scene = CTX_data_sequencer_scene(C);
  if (!scene) {
    return std::nullopt;
  }
  const std::string action = query.lookup_str("action").value_or("");
  Strip *strip = find_strip(scene, query);

  if (action == "frame") {
    scene->r.cfra = int(query.lookup_int("frame").value_or(scene->r.cfra));
    scene->r.subframe = 0.0f;
    DEG_id_tag_update(&scene->id, ID_RECALC_FRAME_CHANGE);
    sync_scene(C);
    WM_event_add_notifier(C, NC_SCENE | ND_FRAME, scene);
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
    sync_scene(C);
    return left ? "Trim Shot Start" : "Trim Shot End";
  }
  if (action == "layer_delete" || action == "layer_duplicate" || action == "layer_clear" ||
      action == "layer_lock" || action == "layer_rename")
  {
    GreasePencil *grease_pencil = shown_grease_pencil(C);
    bke::greasepencil::Layer *layer = grease_pencil ?
                                          find_layer(*grease_pencil, query.lookup_str("layer").value_or("")) :
                                          nullptr;
    if (!layer) {
      return std::nullopt;
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
    WM_operator_name_call(C,
                          action == "layer_delete" ? "GREASE_PENCIL_OT_layer_remove" :
                                                     "GREASE_PENCIL_OT_layer_duplicate",
                          wm::OpCallContext::ExecDefault,
                          nullptr,
                          nullptr);
    return "";
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
    WM_operator_name_call(C, "GREASE_PENCIL_OT_layer_add", wm::OpCallContext::ExecDefault, nullptr,
                          nullptr);
    return "";
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
    select_only(scene, strip);
    if (action == "delete") {
      PointerRNA properties = WM_operator_properties_create("SEQUENCER_OT_delete");
      RNA_boolean_set(&properties, "delete_data", false);
      WM_operator_name_call(C, "SEQUENCER_OT_delete", wm::OpCallContext::ExecDefault,
                            &properties, nullptr);
      WM_operator_properties_free(&properties);
      sync_scene(C);
      return "";
    }
    /* A copy of the shot and its scene, right after it, the later shots making room. */
    const int length = strip->right_handle(scene) - strip->left_handle();
    const int after = strip->right_handle(scene);
    const int channel = strip->channel;
    Scene *shot_scene = strip->scene;
    make_room(scene, channel, after, length);
    if (!shot_scene) {
      return std::nullopt;
    }
    Scene *previous = CTX_data_scene(C);
    CTX_data_scene_set(C, shot_scene);
    PointerRNA properties = WM_operator_properties_create("SEQUENCER_OT_scene_strip_add_new");
    RNA_enum_set(&properties, "type", SCE_COPY_FULL);
    RNA_int_set(&properties, "frame_start", after);
    RNA_int_set(&properties, "channel", channel);
    /* Placed where asked, not then moved with a pointer as the Sequencer's own Add does. */
    RNA_boolean_set(&properties, "move_strips", false);
    WM_operator_name_call(C, "SEQUENCER_OT_scene_strip_add_new", wm::OpCallContext::ExecDefault,
                          &properties, nullptr);
    WM_operator_properties_free(&properties);
    CTX_data_scene_set(C, previous);
    sync_scene(C);
    return "";
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
    Scene *template_scene = new_shot_template(C, scene);
    Scene *source = template_scene ? template_scene :
                    after && after->scene ? after->scene :
                                            CTX_data_scene(C);
    const int length = source ? source->r.efra - source->r.sfra + 1 : 48;
    make_room(scene, channel, frame, length);
    Scene *previous = CTX_data_scene(C);
    CTX_data_scene_set(C, source);
    PointerRNA properties = WM_operator_properties_create("SEQUENCER_OT_scene_strip_add_new");
    /* A copy whole, camera, layers and settings, its drawings then emptied. */
    RNA_enum_set(&properties, "type", source ? SCE_COPY_FULL : SCE_COPY_EMPTY);
    RNA_int_set(&properties, "frame_start", frame);
    RNA_int_set(&properties, "channel", channel);
    /* Placed where asked, not then moved with a pointer as the Sequencer's own Add does. */
    RNA_boolean_set(&properties, "move_strips", false);
    WM_operator_name_call(C, "SEQUENCER_OT_scene_strip_add_new", wm::OpCallContext::ExecDefault,
                          &properties, nullptr);
    WM_operator_properties_free(&properties);
    CTX_data_scene_set(C, previous);
    if (Strip *added = seq::select_active_get(scene); added && added->scene && added->scene != source) {
      clear_drawings(*added->scene);
    }
    /* The playhead on the new shot, showing it to draw in. */
    scene->r.cfra = frame;
    DEG_id_tag_update(&scene->id, ID_RECALC_FRAME_CHANGE);
    sync_scene(C);
    WM_event_add_notifier(C, NC_SCENE | ND_FRAME, scene);
    return "";
  }
  return std::nullopt;
}

}  // namespace

std::string native_storyboard_query(bContext *C, const std::string &request, const bool execute)
{
  std::istringstream stream(request);
  std::unique_ptr<Value> value = JsonFormatter().deserialize(stream);
  const DictionaryValue *query = value ? value->as_dictionary_value() : nullptr;
  SequencerSpaceContext space(C);
  if (!execute) {
    /* Not while playing, which draws the shots itself. */
    return read_storyboard(C, query,
                           !ED_screen_animation_playing(CTX_wm_manager(C)) &&
                               (!query || query->lookup_int("draw").value_or(1)));
  }
  if (!query) {
    return "This storyboard change could not be made.";
  }
  const std::optional<std::string> undo = apply_edit(C, *query);
  if (!undo) {
    return "This storyboard change could not be made.";
  }
  if (!undo->empty()) {
    ED_undo_push(C, undo->c_str());
  }
  return "";
}

}  // namespace blender::ed::vse
