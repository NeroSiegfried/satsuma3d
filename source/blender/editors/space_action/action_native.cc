/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup spaction
 *
 * The Timeline's keys for a native interface, and its edits on them. A hidden Timeline stands in
 * for the strip the native interface draws, so the keys it lists, the keys its previous and next
 * buttons jump to, and the keys its edits change are those of Blender's own Timeline, with its
 * default settings (ROUND6 EDIT-6, D16): the scene's, the world's and the selected objects' and
 * their data's (Only Show Selected, which the Timeline takes from the scene), Grease Pencil
 * drawings by the Dope Sheet's own rules, and locked channels never edited.
 */

#include <cmath>
#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "MEM_guardedalloc.h"

#include "BLI_listbase.h"
#include "BLI_string.h"
#include "BLI_string_ref.hh"

#include "BLT_translation.hh"

#include "DNA_anim_types.h"
#include "DNA_grease_pencil_types.h"
#include "DNA_scene_types.h"
#include "DNA_screen_types.h"
#include "DNA_space_types.h"

#include "BKE_context.hh"
#include "BKE_fcurve.hh"
#include "BKE_grease_pencil.hh"
#include "BKE_report.hh"
#include "BKE_screen.hh"

#include "ED_action_native.hh"
#include "ED_anim_api.hh"
#include "ED_grease_pencil.hh"
#include "ED_keyframes_edit.hh"
#include "ED_keyframes_keylist.hh"

#include "RNA_access.hh"
#include "RNA_define.hh"

#include "WM_api.hh"
#include "WM_types.hh"

#include "action_intern.hh"

namespace blender {

namespace {

/** Kept for the session, as Blender's own would be; freed at exit. */
ScrArea *timeline_area = nullptr;

ScrArea *native_timeline_area(bContext *C)
{
  ScrArea *&area = timeline_area;
  if (area == nullptr) {
    area = MEM_new<ScrArea>("native timeline");
    area->spacetype = SPACE_ACTION;
    area->butspacetype_subtype = SACTCONT_TIMELINE;
    /* On no screen, as Blender's own off-screen areas: an operator run in it shows no redo panel
     * there (ROUND6 EDIT-1). */
    area->flag |= AREA_FLAG_OFFSCREEN;
    area->type = BKE_spacetype_from_id(SPACE_ACTION);
    SpaceLink *link = area->type->create(area, CTX_data_scene(C));
    BLI_addtail(&area->spacedata, link);
    std::swap(area->regionbase, link->regionbase);
    for (ARegion &region : area->regionbase) {
      region.runtime->type = BKE_regiontype_from_id(area->type, region.regiontype);
    }
    /* As a new Timeline is: the summary collapsed, its keys the only row. */
    SpaceAction *saction = reinterpret_cast<SpaceAction *>(link);
    saction->mode = SACTCONT_TIMELINE;
    saction->mode_prev = SACTCONT_TIMELINE;
    saction->ads.flag |= ADS_FLAG_SUMMARY_COLLAPSED;
  }
  return area;
}

/** The hidden Timeline as the context's area while its keys are read or edited. A window is
 * needed by the operators it runs; without one (in the background) the first is lent. */
struct TimelineContext {
  bContext *C;
  wmWindow *previous_window;
  ScrArea *previous_area;
  ARegion *previous_region;

  explicit TimelineContext(bContext *context) : C(context)
  {
    previous_window = CTX_wm_window(C);
    previous_area = CTX_wm_area(C);
    previous_region = CTX_wm_region(C);
    if (previous_window == nullptr) {
      if (wmWindowManager *wm = CTX_wm_manager(C)) {
        CTX_wm_window_set(C, static_cast<wmWindow *>(wm->windows.first));
      }
    }
    ScrArea *area = native_timeline_area(C);
    CTX_wm_area_set(C, area);
    CTX_wm_region_set(C, BKE_area_find_region_type(area, RGN_TYPE_WINDOW));
  }

  ~TimelineContext()
  {
    if (previous_window == nullptr) {
      CTX_wm_window_set(C, nullptr);
    }
    CTX_wm_area_set(C, previous_area);
    CTX_wm_region_set(C, previous_region);
  }
};

/** Every channel the Timeline's keys come from, as its summary row gathers them. */
constexpr eAnimFilter_Flags keys_filter = eAnimFilter_Flags(ANIMFILTER_DATA_VISIBLE |
                                                            ANIMFILTER_NODUPLIS);

struct Channels {
  bAnimContext ac = {};
  ListBaseT<bAnimListElem> list = {};
  bool valid = false;

  Channels(bContext *C, const eAnimFilter_Flags filter)
  {
    if (!ANIM_animdata_get_context(C, &ac)) {
      return;
    }
    valid = true;
    ANIM_animdata_filter(&ac, &list, filter, ac.data, eAnimCont_Types(ac.datatype));
  }

