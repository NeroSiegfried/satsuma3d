/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup edinterface
 *
 * Blender's menus as `menu` views, see `interface_native.hh`: drawn as Blender draws them, and run
 * as their buttons do, rather than kept as a second list of commands.
 *
 * A menu's item is known by its route: the menu it is in, by Blender's name and, in a Properties
 * tab, the tab after a tab character, then a line for each step to it, each item it is under and
 * the item itself. A step names its item by what it shows and does, which is checked again as it
 * runs: nothing of Blender's is kept between drawing a menu and running its item.
 */

#include "BKE_context.hh"
#include "BKE_screen.hh"
#include "BLT_translation.hh"
#include "BLI_set.hh"
#include "BLI_string_utils.hh"
#include "ED_undo.hh"
#include "RNA_access.hh"
#include "RNA_enum_types.hh"
#include "UI_interface_layout.hh"
#include "WM_api.hh"
#include "WM_native_interface.hh"
#include "WM_types.hh"
#include "interface_intern.hh"
#include "interface_native.hh"

namespace blender::ui {
namespace {
using namespace wm::native_ui;

std::string label(const Button &but)
{
  return but.drawstr.substr(
      0, (but.flag & BUT_HAS_SEP_CHAR) ? but.drawstr.find(UI_SEP_CHAR) : std::string::npos);
}

/** The key that runs the button's operator, as the menu shows it, or null. Mouse buttons and
 * keys the native interface keeps from the operator have none. */
const wmKeyMapItem *shortcut(const bContext *C, const Button &but)
{
  if (!but.optype) {
    return nullptr;
  }
  IDProperty *properties = but.opptr ? static_cast<IDProperty *>(but.opptr->data) : nullptr;
  const wmKeyMapItem *kmi = WM_key_event_operator(C,
                                                  but.optype->idname,
                                                  but.opcontext,
                                                  properties,
                                                  EVT_TYPE_MASK_KEYBOARD,
                                                  EVT_TYPE_MASK_KEYBOARD_MODIFIER,
                                                  nullptr);
  if (kmi == nullptr) {
    return nullptr;
  }
  const wmNativeInterface *native = WM_native_interface();
  if (native && native->keymap_item_hidden && native->keymap_item_hidden(kmi)) {
    return nullptr;
  }
  return kmi;
}

/** A step of a route to \a but: what it shows and does, each after a tab. */
std::string identity(bContext *C, Button &but)
{
  std::string key = label(but) + "\t" + std::to_string(int(but.type));
  if (MenuType *mt = button_menutype_get(&but)) {
    key += std::string("\t") + mt->idname;
  }
  if (but.optype) {
    key += std::string("\t") + but.optype->idname + "\t" + std::to_string(int(but.opcontext));
    if (but.opptr) {
      key += "\t" + RNA_pointer_as_string_keywords(C, but.opptr, false, false, true, INT_MAX);
    }
  }
  if (but.rnaprop) {
    key += std::string("\t") + RNA_property_identifier(but.rnaprop) + "\t" +
           std::to_string(but.rnaindex);
    if (RNA_property_type(but.rnaprop) == PROP_ENUM) {
      key += "\t" + std::to_string(int(but.hardmax));
    }
  }
  /* Lines part the steps of a route. */
  std::replace(key.begin(), key.end(), '\n', ' ');
  return key;
}

/** What a menu is drawn into: the menu's node, the routes of its items. */
struct MenuWriter {
  ViewBuilder &builder;
  NodeId top;
  int separators = 0;
};

struct Invocation {
  wmOperatorType *type = nullptr;
  PointerRNA *properties = nullptr;
  wm::OpCallContext opcontext = wm::OpCallContext::InvokeRegionWin;
  std::unique_ptr<bContextStore> context;
  PointerRNA rnapoin = {};
  PropertyRNA *rnaprop = nullptr;
  int index = -1;
  int enum_value = 0;
  std::string title;

  ~Invocation()
  {
    if (properties) {
      WM_operator_properties_free(properties);
      MEM_delete(properties);
    }
  }

  void capture(Button &but)
  {
    title = label(but);
    if (but.context) {
      context = std::make_unique<bContextStore>(*but.context);
    }
    type = but.optype;
    opcontext = but.opcontext;
    if (type) {
      properties = but.opptr;
      but.opptr = nullptr;
    }
    else {
      rnapoin = but.rnapoin;
      rnaprop = but.rnaprop;
      index = but.rnaindex;
      enum_value = int(but.hardmax);
    }
  }

