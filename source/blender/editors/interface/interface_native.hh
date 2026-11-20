/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup edinterface
 *
 * Blender's panels as views of controls for a platform's own interface, see
 * `WM_native_ui_views.hh`. `interface_native_properties.cc` writes their nodes from the buttons
 * Blender draws, and edits them as the buttons do; `interface_native_view.cc` makes views of them
 * and carries out their commands.
 */

#pragma once

#include <set>
#include <string>

#include "BLI_function_ref.hh"
#include "BLI_map.hh"
#include "BLI_string_ref.hh"
#include "BLI_vector.hh"

#include "WM_native_interface.hh"
#include "WM_native_ui_views.hh"

namespace blender {
struct bContext;
}

namespace blender::ui {
struct Block;
struct Button;
}

namespace blender::ui::native {

/** What a control edits: a button, found again by its key in the panel that draws it. */
struct Edit {
  enum class Kind : uint8_t {
    Property,
    Operator,
    /** An operator's enum as a menu, such as Add Modifier. */
    OperatorMenu,
    /** A data-block picker. */
    Picker,
    List,
    /** An operator run by its name, as a list's Duplicate. */
    Call,
    /** A color ramp's stops. */
    Ramp,
    /** A curve's points (ROUND6 PANEL-7). */
    Curve,
  };
  Kind kind = Kind::Property;
  /** The panel drawing it, by its id. */
  std::string panel;
  std::string key;
  /** Which of the buttons with its key it is, as each row of a list has its own. */
  int occurrence = 0;
  /** A component of an array, whose keyframe can be inserted alone. */
  bool component = false;
  /** A slider, which an edit to the value it has leaves alone. */
  bool slider = false;
  /** A list's add and remove buttons, by their keys; a physics' switch's panel as `add`. */
  std::string add, remove;
};

/** A row of a list: the list's key, its index, and the name drawn on it, if any, by its key and
 * which of the names with that key it is. */
struct Row {
  std::string list;
  int64_t index = 0;
  std::string name;
  int name_occurrence = 0;
};

/** A panel, by its node's key: its id, whether it is outermost, and whether it is open. */
struct PanelState {
  std::string id;
  bool outer = false;
  bool open = false;
  /** A section of a panel (`layout.panel`, ROUND6 PANEL-3): the panel's id; and whether it opens
   * by a property of what it belongs to, such as a modifier's, rather than a state the view keeps. */
  std::string section_of;
  bool section_property = false;
};

/** What a view of panels keeps between its builds and the commands that follow them. */
struct PanelsData : public wm::native_ui::ViewData {
  std::string tab;
  /** The Properties editor's own Tool tab, rather than the tool settings. */
  bool tool_tab = false;
  /** The described object and tab (and tool), which edits name. */
  std::string identity;

  /** What each node edits, by its key. */
  Map<std::string, Edit> edits;
  Map<std::string, Row> rows;
  Map<std::string, PanelState> panels;

  /** A drag's interaction, which makes one undo step of it. */
  int interaction = 0;
  bool dragging = false;

  /** Per tab: its open panels, once an interface opened or closed one. Kept for as long as
   * Blender runs, as a view shown again is subscribed to again. */
  static Map<std::string, std::set<std::string>> &expanded()
  {
    static Map<std::string, std::set<std::string>> expanded;
    return expanded;
  }
  /** Per tab: sub-panels an interface opened or closed. */
  static Map<std::string, Map<std::string, bool>> &subpanels()
  {
    static Map<std::string, Map<std::string, bool>> subpanels;
    return subpanels;
  }

  /**
   * With several objects selected, an edit goes to every selected item that has the property, as
   * Alt does on the desktop, rather than to the active one alone (decision R6-10, ROUND6
   * PANEL-6): the switch at the top of Properties. Off, as on the desktop.
   */
  static bool &edit_selected()
  {
    static bool edit_selected = false;
    return edit_selected;
  }

  /** The tab's open panels: those open now, the first time one is opened or closed. */
  std::set<std::string> &expanded_panels()
  {
    return expanded().lookup_or_add_cb(tab, [&]() {
      std::set<std::string> opened;
      for (const PanelState &state : panels.values()) {
        if (state.outer && state.open) {
          opened.insert(state.id);
        }
      }
      return opened;
    });
  }