  ~Channels()
  {
    ANIM_animdata_freelist(&list);
  }
};

bke::greasepencil::Layer *grease_pencil_layer(bAnimListElem &ale)
{
  return ale.datatype == ALE_GREASE_PENCIL_CEL ?
             &static_cast<GreasePencilLayer *>(ale.data)->wrap() :
             nullptr;
}

FCurve *fcurve(bAnimListElem &ale)
{
  return ale.datatype == ALE_FCURVE ? static_cast<FCurve *>(ale.key_data) : nullptr;
}

/** A key's frame in scene time, as the strip draws it: whole frames. */
int strip_frame(bAnimListElem &ale, const float frame)
{
  return int(std::lround(ANIM_nla_tweakedit_remap(&ale, frame, NLATIME_CONVERT_MAP)));
}

/**
 * The keys selected outside the frames the strip draws, put aside while an edit of the drawn ones
 * runs and selected again after: the strip's edits keep to what it draws (ROUND6 EDIT-1), while
 * the edits themselves are Blender's own, which act on every selected key.
 */
struct UndrawnSelection {
  std::vector<std::pair<FCurve *, float>> keys;
  std::vector<std::pair<bke::greasepencil::Layer *, int>> drawings;

  UndrawnSelection(bContext *C, const int start, const int end)
  {
    Channels channels(C, keys_filter);
    for (bAnimListElem &ale : channels.list) {
      if (FCurve *fcu = fcurve(ale)) {
        for (int i = 0; i < int(fcu->totvert); i++) {
          BezTriple &bezt = fcu->bezt[i];
          const int frame = strip_frame(ale, bezt.vec[1][0]);
          if ((bezt.f2 & SELECT) && (frame < start || frame > end)) {
            keys.emplace_back(fcu, bezt.vec[1][0]);
            BEZT_DESEL_ALL(&bezt);
          }
        }
      }
      else if (bke::greasepencil::Layer *layer = grease_pencil_layer(ale)) {
        std::vector<int> undrawn;
        for (const auto item : layer->frames().items()) {
          if (item.value.is_selected() && (item.key < start || item.key > end)) {
            undrawn.push_back(item.key);
          }
        }
        for (const int frame : undrawn) {
          ed::greasepencil::select_frame_at(*layer, frame, SELECT_SUBTRACT);
          drawings.emplace_back(layer, frame);
        }
      }
    }
  }

  /** Selects them again: those still where they were. */
  void restore()
  {
    for (const auto &[fcu, frame] : keys) {
      bool replace = false;
      const int index = BKE_fcurve_bezt_binarysearch_index(fcu->bezt, frame, fcu->totvert, &replace);
      if (replace && index >= 0 && index < int(fcu->totvert)) {
        BEZT_SEL_ALL(&fcu->bezt[index]);
      }
    }
    for (const auto &[layer, frame] : drawings) {
      ed::greasepencil::select_frame_at(*layer, frame, SELECT_ADD);
    }
  }
};

/** Whether anything the Timeline's own edits would change is selected and drawn. */
bool editable_selected(bContext *C, const int start, const int end)
{
  Channels channels(C, eAnimFilter_Flags(keys_filter | ANIMFILTER_FOREDIT));
  for (bAnimListElem &ale : channels.list) {
    if (FCurve *fcu = fcurve(ale)) {
      for (int i = 0; i < int(fcu->totvert); i++) {
        const int frame = strip_frame(ale, fcu->bezt[i].vec[1][0]);
        if ((fcu->bezt[i].f2 & SELECT) && frame >= start && frame <= end) {
          return true;
        }
      }
    }
    else if (bke::greasepencil::Layer *layer = grease_pencil_layer(ale)) {
      for (const auto item : layer->frames().items()) {
        if (item.value.is_selected() && item.key >= start && item.key <= end) {
          return true;
        }
      }
    }
  }
  return false;
}

/** Runs one of Blender's own operators in the hidden Timeline, its reports given to \a op. */
wmOperatorStatus run_in_timeline(bContext *C,
                                 wmOperator *op,
                                 const char *idname,
                                 PointerRNA *properties)
{
  wmOperatorType *ot = WM_operatortype_find(idname, false);
  if (ot == nullptr) {
    BKE_reportf(op->reports, RPT_ERROR, "%s is missing", idname);
    return OPERATOR_CANCELLED;
  }
  if (!WM_operator_poll(C, ot)) {
    const char *why = CTX_wm_operator_poll_msg_get(C, nullptr);
    BKE_report(op->reports, RPT_ERROR, why && why[0] ? why : RPT_("The keys cannot be changed now"));
    return OPERATOR_CANCELLED;
  }
  /* Its undo step is this operator's. */
  return WM_operator_call_py(C, ot, wm::OpCallContext::ExecDefault, properties, op->reports, false);
}

std::set<int> frames_from_text(const std::string &text)
{
  std::set<int> frames;
  size_t start = 0;
  while (start <= text.size()) {
    const size_t comma = text.find(',', start);
    const std::string part = text.substr(start, comma == std::string::npos ? std::string::npos :
                                                                             comma - start);
    if (part.find_first_not_of(" ") != std::string::npos) {
      frames.insert(std::atoi(part.c_str()));
    }
    if (comma == std::string::npos) {
      break;
    }
    start = comma + 1;
  }
  return frames;
}

void frame_range_properties(wmOperatorType *ot)
{
  /* The frames the strip draws, which its edits keep to (ROUND6 EDIT-1). */
  PropertyRNA *prop;
  prop = RNA_def_int(
      ot->srna, "frame_start", -MAXFRAME, -MAXFRAME, MAXFRAME, "Start", "", -MAXFRAME, MAXFRAME);
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);
  prop = RNA_def_int(
      ot->srna, "frame_end", MAXFRAME, -MAXFRAME, MAXFRAME, "End", "", -MAXFRAME, MAXFRAME);
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);
}

