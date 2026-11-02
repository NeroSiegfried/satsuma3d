/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * Fingers move objects with the Tweak tool on the iPad, one object under each finger, while the
 * Pencil keeps Blender's own Tweak. A finger landing on an object holds it, and dragging moves it
 * in the view's plane, staying under the finger; many fingers move many objects at once. A tap
 * selects as a click does. Fingers on empty space navigate, unless another holds an object.
 *
 * UIKit hands the touches over from its own thread, see #GHOST_IOSNativeInterface; they are
 * picked and applied here, on Blender's.
 */

#if defined(WITH_APPLE_CROSSPLATFORM) && APPLE_TARGET_IOS

#  include <atomic>

#  include "BLI_math_matrix.hh"
#  include "BLI_math_vector.h"
#  include "BLI_vector.hh"

#  include "BKE_context.hh"
#  include "BKE_layer.hh"
#  include "BKE_lib_id.hh"
#  include "BKE_object.hh"
#  include "BKE_screen.hh"
#  include "BKE_wm_runtime.hh"

#  include "DEG_depsgraph.hh"

#  include "DNA_object_types.h"
#  include "DNA_scene_types.h"
#  include "DNA_screen_types.h"
#  include "DNA_space_types.h"
#  include "DNA_userdef_types.h"
#  include "DNA_view3d_types.h"
#  include "DNA_windowmanager_types.h"
#  include "DNA_workspace_types.h"

#  include "ED_object.hh"
#  include "ED_select_utils.hh"
#  include "ED_undo.hh"
#  include "ED_view3d.hh"

#  include "RNA_access.hh"

#  include "GHOST_Mailbox.hh"
#  include "GHOST_IOSNativeInterface.hh"

#  include "WM_api.hh"
#  include "WM_apple_ios.hh"
#  include "WM_native_ui.hh"
#  include "WM_native_interface.hh"
#  include "WM_toolsystem.hh"
#  include "WM_types.hh"

#  include "wm_window.hh"


