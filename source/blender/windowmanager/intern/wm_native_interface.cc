/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 */

#include "WM_api.hh"
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
  if (!native_interface) {
    return false;
  }
  /* Started by a finger or button still down: it follows that one, as on the desktop. */
  if (event && ISMOUSE_BUTTON(event->type) && ELEM(event->val, KM_PRESS, KM_PRESS_DRAG)) {
    return false;
  }
  /* A touch started it, not the interface or the editor: a mouse or trackpad hovers. */
  return WM_event_touch_input();
}

}  // namespace blender