/* -------------------------------------------------------------------- */
/** \name Operators
 * \{ */

wmOperatorStatus native_key_select_exec(bContext *C, wmOperator *op)
{
  char text[4096];
  RNA_string_get(op->ptr, "frames", text);
  const std::set<int> frames = frames_from_text(text);
  const bool extend = RNA_boolean_get(op->ptr, "extend");
  TimelineContext timeline(C);
  Channels channels(C, keys_filter);
  if (!channels.valid) {
    return OPERATOR_CANCELLED;
  }
  /* As a click on the Timeline's keys selects a column: every key on the frame. */
  for (bAnimListElem &ale : channels.list) {
    if (FCurve *fcu = fcurve(ale)) {
      for (int i = 0; i < int(fcu->totvert); i++) {
        BezTriple &bezt = fcu->bezt[i];
        if (frames.count(strip_frame(ale, bezt.vec[1][0]))) {
          BEZT_SEL_ALL(&bezt);
        }
        else if (!extend) {
          BEZT_DESEL_ALL(&bezt);
        }
      }
    }
    else if (bke::greasepencil::Layer *layer = grease_pencil_layer(ale)) {
      if (!extend) {
        ed::greasepencil::select_all_frames(*layer, SELECT_SUBTRACT);
      }
      for (const int frame : frames) {
        ed::greasepencil::select_frame_at(*layer, frame, SELECT_ADD);
      }
      ale.update |= ANIM_UPDATE_DEPS;
    }
  }
  ANIM_animdata_update(&channels.ac, &channels.list);
  WM_event_add_notifier(C, NC_ANIMATION | ND_KEYFRAME | NA_SELECTED, nullptr);
  return OPERATOR_FINISHED;
}

void ANIM_OT_native_key_select(wmOperatorType *ot)
{
  ot->name = "Select Keyframes";
  ot->idname = "ANIM_OT_native_key_select";
  ot->description = "Select the keys on some frames of the timeline";
  ot->exec = native_key_select_exec;
  ot->flag = OPTYPE_UNDO | OPTYPE_INTERNAL;
  PropertyRNA *prop = RNA_def_string(
      ot->srna, "frames", nullptr, 0, "Frames", "Comma separated frames");
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);
  prop = RNA_def_boolean(ot->srna, "extend", false, "Extend", "");
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);
}

wmOperatorStatus native_key_move_exec(bContext *C, wmOperator *op)
{
  const int delta = RNA_int_get(op->ptr, "delta");
  const int start = RNA_int_get(op->ptr, "frame_start"), end = RNA_int_get(op->ptr, "frame_end");
  if (delta == 0) {
    return OPERATOR_CANCELLED;
  }
  TimelineContext timeline(C);
  if (!editable_selected(C, start, end)) {
    return OPERATOR_CANCELLED;
  }
  UndrawnSelection undrawn(C, start, end);
  /* The Timeline's own move: keys moved onto others replace them, locked channels and layers stay,
   * the curves are cleaned up after, as dragging keys there does. */
  wmOperatorType *ot = WM_operatortype_find("TRANSFORM_OT_transform", false);
  PointerRNA properties = WM_operator_properties_create_ptr(ot);
  RNA_enum_set_identifier(C, &properties, "mode", "TIME_TRANSLATE");
  const float value[4] = {float(delta), 0.0f, 0.0f, 0.0f};
  RNA_float_set_array(&properties, "value", value);
  const wmOperatorStatus status = run_in_timeline(C, op, "TRANSFORM_OT_transform", &properties);
  WM_operator_properties_free(&properties);
  undrawn.restore();
  return status;
}