  void execute(bContext *C)
  {
    const bContextStore *previous = CTX_store_get(C);
    CTX_store_set(C, context.get());
    if (type && WM_operator_poll_context(C, type, opcontext)) {
      WM_operator_name_call_ptr_with_depends_on_cursor(
          C, type, opcontext, properties, nullptr, title);
    }
    else if (rnaprop && RNA_property_editable(&rnapoin, rnaprop)) {
      if (RNA_property_type(rnaprop) == PROP_BOOLEAN) {
        if (RNA_property_array_check(rnaprop)) {
          RNA_property_boolean_set_index(
              &rnapoin, rnaprop, index, !RNA_property_boolean_get_index(&rnapoin, rnaprop, index));
        }
        else {
          RNA_property_boolean_set(
              &rnapoin, rnaprop, !RNA_property_boolean_get(&rnapoin, rnaprop));
        }
      }
      else if (RNA_property_type(rnaprop) == PROP_ENUM) {
        const int value = RNA_property_flag(rnaprop) & PROP_ENUM_FLAG ?
                              RNA_property_enum_get(&rnapoin, rnaprop) ^ enum_value :
                              enum_value;
        RNA_property_enum_set(&rnapoin, rnaprop, value);
      }
      RNA_property_update(C, &rnapoin, rnaprop);
      if (rnapoin.owner_id && RNA_struct_undo_check(rnapoin.type)) {
        ED_undo_push(C, title.c_str());
      }
    }
    CTX_store_set(C, previous);
  }
};

bool is_submenu(Button &but)
{
  return button_menutype_get(&but) || (but.menu_create_func && !button_paneltype_get(&but));
}

bool is_action(Button &but)
{
  return but.optype ||
         (but.rnaprop && ELEM(RNA_property_type(but.rnaprop), PROP_BOOLEAN, PROP_ENUM));
}

/**
 * What the iPad's menu bar leaves out: Blender's own windows, preferences and debugging, files
 * outside the document, and the regions the native interface replaces, which do nothing there or
 * open Blender's desktop interface over it.
 */
bool hidden_from_menu_bar(Button &but)
{
  static const Set<StringRef> operators = {
      "WM_OT_splash",
      "WM_OT_splash_about",
      "WM_OT_quit_blender",
      "WM_OT_save_homefile",
      "WM_OT_read_factory_settings",
      "WM_OT_link",
      "WM_OT_append",
      "WM_OT_window_new",
      "WM_OT_window_new_main",
      "WM_OT_window_fullscreen_toggle",
      "SCREEN_OT_userpref_show",
      "SCREEN_OT_workspace_cycle",
      "SCREEN_OT_screenshot",
      "SCREEN_OT_screenshot_area",
      "OUTLINER_OT_orphans_manage",
      "RENDER_OT_view_show",
      "RENDER_OT_play_rendered_anim",
      "RENDER_OT_opengl",
  };
  static const Set<StringRef> menus = {
      "TOPBAR_MT_blender_system",
      "TOPBAR_MT_file_open_recent",
      "TOPBAR_MT_file_recover",
      "TOPBAR_MT_file_previews",
      "TOPBAR_MT_file_external_data",
      "TOPBAR_MT_file_defaults",
      "INFO_MT_area",
  };
  static const Set<StringRef> properties = {
      "show_statusbar",
      "show_region_toolbar",
      "show_region_ui",
      "show_region_tool_header",
      "show_region_asset_shelf",
      "show_region_hud",
      "show_viewer",
      "use_lock_interface",
  };
  if (but.optype && operators.contains(but.optype->idname)) {
    return true;
  }
  if (MenuType *child = button_menutype_get(&but); child && menus.contains(child->idname)) {
    return true;
  }
  return !but.optype && but.rnaprop && properties.contains(RNA_property_identifier(but.rnaprop));
}

/**
 * Draws the menu \a mt, or the one \a parent opens, and writes its items with \a writer, or
 * follows \a path into it, \a depth steps along, to the item to capture in \a invocation. Routes
 * of items start with \a root.
 */
void project(bContext *C,
             MenuType *mt,
             Button *parent,
             const std::string &root,
             const Span<std::string> path,
             int depth,
             MenuWriter *writer,
             Invocation *invocation)
{
  if (depth > 16) {
    return;
  }
  const bContextStore *previous = CTX_store_get(C);
  if (parent && parent->context) {
    CTX_store_set(C, parent->context);
  }
  if (mt && !WM_menutype_poll(C, mt)) {
    CTX_store_set(C, previous);
    return;
  }
  /* Detached blocks cannot replace visible regions' blocks or survive a file load. */
  Block *block = block_begin(C, nullptr, __func__, EmbossType::Emboss);
  Layout &layout = block_layout(block,
                                  LayoutDirection::Vertical,
                                  LayoutType::Menu,
                                  0,
                                  0,
                                  200,
                                  0,
                                  UI_MENU_PADDING,
                                  style_get_dpi());
  layout.operator_context_set(wm::OpCallContext::InvokeRegionWin);
  if (parent && parent->context) {
    layout.context_copy(parent->context);
  }
  block_flag_enable(block, BLOCK_SHOW_SHORTCUT_ALWAYS);
  if (mt) {
    menutype_draw(C, mt, &layout);
  }
  else if (parent && parent->menu_create_func) {
    parent->menu_create_func(C, &layout, parent->poin);
  }
  block_end(C, block);

  for (const auto &button : block->buttons) {
    Button &but = *button;
    const bool submenu = is_submenu(but);
    const bool action = is_action(but);
    const bool disabled = but.flag & (BUT_DISABLED | BUT_INACTIVE);
    if (depth < path.size()) {
      if (identity(C, but) != path[depth]) {
        continue;
      }
      if (!disabled) {
        if (invocation && depth + 1 == path.size() && action && !submenu) {
          invocation->capture(but);
        }
        else if (submenu) {
          project(C, button_menutype_get(&but), &but, root, path, depth + 1, writer, invocation);
        }
      }
      break;
    }
    if (!writer) {
      continue;
    }
    if (ELEM(root, "TOPBAR_MT_editor_menus", "VIEW3D_MT_editor_menus") && hidden_from_menu_bar(but)) {
      continue;
    }
    if (ELEM(but.type, ButtonType::Sepr, ButtonType::SeprLine)) {
      writer->builder.add(writer->top,
                          "separator:" + std::to_string(writer->separators++),
                          [](auto &buffer, NodeFields & /*fields*/) {
                            return protocol::CreateSeparator(buffer);
                          });
      continue;
    }
    std::string title = label(but);
    if (title.empty()) {
      if (MenuType *child = button_menutype_get(&but)) {
        title = child->label;
      }
    }
    if (title.empty() && but.optype) {
      title = WM_operatortype_name(but.optype, but.opptr);
    }
    if (title.empty()) {
      continue;
    }
    /* The layout's icon, not one for the operator: an enum's choices and submenus can have
     * their own though they run the same operator. */
    const int icon = button_icon(&but);
    const char *icon_name = "";
    if (ELEM(icon, ICON_NONE, ICON_BLANK1) ||
        !RNA_enum_identifier(rna_enum_icon_items, icon, &icon_name))
    {
      icon_name = "";
    }
    std::string route = root;
    for (const std::string &step : path) {
      route += "\n" + step;
    }
    route += "\n" + identity(C, but);
    const auto common = [&](NodeFields &fields) {
      fields.label = title;
      fields.icon = icon_name;
      fields.enabled = !disabled && (submenu || action);
    };
    if (submenu) {
      /* Its route, and the submenu's name, such as `TOPBAR_MT_file_new`. */
      MenuType *child = button_menutype_get(&but);
      writer->builder.add(writer->top, route, [&](auto &buffer, NodeFields &fields) {
        common(fields);
        flatbuffers::Offset<protocol::Param> params[2];
        int count = 0;
        for (const auto &[name, value] :
             {std::pair{"route", route.c_str()}, std::pair{"menu", child ? child->idname : ""}})
        {
          params[count++] = protocol::CreateParamDirect(
              buffer,
              name,
              protocol::Value::TextValue,
              protocol::CreateTextValueDirect(buffer, value).Union());
        }
        return protocol::CreateMenuButton(
            buffer, buffer.CreateString("menu"), buffer.CreateVector(params, count));
      });
      continue;
    }
    /* The key that runs it, as `ctrl+shift+A`. */
    std::string shortcut_text;
    const char *key_name = nullptr;
    if (const wmKeyMapItem *kmi = shortcut(C, but);
        kmi && RNA_enum_identifier(rna_enum_event_type_items, kmi->type, &key_name))
    {
      for (const auto &[held, modifier] : {std::pair{kmi->ctrl, "ctrl+"},
                                           std::pair{kmi->alt, "alt+"},
                                           std::pair{kmi->shift, "shift+"},
                                           std::pair{kmi->oskey, "oskey+"}})
      {
        if (held == KM_MOD_HELD) {
          shortcut_text += modifier;
        }
      }
      shortcut_text += key_name;
    }
    writer->builder.add(writer->top, route, [&](auto &buffer, NodeFields &fields) {
      common(fields);
      return protocol::CreateButtonDirect(buffer,
                                          protocol::ButtonStyle::Normal,
                                          but.optype ? but.optype->idname : nullptr,
                                          nullptr,
                                          shortcut_text.empty() ? nullptr : shortcut_text.c_str(),
                                          action && but.rnaprop && button_is_pushed(&but));
    });
  }
  block_free(nullptr, block);
  CTX_store_set(C, previous);
}
}  // namespace

static const char *native_context_menu_id(const bContext *C)
{
  switch (CTX_data_mode_enum(C)) {
    case CTX_MODE_OBJECT: return "VIEW3D_MT_object_context_menu";
    case CTX_MODE_EDIT_MESH: return "VIEW3D_MT_edit_mesh_context_menu";
    case CTX_MODE_EDIT_CURVE:
    case CTX_MODE_EDIT_SURFACE: return "VIEW3D_MT_edit_curve_context_menu";
    case CTX_MODE_EDIT_TEXT: return "VIEW3D_MT_edit_font_context_menu";
    case CTX_MODE_EDIT_ARMATURE: return "VIEW3D_MT_armature_context_menu";
    case CTX_MODE_EDIT_METABALL: return "VIEW3D_MT_edit_metaball_context_menu";
    case CTX_MODE_EDIT_LATTICE: return "VIEW3D_MT_edit_lattice_context_menu";
    case CTX_MODE_EDIT_CURVES: return "VIEW3D_MT_edit_curves_context_menu";
    case CTX_MODE_EDIT_GREASE_PENCIL: return "VIEW3D_MT_greasepencil_edit_context_menu";
    case CTX_MODE_POSE: return "VIEW3D_MT_pose_context_menu";
    case CTX_MODE_PARTICLE: return "VIEW3D_MT_particle_context_menu";
    case CTX_MODE_SCULPT: return "VIEW3D_PT_sculpt_context_menu";
    case CTX_MODE_PAINT_WEIGHT: return "VIEW3D_PT_paint_weight_context_menu";
    case CTX_MODE_PAINT_VERTEX: return "VIEW3D_PT_paint_vertex_context_menu";
    case CTX_MODE_PAINT_TEXTURE: return "VIEW3D_PT_paint_texture_context_menu";
    case CTX_MODE_PAINT_GREASE_PENCIL: return "VIEW3D_PT_greasepencil_draw_context_menu";
    case CTX_MODE_SCULPT_GREASE_PENCIL: return "VIEW3D_PT_greasepencil_sculpt_context_menu";
    case CTX_MODE_WEIGHT_GREASE_PENCIL: return "VIEW3D_PT_greasepencil_weight_context_menu";
    case CTX_MODE_VERTEX_GREASE_PENCIL: return "VIEW3D_PT_greasepencil_vertex_paint_context_menu";
    default: return nullptr;
  }
}

/** \a text up to \a separator, and what comes after it, if anything. */
static std::pair<StringRef, StringRef> split(const StringRef text, const char separator)
{
  const int64_t found = text.find(separator);
  if (found == StringRef::not_found) {
    return {text, {}};
  }
  return {text.substr(0, found), text.substr(found + 1)};
}

/** The steps of \a route, after its first line, the root's. */
static Vector<std::string> route_path(const StringRef route)
{
  Vector<std::string> steps;
  for (StringRef rest = split(route, '\n').second; !rest.is_empty();) {
    const auto [step, after] = split(rest, '\n');
    steps.append(step);
    rest = after;
  }
  return steps;
}

/** Writes the menu \a route names, with \a writer, or with \a invocation runs its item. */
static void native_menu(bContext *C,
                        const StringRef route,
                        MenuWriter *writer,
                        Invocation *invocation)
{
  const StringRef first = split(route, '\n').first;
  const std::string root = split(first, '\t').first;
  const Vector<std::string> path = route_path(route);
  if (root == "menubar" && path.is_empty() && writer) {
    for (const char *idname : {"TOPBAR_MT_editor_menus", "VIEW3D_MT_editor_menus"}) {
      if (MenuType *mt = WM_menutype_find(idname, true)) {
        project(C, mt, nullptr, idname, path, 0, writer, nullptr);
      }
    }
    return;
  }
  if (invocation && root == "context") {
    return;
  }
  const char *context_id = native_context_menu_id(C);
  const std::string resolved = root == "context" ? (context_id ? context_id : "") : root;
  /* A Properties tab's menus are drawn in a Properties editor of their own, see
   * #native::in_properties_tab, and checked as the viewport's. */
  const bool properties_menu = CTX_wm_space_properties(C) &&
                               WM_menutype_find(resolved.c_str(), true);
  if (!ELEM(resolved,
            "TOPBAR_MT_editor_menus",
            "VIEW3D_MT_editor_menus",
            "VIEW3D_MT_add",
            /* The Share menu's Import and Export. */
            "TOPBAR_MT_file_import",
            "TOPBAR_MT_file_export") &&
      (!context_id || resolved != context_id) && !properties_menu)
  {
    return;
  }
  /* What `first` names its items' routes after: the menu, and its tab. */
  const std::string item_root = root == "context" ? resolved : std::string(first);
  if (MenuType *mt = WM_menutype_find(resolved.c_str(), true)) {
    project(C, mt, nullptr, item_root, path, 0, writer, invocation);
    if (invocation) {
      invocation->execute(C);
    }
  }
  else if (PanelType *pt = WM_paneltype_find(resolved.c_str(), true)) {
    /* A mode whose context menu is a panel of settings, such as Sculpt Mode's: opened as one. */
    if (pt->poll && !pt->poll(C, pt)) {
      return;
    }
    if (writer && path.is_empty()) {
      const std::string label = std::string(pt->label) + " Settings";
      writer->builder.add(
          writer->top, resolved + "\npanel", [&](auto &buffer, NodeFields &fields) {
            fields.label = label;
            return protocol::CreateButtonDirect(
                buffer, protocol::ButtonStyle::Normal, "WM_OT_call_panel");
          });
    }
    else if (invocation && path.size() == 1 && path[0] == "panel") {
      PointerRNA properties = WM_operator_properties_create("WM_OT_call_panel");
      RNA_string_set(&properties, "name", resolved.c_str());
      WM_operator_name_call(
          C, "WM_OT_call_panel", wm::OpCallContext::InvokeRegionWin, &properties, nullptr);
      WM_operator_properties_free(&properties);
    }
  }
}

/** The heading of the context menu: as Blender titles it, or for Edit Mode, its mode, as
 * "Mesh". */
static std::string native_context_menu_heading(bContext *C)
{
  const char *context_id = native_context_menu_id(C);
  if (!context_id) {
    return "";
  }
  std::string heading;
  if (MenuType *mt = WM_menutype_find(context_id, true)) {
    heading = CTX_IFACE_(mt->translation_context, mt->label);
  }
  else if (PanelType *pt = WM_paneltype_find(context_id, true)) {
    heading = CTX_IFACE_(pt->translation_context, pt->label);
  }
  const char *mode_name = nullptr;
  if (heading.empty() &&
      RNA_enum_name(rna_enum_context_mode_items, CTX_data_mode_enum(C), &mode_name))
  {
    heading = IFACE_(mode_name);
    const std::string suffix = " Edit";
    if (heading.size() > suffix.size() && heading.ends_with(suffix)) {
      heading.resize(heading.size() - suffix.size());
    }
  }
  return heading;
}

namespace native {

void menu_write(bContext *C, const StringRef route, ViewBuilder &builder)
{
  const auto [first, path] = split(route, '\n');
  const StringRef tab = split(first, '\t').second;
  const std::string heading = first == "context" && path.is_empty() ?
                                native_context_menu_heading(C) :
                                "";
  MenuWriter writer{builder, builder.top("menu", [&](auto &buffer, NodeFields &fields) {
                      fields.label = heading;
                      return protocol::CreateMenu(buffer);
                    })};
  in_properties_tab(C, tab, [&]() { native_menu(C, route, &writer, nullptr); });
}

void menu_run(bContext *C, const StringRef route)
{
  const StringRef tab = split(split(route, '\n').first, '\t').second;
  in_properties_tab(C, tab, [&]() {
    Invocation invocation;
    native_menu(C, route, nullptr, &invocation);
  });
}

}  // namespace native

}  // namespace blender::ui
