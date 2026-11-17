/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 */

#include "WM_native_interface.hh"
#include "WM_types.hh"

namespace blender {

static const wmNativeInterface *native_interface = nullptr;

const wmNativeInterface *WM_native_interface()
{
  return native_interface;
}

void WM_native_interface_set(const wmNativeInterface *native)
{
  native_interface = native;
}

bool WM_native_awaits_press(const wmEvent *event)
{
  const wmNativeInterface *native = native_interface;
  if (!native || !native->replaces_redo_panel || !native->replaces_redo_panel()) {
    return false;
  }
  /* Started by a finger or button still down: it follows that one, as on the desktop. */
  if (event && ISMOUSE_BUTTON(event->type) && ELEM(event->val, KM_PRESS, KM_PRESS_DRAG)) {
    return false;
  }
  return true;
}

bool WM_native_event_is_left_press(const wmEvent *event)
{
  if (event->type == LEFTMOUSE) {
    return event->val == KM_PRESS;
  }
  return event->type == EVT_MODAL_MAP && event->prev_type == LEFTMOUSE &&
         event->prev_val == KM_PRESS;
}

}  // namespace blender