  void clear()
  {
    edits.clear();
    rows.clear();
    panels.clear();
  }
};

/** An edit a command asks for, see #panels_edit. */
struct EditRequest {
  const Edit *edit = nullptr;
  /** What is done, as `select` of a picker, or empty to set its value. */
  std::string action;
  const wm::native_ui::protocol::Command *command = nullptr;
  /** The row, the place it moves to, or the place of a stack's panel. */
  int64_t index = -1, to = -1;
  /** A text: a name, a file. */
  std::string text;
  /** A font family's faces, by the slot each goes in. */
  Vector<std::pair<std::string, std::string>> family;
  /** A drag, as one step to undo, and how far it is. */
  std::string interaction;
  std::string phase;
  /** With `button` as the action: called with the button the edit's key names, as the panel
   * draws it (#panel_button). */
  FunctionRef<void(Button &)> with_button;
};

/**
 * The root of a route to a menu Blender builds in C for a panel's button (ROUND6 PANEL-4), such
 * as a modifier's header menu: `panel`, then, each after #PANEL_MENU_PART, 1 for the Properties'
 * Tool tab, the panel's id and the button's key. The tab follows as for every route.
 */
inline constexpr const char *PANEL_MENU_ROOT = "panel";
inline constexpr char PANEL_MENU_PART = '\x1f';
/**
 * The root of a route to Blender's context menu for a panel's control (ROUND6 PANEL-12):
 * `button`, then, each after #PANEL_MENU_PART, 1 for the Properties' Tool tab, the panel's id,
 * the control's key and which of the buttons with that key it is.
 */
inline constexpr const char *BUTTON_MENU_ROOT = "button";

/**
 * Calls \a fn with the button \a key names in the panel \a panel of \a tab, drawn as the
 * panels' view draws it there (the Properties' Tool tab with \a tool_tab); false where it is no
 * longer there.
 */
bool panel_button(bContext *C,
                  StringRef tab,
                  bool tool_tab,
                  StringRef panel,
                  StringRef key,
                  FunctionRef<void(Button &)> fn,
                  int occurrence = 0);

/** The node editor's view, see `interface_native_view.cc`: its tree's nodes as records, and their
 * values as controls. */
struct NodesData : public PanelsData {
  /** Which tree it shows, as the interface says: its kind as `tree`, and whether with a
   * `backdrop` and `previews`. */
  std::unique_ptr<io::serialize::DictionaryValue> state =
      std::make_unique<io::serialize::DictionaryValue>();
  /** The `sequence` of the last edit, and why it failed. */
  int64_t ack = 0;
  std::string error;
  /** The tree the nodes to add were sent for, as they are once for each. */
  std::string add_for;
  /** The compositor's result is drawn behind its nodes, and computed once it is shown. */
  bool composite = false;
};

/** Write the view of \a data's panels, see #PanelsData. */
void panels_write(bContext *C, PanelsData &data, wm::native_ui::ViewBuilder &builder);
/** Carry out an edit of a view of panels, or say why it cannot be. */
std::string panels_edit(bContext *C, PanelsData &data, const EditRequest &request);

/** The last operation's properties, to adjust it, see `native_redo_operator_register`. */
void redo_write(bContext *C, PanelsData &data, wm::native_ui::ViewBuilder &builder);
std::string redo_edit(bContext *C, PanelsData &data, const EditRequest &request);
/** An operator's properties before it runs, see `native_operator_dialog_begin`. */
void dialog_write(bContext *C, PanelsData &data, wm::native_ui::ViewBuilder &builder);
std::string dialog_edit(bContext *C, PanelsData &data, const EditRequest &request);

/** One of Blender's menus by its route, see `interface_native_menu.cc`: its items, keyed by
 * their own routes. */
void menu_write(bContext *C, StringRef route, wm::native_ui::ViewBuilder &builder);
/** Run the menu item at \a route. */
void menu_run(bContext *C, StringRef route);

/** Takes the items of \a block, a popup menu titled \a title, for #popup_menu_choose. */
wmNativePopupMenu popup_menu_take(bContext *C, Block *block, StringRef title);
/** Runs the item of the last menu taken, as its button would: empty, or why nothing ran. */
std::string popup_menu_choose(bContext *C, StringRef value);
/**
 * Whether the interface draws the menu \a idname here, by itself or as the root of a route: the
 * menu exists, its poll passes in \a C, and it is one the interface shows (the menu bars, Add,
 * Import and Export, the mode's context menu, a Properties tab's) or one Blender asked to pop up,
 * see #menu_popup_asked. What it cannot draw, Blender draws (`bridge_menu_popup`).
 */
bool menu_can_show(bContext *C, StringRef idname);
/** Blender asked for \a idname to pop up, as a key or a pie does: drawn where it is asked for. */
void menu_popup_asked(StringRef idname);
/** Calls \a fn in a Properties editor showing \a tab, as its menus are drawn in, or as it is
 * without a tab, or for the Tool tab. */
void in_properties_tab(bContext *C, StringRef tab, FunctionRef<void()> fn);

void nodes_write(bContext *C, NodesData &data, wm::native_ui::ViewBuilder &builder);
/** An edit of the tree itself, such as moving nodes, as \a edit's values describe it. */
std::string nodes_edit(bContext *C, NodesData &data, const io::serialize::DictionaryValue &edit);
/** An edit of a node's value, or of the editor's header. */
std::string nodes_edit_control(bContext *C, NodesData &data, const EditRequest &request);

}  // namespace blender::ui::native

/**
 * The panels' census (ROUND6 PANEL-1), for the Mac harness's `census` scenario, by name through
 * the C API: while recording, every panel written notes what became of each button it drew;
 * taking returns those notes since the last take, as a JSON array, and forgets them. The text
 * stays valid until the next take.
 */
extern "C" void UI_native_panel_census_record(bool on);
extern "C" const char *UI_native_panel_census_take();