namespace blender {

namespace {

struct FingerTouch {
  uint64_t id;
  /** A #GHOST_IOSTouchPhase. */
  int phase;
  /** GHOST's window pixels. */
  int x, y;
};

/** A finger on the viewport, from landing to lifting. */
struct Finger {
  uint64_t id;
  /** Window coordinates where it landed, and where its object was last moved to. */
  int2 start_xy;
  int2 xy;
  /** The object it holds, or zero for none. */
  uint32_t object_uid = 0;
  /** It moved past the drag threshold, and moves its object. */
  bool dragging = false;
  /** Depth of the object in the view, see #ED_view3d_calc_zfac. */
  float zfac = 1.0f;
  /** From world space to the space of the object's location, and the location it started at. */
  float3x3 world_to_local = float3x3::identity();
  float3 start_location;
};

GHOST_MessageQueue<FingerTouch> finger_touches;
/** Tweak is the tool, in Object Mode, with the native interface showing. */
std::atomic<bool> finger_tweak_mode{false};
/** Fingers landed, not picked yet: they may hold an object. */
std::atomic<int> fingers_pending{0};
/** Fingers holding an object. */
std::atomic<int> fingers_holding{0};

/* Engine thread only. */
Vector<Finger> fingers;
/** How many fingers touched since none did: only a finger alone taps. */
int fingers_in_gesture = 0;
/** An object moved since no finger held one, for an undo step when the last lifts. */
bool objects_moved = false;

struct ContextStore {
  wmWindow *win;
  bScreen *screen;
  ScrArea *area;
  ARegion *region;
};

ContextStore context_push(bContext *C, wmWindow *win, ScrArea *area, ARegion *region)
{
  const ContextStore store = {CTX_wm_window(C), CTX_wm_screen(C), CTX_wm_area(C), CTX_wm_region(C)};
  CTX_wm_window_set(C, win);
  CTX_wm_screen_set(C, WM_window_get_active_screen(win));
  CTX_wm_area_set(C, area);
  CTX_wm_region_set(C, region);
  return store;
}

void context_pop(bContext *C, const ContextStore &store)
{
  CTX_wm_window_set(C, store.win);
  CTX_wm_screen_set(C, store.screen);
  CTX_wm_area_set(C, store.area);
  CTX_wm_region_set(C, store.region);
}

wmWindow *document_window(bContext *C)
{
  if (wmWindow *win = CTX_wm_window(C)) {
    return win;
  }
  wmWindowManager *wm = CTX_wm_manager(C);
  return wm ? static_cast<wmWindow *>(wm->windows.first) : nullptr;
}

/** The 3D view's main region at window coordinates `xy`, or null. */
ARegion *viewport_region_at(wmWindow *win, const int2 &xy, ScrArea **r_area)
{
  bScreen *screen = WM_window_get_active_screen(win);
  ScrArea *area = screen ? BKE_screen_find_area_xy(screen, SPACE_VIEW3D, xy) : nullptr;
  *r_area = area;
  return area ? BKE_area_find_region_xy(area, RGN_TYPE_WINDOW, xy) : nullptr;
}

Object *finger_object(bContext *C, const Finger &finger)
{
  if (finger.object_uid == 0) {
    return nullptr;
  }
  return reinterpret_cast<Object *>(
      BKE_libblock_find_session_uid(CTX_data_main(C), ID_OB, finger.object_uid));
}

void holding_update()
{
  int holding = 0;
  for (const Finger &finger : fingers) {
    if (finger.object_uid) {
      holding++;
    }
  }
  fingers_holding = holding;
}

/** Pick the object under a finger landing, as a click would select it. */
void finger_land(bContext *C, wmWindow *win, Finger &finger)
{
  ScrArea *area;
  ARegion *region = viewport_region_at(win, finger.start_xy, &area);
  if (region == nullptr) {
    return;
  }
  const ContextStore store = context_push(C, win, area, region);
  const int mval[2] = {finger.start_xy.x - region->winrct.xmin,
                       finger.start_xy.y - region->winrct.ymin};
  Base *base = ED_view3d_give_base_under_cursor(C, mval);
  const View3D *v3d = CTX_wm_view3d(C);
  if (base && BASE_SELECTABLE(v3d, base) &&
      BKE_id_is_editable(CTX_data_main(C), &base->object->id))
  {
    Object *ob = base->object;
    bool held = false;
    for (const Finger &other : fingers) {
      held |= other.object_uid == ob->id.session_uid;
    }
    /* One finger to an object: a second finger on it does nothing. */
    if (!held) {
      finger.object_uid = ob->id.session_uid;
      const RegionView3D *rv3d = static_cast<const RegionView3D *>(region->regiondata);
      finger.zfac = ED_view3d_calc_zfac(rv3d, ob->object_to_world().location());
    }
  }
  context_pop(C, store);
}

/** The finger's object starts moving: select it, as Tweak selects what it drags. */
void finger_drag_begin(bContext *C, wmWindow *win, Finger &finger, Object *ob)
{
  finger.dragging = true;
  finger.start_location = float3(ob->loc);
  /* The location is in the space of the object's parent, and its parent inverse. */
  float4x4 local;
  BKE_object_to_mat4(ob, local.ptr());
  bool valid = false;
  const float4x4 parent = ob->object_to_world() * math::invert(local, valid);
  finger.world_to_local = valid ? math::invert(float3x3(parent), valid) : float3x3::identity();
  if (!valid) {
    finger.world_to_local = float3x3::identity();
  }

  Scene *scene = WM_window_get_active_scene(win);
  ViewLayer *view_layer = WM_window_get_active_view_layer(win);
  BKE_view_layer_synced_ensure(scene, view_layer);
  Base *base = BKE_view_layer_base_find(view_layer, ob);
  if (base == nullptr) {
    return;
  }
  bool first = true;
  for (const Finger &other : fingers) {
    first &= &other == &finger || !other.dragging;
  }
  ScrArea *area;
  ARegion *region = viewport_region_at(win, finger.start_xy, &area);
  const ContextStore store = context_push(C, win, area, region);
  if (first && !(base->flag & BASE_SELECTED)) {
    ed::object::base_deselect_all(scene, view_layer, CTX_wm_view3d(C), SEL_DESELECT);
  }
  ed::object::base_select(base, ed::object::BA_SELECT);
  if (first) {
    ed::object::base_activate(C, base);
  }
  DEG_id_tag_update(&scene->id, ID_RECALC_SELECT);
  WM_event_add_notifier(C, NC_SCENE | ND_OB_SELECT, scene);
  context_pop(C, store);
}

void object_location_set(bContext *C, Object *ob, const float3 &location)
{
  for (int axis = 0; axis < 3; axis++) {
    if (!(ob->protectflag & (OB_LOCK_LOCX << axis))) {
      ob->loc[axis] = location[axis];
    }
  }
  DEG_id_tag_update(&ob->id, ID_RECALC_TRANSFORM);
  WM_event_add_notifier(C, NC_OBJECT | ND_TRANSFORM, ob);
}

/** Move the finger's object by how far the finger went, at the object's depth. */
void finger_move(bContext *C, wmWindow *win, Finger &finger, const int2 &xy)
{
  Object *ob = finger_object(C, finger);
  if (ob == nullptr) {
    finger.xy = xy;
    return;
  }
  if (!finger.dragging) {
    const float threshold = U.drag_threshold_tablet * UI_SCALE_FAC;
    if (math::distance(float2(xy), float2(finger.start_xy)) < threshold) {
      return;
    }
    if (const wmNativeInterface *native = WM_native_interface(); native && native->tweak_drag) {
      bool move, roll, tilt;
      native->tweak_drag(&move, &roll, &tilt);
      if (!move) {
        return;
      }
    }
    finger_drag_begin(C, win, finger, ob);
  }
  ScrArea *area;
  ARegion *region = viewport_region_at(win, finger.start_xy, &area);
  if (region == nullptr) {
    return;
  }
  const float2 delta = float2(xy - finger.xy);
  finger.xy = xy;
  float3 world_delta;
  ED_view3d_win_to_delta(region, delta, finger.zfac, world_delta);
  object_location_set(
      C, ob, float3(ob->loc) + math::transform_point(finger.world_to_local, world_delta));
  objects_moved = true;
}

/** A tap selects what is under it, as clicking with Tweak does. */
void finger_tap(bContext *C, wmWindow *win, const Finger &finger)
{
  ScrArea *area;
  ARegion *region = viewport_region_at(win, finger.start_xy, &area);
  wmOperatorType *ot = WM_operatortype_find("VIEW3D_OT_select", false);
  if (region == nullptr || ot == nullptr) {
    return;
  }
  const ContextStore store = context_push(C, win, area, region);
  wmEvent event = *win->runtime->eventstate;
  event.type = LEFTMOUSE;
  event.val = KM_CLICK;
  event.xy[0] = finger.start_xy.x;
  event.xy[1] = finger.start_xy.y;
  const bool shift = (event.modifier & KM_SHIFT) != 0;
  PointerRNA props = WM_operator_properties_create_ptr(ot);
  RNA_boolean_set(&props, "deselect_all", !shift);
  RNA_boolean_set(&props, "toggle", shift);
  WM_operator_name_call_ptr(C, ot, wm::OpCallContext::InvokeDefault, &props, &event);
  WM_operator_properties_free(&props);
  context_pop(C, store);
}

void finger_lift(bContext *C, wmWindow *win, const int index, const bool cancelled)
{
  Finger finger = fingers[index];
  fingers.remove(index);
  if (cancelled && finger.dragging) {
    if (Object *ob = finger_object(C, finger)) {
      object_location_set(C, ob, finger.start_location);
    }
  }
  else if (!cancelled && !finger.dragging && fingers_in_gesture == 1 &&
           math::distance(float2(finger.xy), float2(finger.start_xy)) <
               U.drag_threshold_tablet * UI_SCALE_FAC)
  {
    finger_tap(C, win, finger);
  }
  holding_update();
  if (fingers_holding == 0 && objects_moved) {
    objects_moved = false;
    ED_undo_push(C, "Tweak");
  }
  if (fingers.is_empty()) {
    fingers_in_gesture = 0;
  }
}

}  // namespace

bool WM_apple_ios_finger_tweak_active()
{
  return finger_tweak_mode;
}

void WM_apple_ios_finger_tweak_touch(const uint64_t id, const int phase, const int x, const int y)
{
  if (phase == GHOST_kIOSTouchBegan) {
    fingers_pending++;
  }
  finger_touches.push({id, phase, x, y});
}

int WM_apple_ios_finger_tweak_holding(bool *r_landing)
{
  *r_landing = fingers_pending > 0;
  return fingers_holding;
}

void WM_apple_ios_finger_tweak_mode_update(bContext *C)
{
  wmWindow *win = document_window(C);
  bool active = false;
  if (win && !WM_native_ui_desktop_mode()) {
    Scene *scene = WM_window_get_active_scene(win);
    ViewLayer *view_layer = WM_window_get_active_view_layer(win);
    WorkSpace *workspace = WM_window_get_active_workspace(win);
    BKE_view_layer_synced_ensure(scene, view_layer);
    const Object *ob = BKE_view_layer_active_object_get(view_layer);
    const bToolKey key = {SPACE_VIEW3D, CTX_MODE_OBJECT};
    const bToolRef *tool = workspace ? WM_toolsystem_ref_find(workspace, &key) : nullptr;
    active = (ob == nullptr || ob->mode == OB_MODE_OBJECT) && tool &&
             STREQ(tool->idname, "builtin.select");
  }
  finger_tweak_mode = active;
}

void WM_apple_ios_finger_tweak_flush(bContext *C)
{
  Vector<FingerTouch> touches;
  for (FingerTouch &touch : finger_touches.take()) {
    touches.append(touch);
  }
  if (touches.is_empty()) {
    return;
  }
  wmWindow *win = document_window(C);
  for (const FingerTouch &touch : touches) {
    int2 xy(touch.x, touch.y);
    if (win) {
      wm_cursor_position_from_ghost_client_coords(win, &xy.x, &xy.y);
    }
    int index = -1;
    for (const int i : fingers.index_range()) {
      if (fingers[i].id == touch.id) {
        index = i;
      }
    }
    switch (touch.phase) {
      case GHOST_kIOSTouchBegan: {
        fingers_pending--;
        if (index != -1 || win == nullptr) {
          break;
        }
        Finger finger;
        finger.id = touch.id;
        finger.start_xy = xy;
        finger.xy = xy;
        finger_land(C, win, finger);
        fingers.append(finger);
        fingers_in_gesture++;
        holding_update();
        break;
      }
      case GHOST_kIOSTouchMoved:
        if (index != -1 && win) {
          finger_move(C, win, fingers[index], xy);
        }
        break;
      case GHOST_kIOSTouchEnded:
      case GHOST_kIOSTouchCancelled:
        if (index != -1) {
          if (win == nullptr) {
            fingers.remove(index);
            holding_update();
            break;
          }
          if (touch.phase == GHOST_kIOSTouchEnded && !fingers[index].dragging) {
            fingers[index].xy = xy;
          }
          finger_lift(C, win, index, touch.phase == GHOST_kIOSTouchCancelled);
        }
        break;
    }
  }
}

}  // namespace blender

#endif
