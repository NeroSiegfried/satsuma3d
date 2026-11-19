/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup edinterface
 *
 * What a finger meets in Blender's own interface (ROUND5 13A, decision 84): which directions each
 * kind of button takes a drag for itself, the buttons of a region with those directions, and
 * whether a popup scrolls. The iPad's window asks this through a map the window manager keeps
 * after each draw (`wm_native_ui.cc`), so a touch is told apart before it acts (13B): a drag along
 * a direction that scrolls and that the control does not take scrolls; any other drag is the
 * control's.
 */

#include "BLI_listbase.h"
#include "BLI_rect.h"

#include "DNA_screen_types.h"

#include "BKE_screen.hh"

#include "interface_intern.hh"

namespace blender::ui {

/* A button type missing from the list below is an error, not a warning (ROUND5 13A.3). */
#if defined(__clang__)
#  pragma clang diagnostic push
#  pragma clang diagnostic error "-Wswitch"
#elif defined(__GNUC__)
#  pragma GCC diagnostic push
#  pragma GCC diagnostic error "-Wswitch"
#endif

TouchTakes button_type_touch_takes(const ButtonType type)
{
  /* The list is closed: no `default`, so a new button type fails the build until it is placed
   * (ROUND5 13A.3). */
  switch (type) {
    /* A drag along x changes the value, or selects text. */
    case ButtonType::Num:
    case ButtonType::NumSlider:
    case ButtonType::Text:
    case ButtonType::SearchMenu:
      return TouchTakes::X;
    /* Controls that take a drag in both directions: a scrollbar, the colour pickers, curves and
     * colour bands, the normal's sphere, a list's grip, scopes, a tracking preview, a socket. */
    case ButtonType::Scroll:
    case ButtonType::HsvCube:
    case ButtonType::HsvCircle:
    case ButtonType::ColorBand:
    case ButtonType::Unitvec:
    case ButtonType::Curve:
    case ButtonType::CurveProfile:
    case ButtonType::TrackPreview:
    case ButtonType::Histogram:
    case ButtonType::Waveform:
    case ButtonType::Vectorscope:
    case ButtonType::Grip:
    case ButtonType::NodeSocket:
      return TouchTakes::Both;
    /* Pressed, not dragged: a drag on them scrolls where the region scrolls. What Blender drags
     * away (a list's or a tree's row, a preview, a colour swatch, a data-block) is dragged after a
     * hold, so a scroll that begins on it is never taken for a drag (ROUND6 DESK-4, C12). */
    case ButtonType::ListRow:
    case ButtonType::ViewItem:
    case ButtonType::PreviewTile:
    case ButtonType::But:
    case ButtonType::Row:
    case ButtonType::Menu:
    case ButtonType::ButMenu:
    case ButtonType::Toggle:
    case ButtonType::ToggleN:
    case ButtonType::IconToggle:
    case ButtonType::IconToggleN:
    case ButtonType::ButToggle:
    case ButtonType::Checkbox:
    case ButtonType::CheckboxN:
    case ButtonType::Color:
    case ButtonType::Tab:
    case ButtonType::Popover:
    case ButtonType::Block:
    case ButtonType::Label:
    case ButtonType::KeyEvent:
    case ButtonType::Pulldown:
    case ButtonType::Roundbox:
    case ButtonType::ListBox:
    case ButtonType::Extra:
    case ButtonType::HotkeyEvent:
    case ButtonType::Image:
    case ButtonType::Progress:
    case ButtonType::Sepr:
    case ButtonType::SeprLine:
    case ButtonType::SeprSpacer:
    case ButtonType::Decorator:
      return TouchTakes::None;
  }
  BLI_assert_unreachable();
  return TouchTakes::None;
}

#if defined(__clang__)
#  pragma clang diagnostic pop
#elif defined(__GNUC__)
#  pragma GCC diagnostic pop
#endif

const char *touch_takes_name(const TouchTakes takes)
{
  switch (takes) {
    case TouchTakes::None:
      return "none";
    case TouchTakes::X:
      return "x";
    case TouchTakes::Y:
      return "y";
    case TouchTakes::Both:
      return "both";
  }
  return "none";
}

void region_touch_buttons(const ARegion *region, Vector<TouchButton> &r_buttons)
{
  /* Each panel's header, as #draw_aligned_panel places it: no control of its own (a tap folds the
   * panel, a hold then a drag moves it), so `takes` none; listed for the check scripts to find. */
  for (const Block &block : region->runtime->uiblocks) {
    const Panel *panel = block.panel;
    if (panel == nullptr || panel->type == nullptr || (panel->type->flag & PANEL_TYPE_NO_HEADER) ||
        panel->sizex < 0 || panel->sizey < 0 || !panel_is_active(panel))
    {
      continue;
    }
    rcti rect;
    button_to_pixelrect(&rect, region, &block, nullptr);
    rcti header = {rect.xmin, rect.xmax, rect.ymax, rect.ymax + int(PNL_HEADER / block.aspect)};
    BLI_rcti_translate(&header, region->winrct.xmin, region->winrct.ymin);
    if (BLI_rcti_isect(&header, &region->winrct, &header)) {
      r_buttons.append({header, TouchTakes::None, TOUCH_PANEL_HEADER});
    }
  }
  for (const Block &block : region->runtime->uiblocks) {
    for (const std::unique_ptr<Button> &but : block.buttons) {
      if ((but->flag & UI_HIDDEN) || !button_is_interactive(but.get(), true)) {
        continue;
      }
      rctf window;
      block_to_window_rctf(region, &block, &window, &but->rect);
      rcti rect;
      BLI_rcti_rctf_copy_round(&rect, &window);
      /* Clipped to the region: what scrolled out of it is not under a finger. */
      if (!BLI_rcti_isect(&rect, &region->winrct, &rect)) {
        continue;
      }
      r_buttons.append({rect,
                        button_type_touch_takes(but->type),
                        int8_t(but->type)});
    }
  }
}

bool region_popup_scrolls(const ARegion *region)
{
  for (const Block &block : region->runtime->uiblocks) {
    if (block.flag & (BLOCK_CLIPTOP | BLOCK_CLIPBOTTOM)) {
      return true;
    }
  }
  return false;
}

}  // namespace blender::ui