void ANIM_OT_native_key_move(wmOperatorType *ot)
{
  ot->name = "Move Keyframes";
  ot->idname = "ANIM_OT_native_key_move";
  ot->description = "Move the selected keys of the timeline by a number of frames";
  ot->exec = native_key_move_exec;
  ot->flag = OPTYPE_UNDO | OPTYPE_INTERNAL;
  PropertyRNA *prop = RNA_def_int(
      ot->srna, "delta", 0, -MAXFRAME, MAXFRAME, "Delta", "", -MAXFRAME, MAXFRAME);
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);
  frame_range_properties(ot);
}

wmOperatorStatus native_key_delete_exec(bContext *C, wmOperator *op)
{
  const int start = RNA_int_get(op->ptr, "frame_start"), end = RNA_int_get(op->ptr, "frame_end");
  TimelineContext timeline(C);
  if (!editable_selected(C, start, end)) {
    return OPERATOR_CANCELLED;
  }
  UndrawnSelection undrawn(C, start, end);
  /* The Timeline's own delete: curves left without keys go too, locked ones stay. */
  const wmOperatorStatus status = run_in_timeline(C, op, "ACTION_OT_delete", nullptr);
  undrawn.restore();
  return status;
}

void ANIM_OT_native_key_delete(wmOperatorType *ot)
{
  ot->name = "Delete Keyframes";
  ot->idname = "ANIM_OT_native_key_delete";
  ot->description = "Delete the selected keys of the timeline";
  ot->exec = native_key_delete_exec;
  ot->flag = OPTYPE_UNDO | OPTYPE_INTERNAL;
  frame_range_properties(ot);
}

wmOperatorStatus native_key_jump_exec(bContext *C, wmOperator *op)
{
  TimelineContext timeline(C);
  wmOperatorType *ot = WM_operatortype_find("SCREEN_OT_keyframe_jump", false);
  PointerRNA properties = WM_operator_properties_create_ptr(ot);
  RNA_boolean_set(&properties, "next", RNA_boolean_get(op->ptr, "next"));
  /* The Timeline's jump: to the keys it draws, which are the strip's. */
  const wmOperatorStatus status = run_in_timeline(C, op, "SCREEN_OT_keyframe_jump", &properties);
  WM_operator_properties_free(&properties);
  return status;
}

void ANIM_OT_native_key_jump(wmOperatorType *ot)
{
  ot->name = "Jump to Keyframe";
  ot->idname = "ANIM_OT_native_key_jump";
  ot->description = "Jump to the previous or next key of the timeline";
  ot->exec = native_key_jump_exec;
  ot->flag = OPTYPE_INTERNAL;
  PropertyRNA *prop = RNA_def_boolean(ot->srna, "next", true, "Next", "");
  RNA_def_property_flag(prop, PROP_SKIP_SAVE);
}

/** \} */

}  // namespace

ScrArea *ED_action_native_timeline_area(bContext *C)
{
  return native_timeline_area(C);
}

void ED_action_native_timeline_keys(bContext *C,
                                    std::vector<int64_t> &r_frames,
                                    std::vector<int64_t> &r_selected)
{
  TimelineContext timeline(C);
  bAnimContext ac;
  if (!ANIM_animdata_get_context(C, &ac)) {
    return;
  }
  /* What the Timeline draws and jumps to: its summary's columns. */
  AnimKeylist *keylist = ED_keylist_create();
  summary_to_keylist(&ac, keylist, 0, {-FLT_MAX, FLT_MAX});
  ED_keylist_prepare_for_direct_access(keylist);
  std::map<int64_t, bool> frames;
  const ActKeyColumn *columns = ED_keylist_array(keylist);
  for (int64_t i = 0; i < ED_keylist_array_len(keylist); i++) {
    const int64_t frame = std::lround(columns[i].cfra);
    frames[frame] = frames[frame] || columns[i].sel;
  }
  ED_keylist_free(keylist);
  for (const auto &[frame, selected] : frames) {
    r_frames.push_back(frame);
    if (selected) {
      r_selected.push_back(frame);
    }
  }
}

void ED_action_native_exit()
{
  if (timeline_area) {
    BKE_screen_area_free(timeline_area);
    MEM_delete(timeline_area);
    timeline_area = nullptr;
  }
}

void ED_action_native_operatortypes()
{
  WM_operatortype_append(ANIM_OT_native_key_select);
  WM_operatortype_append(ANIM_OT_native_key_move);
  WM_operatortype_append(ANIM_OT_native_key_delete);
  WM_operatortype_append(ANIM_OT_native_key_jump);
}

}  // namespace blender
