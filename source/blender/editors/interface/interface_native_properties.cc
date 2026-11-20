/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup edinterface
 *
 * Blender's panels as the controls of views for a platform's own interface, see
 * `interface_native.hh`: written from the buttons Blender draws, and edited as they are.
 */
#include "BKE_animsys.h"
#include "BKE_colorband.hh"
#include "BKE_appdir.hh"
#include "BKE_context.hh"
#include "BKE_global.hh"
#include "BKE_icons.hh"
#include "BKE_lib_id.hh"
#include "BKE_library.hh"
#include "BKE_preview_image.hh"
#include "BKE_studiolight.h"
#include "BKE_main.hh"
#include "BKE_modifier.hh"
#include "BLI_string.h"
#include "BLI_math_vector.h"
#include "DNA_node_types.h"
#include "DNA_material_types.h"
#include "BKE_object.hh"
#include "BKE_main_invariants.hh"
#include "BKE_node_tree_zones.hh"
#include "NOD_node_declaration.hh"
#include "BKE_node_tree_update.hh"
#include "BKE_node_runtime.hh"
#include "BKE_node.hh"
#include "BKE_material.hh"
#include "BKE_image.hh"
#include "DNA_image_types.h"
#include "BKE_packedFile.hh"
#include "BKE_scene.hh"
#include "BKE_screen.hh"
#include "BKE_workspace.hh"
#include "BKE_vfont.hh"
#include "BLI_array.hh"
#include "BLI_listbase.h"
#include "BLI_rect.h"
#include "BLI_serialize.hh"
#include "DEG_depsgraph.hh"
#include "DEG_depsgraph_build.hh"
#include "DNA_ID.h"
#include "DNA_color_types.h"
#include "DNA_curve_types.h"
#include "DNA_modifier_types.h"
#include "DNA_object_types.h"
#include "DNA_space_types.h"
#include "DNA_userdef_types.h"
#include "DNA_vfont_types.h"
#include "DNA_workspace_types.h"
#include "ED_buttons.hh"
#include "ED_node.hh"
#include "BLI_fileops.h"
#include "BLI_hash_mm2a.hh"
#include "BKE_scene_runtime.hh"
#include "NOD_geometry_nodes_log.hh"
#include "ED_node_preview.hh"
#include "ED_render.hh"
#include "ED_undo.hh"
#include "IMB_colormanagement.hh"
#include "IMB_imbuf.hh"
#include "IMB_imbuf_types.hh"
#include "RNA_access.hh"
#include "RNA_enum_types.hh"
#include "RNA_path.hh"
#include "RNA_prototypes.hh"
#include "UI_interface_layout.hh"
#include "UI_tree_view.hh"
#include "WM_api.hh"
#include "WM_types.hh"
#include "WM_toolsystem.hh"
#include "WM_keymap.hh"
#include "interface_intern.hh"
#include "interface_native.hh"
#include "wm_event_system.hh"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <functional>
#include <optional>
#include <map>
#include <set>
#include <sstream>
#include <vector>

namespace blender::ui {
namespace {
using namespace io::serialize;
using namespace wm::native_ui;

/* A detached editor provides the same context as the desktop one, without changing the visible
 * area or retaining scene pointers between requests. */
struct DetachedAreaContext {
  bContext *C;
  ScrArea *previous_area;
  ARegion *previous_region;
  ScrArea area = {};
  SpaceLink *link;
  ARegion *region;

  DetachedAreaContext(bContext *context, const short spacetype) : C(context)
  {
    previous_area = CTX_wm_area(C);
    previous_region = CTX_wm_region(C);
    area.spacetype = spacetype;
    area.type = BKE_spacetype_from_id(spacetype);
    link = area.type->create(&area, CTX_data_scene(C));
    BLI_addtail(&area.spacedata, link);
    std::swap(area.regionbase, link->regionbase);
    region = BKE_area_find_region_type(&area, RGN_TYPE_WINDOW);
    region->runtime->type = BKE_regiontype_from_id(area.type, RGN_TYPE_WINDOW);
    region->winx = 320;
    region->winy = 1200;
    area.winx = region->winx;
    area.winy = region->winy;
    CTX_wm_area_set(C, &area);
    CTX_wm_region_set(C, region);
  }

  virtual ~DetachedAreaContext()
  {
    /* Instanced modifier/constraint panels can start window-level animation handlers.
     * Retire those handlers and timers before freeing their temporary panels. */
    panels_free_instanced(C, region);
    CTX_wm_area_set(C, previous_area);
    CTX_wm_region_set(C, previous_region);
    BKE_screen_area_free(&area);
  }
};

/* A detached Properties editor, with its context computed for the active object. */
struct PropertiesContext : DetachedAreaContext {
  SpaceProperties *space;

  PropertiesContext(bContext *context) : DetachedAreaContext(context, SPACE_PROPERTIES)
  {
    space = reinterpret_cast<SpaceProperties *>(link);
    ED_buttons_native_context_prepare(C, space);
  }
};

/** Blender's own name of \a icon, which lasts as long as Blender runs. */
const char *icon_name(const int icon)
{
  const char *name = nullptr;
  return RNA_enum_identifier(rna_enum_icon_items, icon, &name) ? name : "";
}

/**
 * PNG of an ID's preview icon (a Grease Pencil material, for example). Written again when the
 * preview changes, so snapshots only carry a path.
 */
std::string id_preview_icon_path(const bContext *C, const int icon_id)
{
  static std::map<int, std::pair<int, std::string>> written;
  const PreviewImage *prv = icon_id_preview(C, icon_id);
  if (prv == nullptr) {
    /* Until its job has rendered it there is no preview; a later snapshot picks it up. */
    const auto found = written.find(icon_id);
    return found != written.end() ? found->second.second : "";
  }
  const int stamp = prv->changed_timestamp[ICON_SIZE_PREVIEW];
  if (const auto found = written.find(icon_id);
      found != written.end() && found->second.first == stamp)
  {
    return found->second.second;
  }
  ImBuf *ibuf = IMB_allocFromBuffer(reinterpret_cast<const uint8_t *>(prv->rect[ICON_SIZE_PREVIEW]),
                                    nullptr,
                                    prv->w[ICON_SIZE_PREVIEW],
                                    prv->h[ICON_SIZE_PREVIEW],
                                    4);
  if (!ibuf) {
    return "";
  }
  /* Previews are premultiplied, PNG is not. */
  IMB_unpremultiply_alpha(ibuf);
  ibuf->planes = 32;
  ibuf->ftype = IMB_FTYPE_PNG;
  /* A new name for each version, so UIKit does not show an image it cached. */
  const std::string path = std::string(BKE_tempdir_session()) + "native_preview_" +
                           std::to_string(icon_id) + "_" + std::to_string(stamp) + ".png";
  const bool saved = IMB_save_image(ibuf, path.c_str(), IB_byte_data);
  IMB_freeImBuf(ibuf);
  written[icon_id] = {stamp, saved ? path : ""};
  return saved ? path : "";
}

/**
 * PNG of a preview icon: a studio light (MatCaps, HDRIs and studio lights in viewport shading),
 * as `template_icon_view` shows them, or an ID's preview. Studio lights are rendered once per
 * session, so snapshots only carry a path.
 */
std::string preview_icon_path(const bContext *C, const int icon_id)
{
  static std::map<int, std::string> rendered;
  if (icon_id < BIFICONID_LAST_STATIC) {
    return "";
  }
  if (const auto found = rendered.find(icon_id); found != rendered.end()) {
    return found->second;
  }
  if (const Icon *icon = BKE_icon_get(icon_id); icon && icon->obj_type != ICON_DATA_STUDIOLIGHT) {
    /* Of the IDs, only materials are picked from previews, as in Blender's material popovers. */
    return icon->id_type == ID_MA ? id_preview_icon_path(C, icon_id) : "";
  }
  /* Studio light previews come from the icon's own preview job; until it finishes there is
   * no preview, and a later snapshot picks it up. */
  const uint8_t *pixels = icon_studiolight_preview(C, icon_id);
  if (!pixels) {
    return "";
  }
  ImBuf *ibuf = IMB_allocFromBuffer(
      pixels, nullptr, STUDIOLIGHT_ICON_SIZE, STUDIOLIGHT_ICON_SIZE, 4);
  if (!ibuf) {
    return "";
  }
  ibuf->planes = 32;
  ibuf->ftype = IMB_FTYPE_PNG;
  const std::string path = std::string(BKE_tempdir_session()) + "native_preview_" +
                           std::to_string(icon_id) + ".png";
  const bool saved = IMB_save_image(ibuf, path.c_str(), IB_byte_data);
  IMB_freeImBuf(ibuf);
  return rendered[icon_id] = saved ? path : "";
}

std::string property_key(const Button &but, int index)
{
  const auto path = RNA_path_from_ID_to_struct(&but.rnapoin);
  return std::to_string(but.rnapoin.owner_id ? but.rnapoin.owner_id->session_uid : 0) + ":" +
         (path ? *path : RNA_struct_identifier(but.rnapoin.type)) + ":" +
         RNA_property_identifier(but.rnaprop) + ":" + std::to_string(index);
}

bool panel_poll(bContext *C, PanelType *panel)
{
  return (!panel->parent || panel_poll(C, panel->parent)) &&
         (!panel->poll || panel->poll(C, panel));
}

bool is_color(PointerRNA *ptr, PropertyRNA *prop)
{
  return RNA_property_type(prop) == PROP_FLOAT &&
         ELEM(RNA_property_subtype(prop), PROP_COLOR, PROP_COLOR_GAMMA) &&
         ELEM(RNA_property_array_length(ptr, prop), 3, 4);
}

/* -------------------------------------------------------------------- */
/** \name Multiple Selection
 *
 * As Blender's buttons do with Alt held (see #ui_selectcontext_begin), a property edits every
 * selected item that has it. Natively that is always so: only the properties all selected items
 * have are shown, with a dash where their values differ.
 * \{ */

struct SelectedOthers {
  /** The same property of every other selected item. */
  Vector<std::pair<PointerRNA, PropertyRNA *>> items;
  /** A selected item doesn't have the property. */
  bool missing = false;
};

SelectedOthers selected_others(bContext *C, Button &but)
{
  SelectedOthers others;
  PointerRNA ptr = but.rnapoin;
  PropertyRNA *prop = but.rnaprop;
  if (!ptr.data || !prop || !RNA_property_editable(&ptr, prop)) {
    return others;
  }
  const bContextStore *previous = CTX_store_get(C);
  if (but.context) {
    CTX_store_set(C, but.context);
  }
  Vector<PointerRNA> list;
  bool use_path_from_id;
  std::optional<std::string> path;
  const bool found = context_copy_to_selected_list(C, &ptr, prop, &list, &use_path_from_id, &path);
  CTX_store_set(C, previous);
  if (!found) {
    return others;
  }
  const char *path_c = path ? path->c_str() : nullptr;
  std::set<void *> seen = {ptr.data};
  for (PointerRNA &link : list) {
    if (link.data == ptr.data) {
      continue;
    }
    PointerRNA lptr;
    PropertyRNA *lprop = nullptr;
    if (context_copy_to_selected_check(&ptr, &link, prop, path_c, use_path_from_id, &lptr, &lprop))
    {
      if (seen.insert(lptr.data).second) {
        others.items.append({lptr, lprop});
      }
      continue;
    }
    /* Items sharing the data shown (e.g. two objects with one mesh) have it, the rest don't. */
    PointerRNA resolved = PointerRNA_NULL;
    PropertyRNA *resolved_prop = nullptr;
    if (use_path_from_id) {
      PointerRNA id_ptr = RNA_id_pointer_create(link.owner_id);
      RNA_path_resolve_property(&id_ptr, path_c, &resolved, &resolved_prop);
    }
    else if (path_c) {
      RNA_path_resolve_property(&link, path_c, &resolved, &resolved_prop);
    }
    else {
      resolved = link;
    }
    if (resolved.data != ptr.data) {
      others.missing = true;
    }
  }
  /* Blender leaves out objects with another type of data (a light's next to a mesh's). */
  if (ptr.owner_id && GS(ptr.owner_id->name) != ID_OB && OB_DATA_SUPPORT_ID(GS(ptr.owner_id->name)))
  {
    for (const PointerRNA &object_ptr : CTX_data_collection_get(C, "selected_editable_objects")) {
      const ID *data = static_cast<const Object *>(object_ptr.data)->data;
      if (!data || GS(data->name) != GS(ptr.owner_id->name)) {
        others.missing = true;
      }
    }
  }
  return others;
}

/** Whether another item's value differs from the button's, at \a index or as a whole. */
bool other_value_differs(PointerRNA *ptr, PropertyRNA *prop, int index, PointerRNA *lptr,
                         PropertyRNA *lprop)
{
  const bool array = RNA_property_array_check(prop);
  const int length = RNA_property_array_length(ptr, prop);
  if (array && RNA_property_array_length(lptr, lprop) != length) {
    return true;
  }
  const int begin = !array ? 0 : index >= 0 ? index : 0;
  const int end = !array ? 1 : index >= 0 ? index + 1 : length;
  switch (RNA_property_type(prop)) {
    case PROP_FLOAT:
      for (int i = begin; i < end; i++) {
        const float a = array ? RNA_property_float_get_index(ptr, prop, i) :
                                RNA_property_float_get(ptr, prop);
        const float b = array ? RNA_property_float_get_index(lptr, lprop, i) :
                                RNA_property_float_get(lptr, lprop);
        if (std::abs(a - b) > 1e-6f * std::max(1.0f, std::abs(a))) {
          return true;
        }
      }
      return false;
    case PROP_INT:
      for (int i = begin; i < end; i++) {
        if ((array ? RNA_property_int_get_index(ptr, prop, i) : RNA_property_int_get(ptr, prop)) !=
            (array ? RNA_property_int_get_index(lptr, lprop, i) : RNA_property_int_get(lptr, lprop)))
        {
          return true;
        }
      }
      return false;
    case PROP_BOOLEAN:
      for (int i = begin; i < end; i++) {
        if ((array ? RNA_property_boolean_get_index(ptr, prop, i) :
                     RNA_property_boolean_get(ptr, prop)) !=
            (array ? RNA_property_boolean_get_index(lptr, lprop, i) :
                     RNA_property_boolean_get(lptr, lprop)))
        {
          return true;
        }
      }
      return false;
    case PROP_ENUM:
      return RNA_property_enum_get(ptr, prop) != RNA_property_enum_get(lptr, lprop);
    case PROP_STRING:
      return RNA_property_string_get(ptr, prop) != RNA_property_string_get(lptr, lprop);
    case PROP_POINTER:
      return RNA_property_pointer_get(ptr, prop).data != RNA_property_pointer_get(lptr, lprop).data;
    default:
      return false;
  }
}

bool others_differ(Button &but, int index, const SelectedOthers &others)
{
  for (const auto &[other_ptr, other_prop] : others.items) {
    PointerRNA lptr = other_ptr;
    if (other_value_differs(&but.rnapoin, but.rnaprop, index, &lptr, other_prop)) {
      return true;
    }
  }
  return false;
}

/** The other items' values when a drag started, which it moves by as much as the button's. */
struct SelectedDrag {
  std::string token;
  double original = 0;
  Vector<double> others;
};
SelectedDrag selected_drag;

double numeric_get(PointerRNA *ptr, PropertyRNA *prop, int index)
{
  const bool array = RNA_property_array_check(prop) && index >= 0;
  if (RNA_property_type(prop) == PROP_FLOAT) {
    return array ? RNA_property_float_get_index(ptr, prop, index) : RNA_property_float_get(ptr, prop);
  }
  return array ? RNA_property_int_get_index(ptr, prop, index) : RNA_property_int_get(ptr, prop);
}

void numeric_set(PointerRNA *ptr, PropertyRNA *prop, int index, double value)
{
  const bool array = RNA_property_array_check(prop) && index >= 0;
  if (RNA_property_type(prop) == PROP_FLOAT) {
    float minimum, maximum;
    RNA_property_float_range(ptr, prop, &minimum, &maximum);
    const float clamped = std::clamp(float(value), minimum, maximum);
    if (array) {
      RNA_property_float_set_index(ptr, prop, index, clamped);
    }
    else {
      RNA_property_float_set(ptr, prop, clamped);
    }
    return;
  }
  int minimum, maximum;
  RNA_property_int_range(ptr, prop, &minimum, &maximum);
  const int clamped = int(std::clamp(std::round(value), double(minimum), double(maximum)));
  if (array) {
    RNA_property_int_set_index(ptr, prop, index, clamped);
  }
  else {
    RNA_property_int_set(ptr, prop, clamped);
  }
}

/** Gives the other items the button's new value, or moves them by as much during a drag. */
void apply_to_others(bContext *C, Button &but, int index, const SelectedOthers &others,
                     const std::string &token)
{
  PointerRNA *ptr = &but.rnapoin;
  PropertyRNA *prop = but.rnaprop;
  const PropertyType type = RNA_property_type(prop);
  const bool array = RNA_property_array_check(prop);
  const bool by_delta = !token.empty() && token == selected_drag.token &&
                        selected_drag.others.size() == others.items.size();
  for (const int i : others.items.index_range()) {
    PointerRNA lptr = others.items[i].first;
    PropertyRNA *lprop = others.items[i].second;
    if (!RNA_property_editable(&lptr, lprop)) {
      continue;
    }
    switch (type) {
      case PROP_FLOAT:
      case PROP_INT:
        if (array && index < 0) {
          /* A whole color. */
          const int length = RNA_property_array_length(ptr, prop);
          if (type == PROP_FLOAT && RNA_property_array_length(&lptr, lprop) == length) {
            Array<float> values(length);
            RNA_property_float_get_array(ptr, prop, values.data());
            RNA_property_float_set_array(&lptr, lprop, values.data());
          }
        }
        else if (by_delta) {
          numeric_set(&lptr, lprop, index,
                      selected_drag.others[i] + numeric_get(ptr, prop, index) - selected_drag.original);
        }
        else {
          numeric_set(&lptr, lprop, index, numeric_get(ptr, prop, index));
        }
        break;
      case PROP_BOOLEAN:
        if (array) {
          RNA_property_boolean_set_index(&lptr, lprop, index,
                                         RNA_property_boolean_get_index(ptr, prop, index));
        }
        else {
          RNA_property_boolean_set(&lptr, lprop, RNA_property_boolean_get(ptr, prop));
        }
        break;
      case PROP_ENUM:
        RNA_property_enum_set(&lptr, lprop, RNA_property_enum_get(ptr, prop));
        break;
      case PROP_STRING:
        RNA_property_string_set(&lptr, lprop, RNA_property_string_get(ptr, prop).c_str());
        break;
      case PROP_POINTER: {
        PointerRNA target = RNA_property_pointer_get(ptr, prop);
        if (RNA_property_pointer_poll(&lptr, lprop, &target)) {
          RNA_property_pointer_set(&lptr, lprop, target, nullptr);
        }
        break;
      }
      default:
        break;
    }
    RNA_property_update(C, &lptr, lprop);
  }
}

/** \} */

struct NativePropertyInteraction {
  std::string token;
  std::string undo_name;
  std::string closed_token;
};
NativePropertyInteraction native_property_interaction;

void finish_property_interaction(bContext *C)
{
  auto &interaction = native_property_interaction;
  if (interaction.token.empty()) {
    return;
  }
  if (!interaction.undo_name.empty()) {
    ED_undo_push(C, interaction.undo_name.c_str());
  }
  interaction.closed_token = std::move(interaction.token);
  interaction.token.clear();
  interaction.undo_name.clear();
}

/** A command's value as a number: a number's, or a switch's as 0 or 1. */
std::optional<double> command_number(const protocol::Command *command)
{
  if (command == nullptr) {
    return std::nullopt;
  }
  if (const protocol::FloatValue *value = command->value_as_FloatValue()) {
    return value->value();
  }
  if (const protocol::IntValue *value = command->value_as_IntValue()) {
    return double(value->value());
  }
  if (const protocol::BoolValue *value = command->value_as_BoolValue()) {
    return value->value() ? 1.0 : 0.0;
  }
  return std::nullopt;
}

std::optional<std::string> command_text(const protocol::Command *command)
{
  const protocol::TextValue *value = command ? command->value_as_TextValue() : nullptr;
  if (value == nullptr) {
    return std::nullopt;
  }
  return value->value() ? value->value()->str() : std::string();
}

/** Set the property \a but edits to the value \a request gives, as an edit in the button does. */
/** A color ramp's key: of the property its button draws. */
std::string ramp_key(const Button &but)
{
  return "ramp:" + property_key(but, -1);
}

/** Moves, chooses, adds or removes a stop of the color ramp \a but draws, as \a request asks,
 * with the button's own update. A drag is one step to undo, at its end. */
bool apply_ramp(bContext *C, Button &but, const native::EditRequest &request)
{
  ColorBand *coba = reinterpret_cast<ColorBand *>(but.poin);
  if (!coba || (but.flag & BUT_DISABLED) ||
      (but.rnapoin.owner_id && !ID_IS_EDITABLE(but.rnapoin.owner_id)))
  {
    return false;
  }
  const std::optional<double> number = command_number(request.command);
  const char *undo = nullptr;
  if (request.action == "activate") {
    if (!number || *number < 0 || *number >= coba->tot) {
      return false;
    }
    coba->cur = short(*number);
  }
  else if (request.action == "add") {
    if (!number || !std::isfinite(*number) ||
        !BKE_colorband_element_add(coba, std::clamp(float(*number), 0.0f, 1.0f)))
    {
      return false;
    }
    undo = "Add Color Ramp Stop";
  }
  else if (request.action == "remove") {
    if (!BKE_colorband_element_remove(coba, coba->cur)) {
      return false;
    }
    undo = "Delete Color Ramp Stop";
  }
  else {
    if (!number || !std::isfinite(*number) || coba->cur < 0 || coba->cur >= coba->tot) {
      return false;
    }
    coba->data[coba->cur].pos = std::clamp(float(*number), 0.0f, 1.0f);
    BKE_colorband_update_sort(coba);
    /* A drag taken back leaves nothing to undo. */
    if (ELEM(request.phase, "", "end")) {
      undo = "Move Color Ramp Stop";
    }
  }
  button_apply_native(C, &but, false);
  if (undo) {
    ED_undo_push(C, undo);
  }
  return true;
}

bool set_property(bContext *C,
                  Button &but,
                  int index,
                  const native::EditRequest &request,
                  const bool push_undo = true,
                  const bool with_selected = true)
{
  PointerRNA *ptr = &but.rnapoin;
  PropertyRNA *prop = but.rnaprop;
  /* Inactive buttons stay editable, as in Blender; they only show that the value has no effect
   * right now. */
  if (!RNA_property_editable(ptr, prop) || (but.flag & BUT_DISABLED)) {
    return false;
  }
  const bool array = RNA_property_array_check(prop);
  /* A row made active gives its list's active index its place. */
  const std::optional<double> number = request.action == "activate" ?
                                           std::optional<double>(request.index) :
                                           command_number(request.command);
  const double numeric = number.value_or(0);
  const std::optional<std::string> text = command_text(request.command);
  const std::string &phase = request.phase;
  const std::string &token = request.interaction;
  const bool slider = request.edit && request.edit->slider;
  /* Adjust Last Operation edits the operator alone. */
  const SelectedOthers others = push_undo && with_selected ? selected_others(C, but) :
                                                              SelectedOthers();
  if (!others.items.is_empty() && !token.empty() && token != selected_drag.token &&
      ELEM(RNA_property_type(prop), PROP_FLOAT, PROP_INT) && !(array && index < 0))
  {
    selected_drag.token = token;
    selected_drag.original = numeric_get(ptr, prop, index);
    selected_drag.others.clear();
    for (auto &[other_ptr, other_prop] : others.items) {
      PointerRNA lptr = other_ptr;
      selected_drag.others.append(numeric_get(&lptr, other_prop, index));
    }
  }
  switch (RNA_property_type(prop)) {
    case PROP_FLOAT: {
      if (is_color(ptr, prop) && index == -1) {
        const protocol::FloatsValue *components = request.command ?
                                                      request.command->value_as_FloatsValue() :
                                                      nullptr;
        const int length = RNA_property_array_length(ptr, prop);
        if (!components || !components->value() || components->value()->size() != length) {
          return false;
        }
        float color[4] = {0, 0, 0, 1};
        for (int i = 0; i < length; i++) {
          const double value = components->value()->Get(i);
          if (!std::isfinite(value) || std::abs(value) > FLT_MAX) {
            return false;
          }
          color[i] = float(value);
        }
        if (RNA_property_subtype(prop) == PROP_COLOR) {
          IMB_colormanagement_srgb_to_scene_linear_v3(color, color);
        }
        float minimum, maximum;
        RNA_property_float_range(ptr, prop, &minimum, &maximum);
        for (int i = 0; i < length; i++) {
          if (!std::isfinite(color[i])) {
            return false;
          }
          color[i] = std::clamp(color[i], minimum, maximum);
        }
        if (length == 4) {
          color[3] = std::clamp(color[3], 0.0f, 1.0f);
        }
        float original[4];
        RNA_property_float_get_array(ptr, prop, original);
        bool changed = false;
        for (int i = 0; i < length; i++) {
          changed |= std::abs(original[i] - color[i]) >
                     1e-6f * std::max(1.0f, std::abs(original[i]));
        }
        if (!changed && others.items.is_empty()) {
          return true;
        }
        RNA_property_float_set_array(ptr, prop, color);
        break;
      }
      if (!number || !std::isfinite(numeric)) {
        return false;
      }
      float minimum, maximum;
      RNA_property_float_range(ptr, prop, &minimum, &maximum);
      const float value = std::clamp(float(numeric), minimum, maximum);
      if (slider && others.items.is_empty() && value == (array ? RNA_property_float_get_index(ptr, prop, index) : RNA_property_float_get(ptr, prop))) {
        return true;
      }
      if (array) {
        RNA_property_float_set_index(ptr, prop, index, value);
      }
      else {
        RNA_property_float_set(ptr, prop, value);
      }
      break;
    }
    case PROP_INT: {
      if (!number || !std::isfinite(numeric)) {
        return false;
      }
      int minimum, maximum;
      RNA_property_int_range(ptr, prop, &minimum, &maximum);
      const int value = int(std::clamp(numeric, double(minimum), double(maximum)));
      if (slider && others.items.is_empty() && value == (array ? RNA_property_int_get_index(ptr, prop, index) : RNA_property_int_get(ptr, prop))) {
        return true;
      }
      if (array) {
        RNA_property_int_set_index(ptr, prop, index, value);
      }
      else {
        RNA_property_int_set(ptr, prop, value);
      }
      break;
    }
    case PROP_BOOLEAN: {
      const protocol::BoolValue *value = request.command ? request.command->value_as_BoolValue() :
                                                           nullptr;
      if (!value) {
        return false;
      }
      if (array) {
        RNA_property_boolean_set_index(ptr, prop, index, value->value());
      }
      else {
        RNA_property_boolean_set(ptr, prop, value->value());
      }
      break;
    }
    case PROP_STRING: {
      if (!text) {
        return false;
      }
      RNA_property_string_set(ptr, prop, text->c_str());
      break;
    }
    case PROP_ENUM: {
      const std::optional<std::string> &value = text;
      const EnumPropertyItem *items;
      int count;
      bool free;
      RNA_property_enum_items(C, ptr, prop, &items, &count, &free);
      int enum_value;
      const bool valid = value && RNA_enum_value_from_identifier(items, value->c_str(), &enum_value);
      if (free) {
        MEM_delete(items);
      }
      if (!valid) {
        return false;
      }
      if (RNA_property_flag(prop) & PROP_ENUM_FLAG) {
        enum_value ^= RNA_property_enum_get(ptr, prop);
      }
      RNA_property_enum_set(ptr, prop, enum_value);
      break;
    }
    case PROP_POINTER: {
      const std::optional<std::string> &value = text;
      if (!value || !RNA_struct_is_ID(RNA_property_pointer_type(ptr, prop))) {
        return false;
      }
      PointerRNA target = PointerRNA_NULL;
      if (!value->empty()) {
        ID *id;
        FOREACH_MAIN_ID_BEGIN (CTX_data_main(C), id) {
          if (std::to_string(id->session_uid) == *value) {
            target = RNA_id_pointer_create(id);
            break;
          }
        }
        FOREACH_MAIN_ID_END;
        if (!target.data || !RNA_struct_is_a(target.type, RNA_property_pointer_type(ptr, prop))) {
          return false;
        }
      }
      if (!RNA_property_pointer_poll(ptr, prop, &target)) {
        return false;
      }
      RNA_property_pointer_set(ptr, prop, target, nullptr);
      break;
    }
    default:
      return false;
  }
  /* The rest is Blender's own button handling, as for an edit in the button: its callbacks, the
   * RNA update, undo and auto keying. While a drag goes on, undo waits for it to end, see
   * #finish_property_interaction. */
  const bool dragging = !token.empty() && phase == "update";
  /* Before Blender's handling, so its undo step holds every item's change. */
  apply_to_others(C, but, index, others, token);
  if (push_undo) {
    const int but_index = but.rnaindex;
    if (array && index >= 0) {
      but.rnaindex = index;
    }
    button_apply_native(C, &but, !dragging && phase != "cancel");
    but.rnaindex = but_index;
    if (dragging) {
      const bool undo = ptr->owner_id && RNA_struct_undo_check(ptr->type);
      native_property_interaction.token = token;
      native_property_interaction.undo_name = undo ? RNA_property_ui_name(prop) : "";
    }
    else if (!token.empty()) {
      native_property_interaction.closed_token = token;
      native_property_interaction.token.clear();
      native_property_interaction.undo_name.clear();
    }
  }
  else {
    /* Adjust Last Operation: its block repeats the operator from a handler, which the caller does
     * itself to report failure; operator properties have no callbacks, keys or undo of their own. */
    RNA_property_update(C, ptr, prop);
  }
  WM_event_add_notifier(C, NC_WINDOW, nullptr);
  return true;
}

struct PropertyAnimationAction {
  std::string id;
  std::string title;
  const char *operator_id;
  const char *icon;
  bool all;
};

/**
 * How a property is animated, as Blender colors its button: keyed on this frame, animated,
 * changed from its animated value, or driven. And whether its keyframes can be inserted and
 * removed, see #property_animation_actions.
 */
std::pair<protocol::Animation, bool> property_animation(bContext *C, Button &but, int index)
{
  if (!RNA_property_path_from_ID_check(&but.rnapoin, but.rnaprop)) {
    return {protocol::Animation::None, false};
  }
  const int old_index = but.rnaindex, old_flag = but.flag, old_drawflag = but.drawflag;
  but.rnaindex = index;
  const AnimationEvalContext eval = BKE_animsys_eval_context_construct(
      CTX_data_depsgraph_pointer(C), BKE_scene_frame_get(CTX_data_scene(C)));
  button_anim_flag(&but, &eval);
  const protocol::Animation state = (but.flag & BUT_DRIVEN) ? protocol::Animation::Driven :
                                    (but.drawflag & BUT_ANIMATED_CHANGED) ?
                                                              protocol::Animation::Changed :
                                    (but.flag & BUT_ANIMATED_KEY) ? protocol::Animation::Keyed :
                                    (but.flag & BUT_ANIMATED)     ? protocol::Animation::Animated :
                                                                    protocol::Animation::None;
  but.rnaindex = old_index;
  but.flag = old_flag;
  but.drawflag = old_drawflag;
  return {state,
          state != protocol::Animation::Driven &&
              RNA_property_anim_editable(&but.rnapoin, but.rnaprop) &&
              !(but.flag & (BUT_DISABLED | BUT_INACTIVE))};
}

std::vector<PropertyAnimationAction> property_animation_actions(bContext *C, Button &but, int index)
{
  if (!RNA_property_anim_editable(&but.rnapoin, but.rnaprop) ||
      !RNA_property_path_from_ID_check(&but.rnapoin, but.rnaprop) ||
      (but.flag & (BUT_DISABLED | BUT_INACTIVE))) {
    return {};
  }
  const int old_index = but.rnaindex, old_flag = but.flag, old_drawflag = but.drawflag;
  but.rnaindex = index;
  const AnimationEvalContext eval = BKE_animsys_eval_context_construct(
      CTX_data_depsgraph_pointer(C), BKE_scene_frame_get(CTX_data_scene(C)));
  button_anim_flag(&but, &eval);
  const bool keyed = but.flag & BUT_ANIMATED_KEY;
  const bool animated = but.flag & BUT_ANIMATED;
  const bool driven = but.flag & BUT_DRIVEN;
  but.rnaindex = old_index;
  but.flag = old_flag;
  but.drawflag = old_drawflag;
  if (driven) {
    return {};
  }
  const bool component = RNA_property_array_check(but.rnaprop) && index >= 0;
  std::vector<PropertyAnimationAction> actions;
  auto add = [&](const char *id, const char *verb, const char *operator_id, const char *icon) {
    actions.push_back({std::string(id) + "_all",
                       std::string(verb) + (component || std::string(id) == "clear" ? " Keyframes" : " Keyframe"),
                       operator_id, icon, true});
    if (component) {
      actions.push_back({std::string(id) + "_single",
                         std::string(verb) + (std::string(id) == "clear" ? " Single Keyframes" : " Single Keyframe"),
                         operator_id, icon, false});
    }
  };
  add("insert", keyed ? "Replace" : "Insert", "ANIM_OT_keyframe_insert_button", "KEY_HLT");
  if (keyed) {
    add("delete", "Delete", "ANIM_OT_keyframe_delete_button", "KEY_DEHLT");
  }
  if (animated && but.rnapoin.type != RNA_NlaStrip) {
    add("clear", "Clear", "ANIM_OT_keyframe_clear_button", "KEY_DEHLT");
  }
  return actions;
}

bool animate_property(bContext *C, Button &but, int index, const std::string &action_id)
{
  for (const PropertyAnimationAction &action : property_animation_actions(C, but, index)) {
    if (action.id != action_id) {
      continue;
    }
    /* Reuse Blender's button operators, with this detached control as their active property. */
    ARegion *region = CTX_wm_region(C);
    ARegion *popup = CTX_wm_region_popup(C);
    const bContextStore *store = CTX_store_get(C);
    const int old_index = but.rnaindex, old_flag = but.flag;
    but.rnaindex = index;
    but.flag |= BUT_ACTIVE_OVERRIDE;
    BLI_addtail(&region->runtime->uiblocks, but.block);
    CTX_wm_region_popup_set(C, nullptr);
    if (but.context) {
      CTX_store_set(C, but.context);
    }
    PointerRNA properties = WM_operator_properties_create(action.operator_id);
    RNA_boolean_set(&properties, "all", action.all);
    const bool changed = WM_operator_name_call(C, action.operator_id, wm::OpCallContext::ExecDefault,
                                               &properties, nullptr) & OPERATOR_FINISHED;
    WM_operator_properties_free(&properties);
    CTX_store_set(C, store);
    CTX_wm_region_popup_set(C, popup);
    BLI_remlink(&region->runtime->uiblocks, but.block);
    but.rnaindex = old_index;
    but.flag = old_flag;
    return changed;
  }
  return false;
}

struct PropertyPair {
  std::string key;
  std::string title;
  std::string component;
};

std::map<Button *, PropertyPair> property_pairs(const Block &block)
{
  std::map<Button *, PropertyPair> pairs;
  Button *previous = nullptr;
  for (const auto &button : block.buttons) {
    Button &but = *button;
    if (!but.rnaprop || !but.rnapoin.data || (but.flag & UI_HIDDEN) ||
        button_is_decorator(&but)) {
      continue;
    }
    const bool scalar = ELEM(RNA_property_type(but.rnaprop), PROP_INT, PROP_FLOAT) &&
                        !RNA_property_array_check(but.rnaprop);
    if (scalar && previous && previous->rnapoin.data == but.rnapoin.data &&
        previous->rnapoin.type == but.rnapoin.type &&
        RNA_property_type(previous->rnaprop) == RNA_property_type(but.rnaprop)) {
      const std::string first = RNA_property_identifier(previous->rnaprop);
      const std::string second = RNA_property_identifier(but.rnaprop);
      for (const auto &suffix : {std::pair{"_x", "_y"}, {"_u", "_v"},
                                 {"_min", "_max"}, {"_start", "_end"}}) {
        if (!StringRef(first).endswith(suffix.first)) {
          continue;
        }
        const std::string stem = first.substr(0, first.size() - strlen(suffix.first));
        if (second != stem + suffix.second) {
          continue;
        }
        /* Separate scalar properties only form a pair when Blender groups them in an
         * aligned layout. Capture this before block_end() frees the layout tree. */
        bool aligned = false;
        for (Layout *a = previous->layout; a && !aligned; a = a->parent()) {
          if (!a->align()) {
            continue;
          }
          for (Layout *b = but.layout; b; b = b->parent()) {
            if (a == b) {
              aligned = true;
              break;
            }
          }
        }
        const std::string first_name = RNA_property_ui_name(previous->rnaprop);
        const std::string second_name = RNA_property_ui_name(but.rnaprop);
        size_t common = 0;
        while (common < first_name.size() && common < second_name.size() &&
               first_name[common] == second_name[common]) {
          common++;
        }
        /* Split at a word boundary, not midway through a translated label. */
        while (common && first_name[common - 1] != ' ') {
          common--;
        }
        if (aligned && common > 1 && common < first_name.size() && common < second_name.size()) {
          const std::string key = property_key(*previous, -1);
          const std::string title = first_name.substr(0, common - 1);
          pairs[previous] = {key, title, first_name.substr(common)};
          pairs[&but] = {key, title, second_name.substr(common)};
        }
        break;
      }
    }
    previous = scalar && !pairs.count(&but) ? &but : nullptr;
  }
  return pairs;
}

/* -------------------------------------------------------------------- */
/** \name Data-Block Pickers, Lists and Previews
 *
 * Blender draws these as groups of small buttons. Native interfaces show each as one control:
 * an ID template becomes a picker with its actions, a UI list a list of rows, and a material's
 * Preview panel its rendered preview.
 * \{ */

/** ID types shown with rendered previews, as Blender's own pickers do. */
bool id_type_has_previews(const short idcode)
{
  return ELEM(idcode, ID_MA, ID_WO, ID_TE, ID_LA, ID_IM);
}

/** PNG of \a id's preview icon, rendered with a job when needed; empty until rendered. */
std::string id_preview_path(bContext *C, ID *id)
{
  if (!id || !id_type_has_previews(GS(id->name))) {
    return "";
  }
  return id_preview_icon_path(C, id_icon_get(C, id, true));
}

/**
 * PNG of a large render of \a id, as the Preview panel shows it. It renders again, with a job,
 * whenever the ID's own preview icon updates after an edit.
 */
std::string id_large_preview_path(bContext *C, ID *id)
{
  struct LargePreview {
    PreviewImage *image = nullptr;
    int source_stamp = -1;
    int written_stamp = -1;
    std::string path;
  };
  /* Kept for the session: a render job may still write into a preview. */
  static std::map<uint, LargePreview> previews;
  constexpr int size = 512;
  if (!id || !ED_preview_id_is_supported(id)) {
    return "";
  }
  LargePreview &preview = previews[id->session_uid];
  if (!preview.image) {
    preview.image = BKE_previewimg_create();
    preview.image->w[ICON_SIZE_PREVIEW] = preview.image->h[ICON_SIZE_PREVIEW] = size;
    preview.image->rect[ICON_SIZE_PREVIEW] = MEM_new_array_zeroed<uint>(size * size, __func__);
  }
  /* The small preview follows edits to the ID; render the large one again when it changes. */
  const PreviewImage *source = icon_id_preview(C, id_icon_get(C, id, true));
  const int source_stamp = source ? source->changed_timestamp[ICON_SIZE_PREVIEW] : 0;
  PreviewImage *image = preview.image;
  if (preview.source_stamp != source_stamp && !BKE_previewimg_is_rendering(image, ICON_SIZE_PREVIEW))
  {
    preview.source_stamp = source_stamp;
    ED_preview_icon_job(C, image, id, ICON_SIZE_PREVIEW, false);
    return preview.path;
  }
  if (BKE_previewimg_is_rendering(image, ICON_SIZE_PREVIEW) ||
      preview.written_stamp == preview.source_stamp)
  {
    return preview.path;
  }
  ImBuf *ibuf = IMB_allocFromBuffer(
      reinterpret_cast<const uint8_t *>(image->rect[ICON_SIZE_PREVIEW]), nullptr, size, size, 4);
  if (!ibuf) {
    return preview.path;
  }
  IMB_unpremultiply_alpha(ibuf);
  ibuf->planes = 32;
  ibuf->ftype = IMB_FTYPE_PNG;
  const std::string path = std::string(BKE_tempdir_session()) + "native_large_preview_" +
                           std::to_string(id->session_uid) + "_" +
                           std::to_string(preview.source_stamp) + ".png";
  if (IMB_save_image(ibuf, path.c_str(), IB_byte_data)) {
    preview.path = path;
    preview.written_stamp = preview.source_stamp;
  }
  IMB_freeImBuf(ibuf);
  return preview.path;
}

std::string id_template_key(const PointerRNA &ptr, PropertyRNA *prop)
{
  const auto path = RNA_path_from_ID_to_struct(&ptr);
  return "id:" + std::to_string(ptr.owner_id ? ptr.owner_id->session_uid : 0) + ":" +
         (path ? *path : RNA_struct_identifier(ptr.type)) + ":" + RNA_property_identifier(prop);
}

/** The button of the ID template browsing \a prop of \a ptr with the role \a event. */
Button *id_template_part(const Block &block, const PointerRNA &ptr, PropertyRNA *prop, int event)
{
  for (const auto &button : block.buttons) {
    PointerRNA part_ptr;
    PropertyRNA *part_prop;
    int part_event;
    if (template_id_property_get(*button, part_ptr, part_prop, part_event) &&
        part_event == event && part_prop == prop && part_ptr.data == ptr.data)
    {
      return button.get();
    }
  }
  return nullptr;
}

/** Data-block creation runs the template's operator; the new ID is assigned afterwards. */
struct PendingNewID {
  PointerRNA ptr = {};
  PropertyRNA *prop = nullptr;
  std::set<ID *> before;
};

bool apply_id_template(bContext *C,
                       const Block &block,
                       const PointerRNA &ptr_const,
                       PropertyRNA *prop,
                       const native::EditRequest &request,
                       wmOperatorType *&r_operator_type,
                       PointerRNA *&r_operator_properties,
                       std::unique_ptr<bContextStore> &r_operator_context,
                       PendingNewID &r_pending)
{
  PointerRNA ptr = ptr_const;
  if (!RNA_property_editable(&ptr, prop)) {
    return false;
  }
  const std::string &action = request.action;
  const std::string &value = request.text;
  ID *id = RNA_property_pointer_get(&ptr, prop).owner_id;
  const short idcode = RNA_type_to_ID_code(RNA_property_pointer_type(&ptr, prop));
  Main *bmain = CTX_data_main(C);
  const char *undo_name = nullptr;
  if (action == "select") {
    ID *target = nullptr;
    if (ListBaseT<ID> *ids = idcode ? which_libbase(bmain, idcode) : nullptr) {
      for (ID &candidate : *ids) {
        if (std::to_string(candidate.session_uid) == value) {
          target = &candidate;
          break;
        }
      }
    }
    PointerRNA target_ptr = target ? RNA_id_pointer_create(target) : PointerRNA_NULL;
    if (!target || !RNA_property_pointer_poll(&ptr, prop, &target_ptr)) {
      return false;
    }
    if (target != id) {
      RNA_property_pointer_set(&ptr, prop, target_ptr, nullptr);
      RNA_property_update(C, &ptr, prop);
      undo_name = RNA_property_ui_name(prop);
    }
  }
  else if (action == "unlink") {
    if (!id || (RNA_property_flag(prop) & PROP_NEVER_NULL)) {
      return false;
    }
    RNA_property_pointer_set(&ptr, prop, PointerRNA_NULL, nullptr);
    RNA_property_update(C, &ptr, prop);
    undo_name = "Unlink Data-Block";
  }
  else if (action == "new") {
    /* New, or a copy when there is an ID, as the template's own button does. */
    Button *button = id_template_part(block, ptr, prop, UI_ID_ADD_NEW);
    if (!button || !button->optype || !button->optype->exec || r_operator_type) {
      return false;
    }
    r_operator_type = button->optype;
    r_operator_properties = button->opptr;
    button->opptr = nullptr;
    if (button->context) {
      r_operator_context = std::make_unique<bContextStore>(*button->context);
    }
    r_pending.ptr = ptr;
    r_pending.prop = prop;
    if (ListBaseT<ID> *ids = idcode ? which_libbase(bmain, idcode) : nullptr) {
      for (ID &existing : *ids) {
        r_pending.before.insert(&existing);
      }
    }
    return true;
  }
  else if (action == "load_font" && idcode == ID_VF && !value.empty()) {
    /* A font file the system's font picker made. Packed, as the file is only a cache. */
    auto load = [&](const std::string &path) -> VFont * {
      VFont *font = BKE_vfont_load_exists(bmain, path.c_str());
      if (font == nullptr) {
        return nullptr;
      }
      /* Loading counts a user, as does assigning it. */
      id_us_min(&font->id);
      if (!font->packedfile) {
        font->packedfile = BKE_packedfile_new(
            nullptr, font->filepath, BKE_main_blendfile_path(bmain));
      }
      return font;
    };
    auto assign = [&](PropertyRNA *target, VFont *font) {
      PointerRNA font_ptr = RNA_id_pointer_create(&font->id);
      RNA_property_pointer_set(&ptr, target, font_ptr, nullptr);
      RNA_property_update(C, &ptr, target);
    };
    VFont *font = load(value);
    if (font == nullptr) {
      return false;
    }
    assign(prop, font);
    /* The family's bold and italic faces along with its regular one, as a text app sets them. */
    for (const auto &[slot, path] : request.family) {
      PropertyRNA *style = RNA_struct_find_property(&ptr, slot.c_str());
      if (style && RNA_property_type(style) == PROP_POINTER &&
          RNA_property_pointer_type(&ptr, style) == RNA_VectorFont)
      {
        if (VFont *style_font = load(path)) {
          assign(style, style_font);
        }
      }
    }
    undo_name = "Choose Font";
  }
  else if (action == "fake_user" && id && !ID_IS_LINKED(id)) {
    PointerRNA id_ptr = RNA_id_pointer_create(id);
    RNA_boolean_set(&id_ptr, "use_fake_user", !(id->flag & ID_FLAG_FAKEUSER));
    undo_name = "Fake User";
  }
  else if (action == "rename" && id && ID_IS_EDITABLE(id) && !value.empty()) {
    PointerRNA id_ptr = RNA_id_pointer_create(id);
    PropertyRNA *name_prop = RNA_struct_find_property(&id_ptr, "name");
    RNA_property_string_set(&id_ptr, name_prop, value.c_str());
    RNA_property_update(C, &id_ptr, name_prop);
    undo_name = "Rename Data-Block";
  }
  else if (action == "single_user" && id && id->us > 1) {
    if (!id_single_user(C, id, &ptr, prop)) {
      return false;
    }
    DEG_relations_tag_update(bmain);
    undo_name = "Make Single User";
  }
  else {
    return false;
  }
  if (undo_name) {
    ED_undo_push(C, undo_name);
    WM_event_add_notifier(C, NC_SPACE | ND_SPACE_OUTLINER, nullptr);
  }
  return true;
}

/** Assign the data-block a template's New operator made, which it assigns only when clicked. */
void finish_pending_new_id(bContext *C, PendingNewID &pending)
{
  if (!pending.prop) {
    return;
  }
  const short idcode = RNA_type_to_ID_code(RNA_property_pointer_type(&pending.ptr, pending.prop));
  ID *created = nullptr;
  if (ListBaseT<ID> *ids = idcode ? which_libbase(CTX_data_main(C), idcode) : nullptr) {
    for (ID &candidate : *ids) {
      if (!pending.before.count(&candidate)) {
        created = &candidate;
      }
    }
  }
  PointerRNA created_ptr = created ? RNA_id_pointer_create(created) : PointerRNA_NULL;
  if (created && RNA_property_pointer_get(&pending.ptr, pending.prop).owner_id != created &&
      RNA_property_pointer_poll(&pending.ptr, pending.prop, &created_ptr))
  {
    RNA_property_pointer_set(&pending.ptr, pending.prop, created_ptr, nullptr);
    /* The operator made it with a user of its own for the picker to take over, as a template's
     * button does once it is assigned. */
    if (created->us > 1) {
      id_us_min(created);
    }
    RNA_property_update(C, &pending.ptr, pending.prop);
    ED_undo_push(C, RNA_property_ui_name(pending.prop));
  }
  pending = {};
}

/** The icon of the physics an enabled physics button removes. */
int physics_icon(bContext *C, const Button &but)
{
  const char *idname = but.optype ? but.optype->idname : "";
  if (STREQ(idname, "OBJECT_OT_forcefield_toggle")) {
    return ICON_FORCE_FORCE;
  }
  if (STREQ(idname, "RIGIDBODY_OT_object_remove")) {
    return ICON_RIGID_BODY;
  }
  if (STREQ(idname, "RIGIDBODY_OT_constraint_remove")) {
    return ICON_RIGID_BODY_CONSTRAINT;
  }
  Object *object = CTX_data_active_object(C);
  if (STREQ(idname, "OBJECT_OT_modifier_remove") && but.opptr && object) {
    const std::string name = RNA_string_get(but.opptr, "modifier");
    if (const ModifierData *md = BKE_modifiers_findby_name(object, name.c_str())) {
      return BKE_modifier_get_info(ModifierType(md->type))->icon;
    }
  }
  return ICON_NONE;
}

std::string operator_key(bContext *C, const Button &but, const Object *object)
{
  return std::string(but.optype->idname) + ":" +
         (but.opptr ? RNA_pointer_as_string_keywords(C, but.opptr, false, false, true, INT_MAX) :
                      "") +
         ":" + std::to_string(object ? object->id.session_uid : 0);
}

/** The buttons beside a list: add, remove, reorder and its specials menu. */
struct ListSide {
  Button *add = nullptr;
  Button *remove = nullptr;
  Button *up = nullptr;
  Button *down = nullptr;
  MenuType *menu = nullptr;
  std::vector<Button *> extras;
};

/** The Properties panel showing the settings of the physics a physics button adds or removes. */
const char *physics_panel(bContext *C, const Button &but)
{
  const char *idname = but.optype ? but.optype->idname : "";
  if (STREQ(idname, "OBJECT_OT_forcefield_toggle")) {
    return "PHYSICS_PT_field";
  }
  if (STRPREFIX(idname, "RIGIDBODY_OT_object_")) {
    return "PHYSICS_PT_rigid_body";
  }
  if (STRPREFIX(idname, "RIGIDBODY_OT_constraint_")) {
    return "PHYSICS_PT_rigid_body_constraint";
  }
  int type = -1;
  if (STREQ(idname, "OBJECT_OT_modifier_add") && but.opptr) {
    type = RNA_enum_get(but.opptr, "type");
  }
  else if (STREQ(idname, "OBJECT_OT_modifier_remove") && but.opptr) {
    Object *object = CTX_data_active_object(C);
    const std::string name = RNA_string_get(but.opptr, "modifier");
    if (const ModifierData *md = object ? BKE_modifiers_findby_name(object, name.c_str()) : nullptr)
    {
      type = md->type;
    }
  }
  switch (type) {
    case eModifierType_Collision:
      return "PHYSICS_PT_collision";
    case eModifierType_Cloth:
      return "PHYSICS_PT_cloth";
    case eModifierType_DynamicPaint:
      return "PHYSICS_PT_dynamic_paint";
    case eModifierType_Softbody:
      return "PHYSICS_PT_softbody";
    case eModifierType_Fluid:
      return "PHYSICS_PT_fluid";
    default:
      return nullptr;
  }
}

/** The operator duplicating the active item of a list that \a add adds to, for the iPad's swipe
 * action. Lists offer it differently (in their menu, or as Add), so it is known by their Add. */
const char *duplicate_operator(const StringRef add)
{
  static const std::pair<const char *, const char *> duplicates[] = {
      {"OBJECT_OT_shape_key_add", "OBJECT_OT_shape_key_copy"},
      {"OBJECT_OT_vertex_group_add", "OBJECT_OT_vertex_group_copy"},
      {"GEOMETRY_OT_color_attribute_add", "GEOMETRY_OT_color_attribute_duplicate"},
      {"GREASE_PENCIL_OT_layer_add", "GREASE_PENCIL_OT_layer_duplicate"},
      {"MESH_OT_uv_texture_add", "MESH_OT_uv_texture_add"},
  };
  for (const auto &[from, duplicate] : duplicates) {
    if (add == from) {
      return duplicate;
    }
  }
  return nullptr;
}

/** A tree view's items in drawing order (shape keys, bone collections, layers), with the buttons
 * beside it. Trees have no active-index property: their items are activated and renamed
 * directly, see #apply_tree. */
struct TreeRows {
  std::vector<const ButtonViewItem *> items;
  rctf rect;
  ListSide side;
};

const AbstractTreeViewItem *tree_item(const ButtonViewItem &button)
{
  const auto *item = dynamic_cast<const AbstractTreeViewItem *>(button.view_item);
  /* Blender pads a short tree with blank rows that do nothing, which a native list doesn't: plain
   * items without interaction. Others without it, such as a reference shape key, are items. */
  if (item && !item->is_interactive() && dynamic_cast<const BasicTreeViewItem *>(item)) {
    return nullptr;
  }
  return item;
}

/** Select, rename or reorder a tree's item, in the order its items are listed. */
bool apply_tree(bContext *C, const TreeRows &tree, const native::EditRequest &request)
{
  const std::string &action = request.action;
  auto item_at = [&](const int64_t index) -> AbstractViewItem * {
    return index >= 0 && index < int64_t(tree.items.size()) ? tree.items[index]->view_item :
                                                                nullptr;
  };
  if (action == "rename") {
    AbstractViewItem *item = item_at(request.index);
    return item && item->supports_renaming() && item->rename(*C, request.text);
  }
  if (action == "move") {
    /* Make the item active, then move it as the arrows beside the tree do. */
    const int64_t from = request.index;
    const int64_t to = request.to;
    AbstractViewItem *item = item_at(from);
    Button *step = to < from ? tree.side.up : tree.side.down;
    if (!item || !item_at(to) || from == to || !step || !step->optype) {
      return false;
    }
    item->activate(*C);
    const bContextStore *previous = CTX_store_get(C);
    CTX_store_set(C, step->context);
    bool applied = true;
    for (int64_t i = 0; i < std::abs(to - from) && applied; i++) {
      applied = WM_operator_name_call_ptr(C, step->optype, wm::OpCallContext::ExecDefault,
                                          step->opptr, nullptr) & OPERATOR_FINISHED;
    }
    CTX_store_set(C, previous);
    return applied;
  }
  AbstractViewItem *item = item_at(request.index);
  if (!item) {
    return false;
  }
  item->activate(*C);
  return true;
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Writing Controls
 *
 * Buttons as the nodes of a view, see `WM_native_ui_views.hh`, each with what it edits, see
 * #native::Edit. Blender draws a data-block picker, a list or a preview as a group of small
 * buttons; a native interface shows each as one control.
 * \{ */

using Buffer = flatbuffers::FlatBufferBuilder;
using native::Edit;

/** How a property is shown, besides as its button says. */
struct Look {
  /** Its name, in place of the property's own. */
  std::string_view name;
  /** For where space is tight, as the X of a mirror's axes. */
  std::string_view short_label;
  protocol::Role role = protocol::Role::None;
  /** Its options side by side, as Blender draws an enum expanded. */
  bool expand = false;
  /** The other selected items with it, or none for it to edit alone. */
  const SelectedOthers *others = nullptr;
  /** It shares a row with another property, such as a minimum with its maximum. */
  const PropertyPair *pair = nullptr;
  /** Its toggles drawn together, such as a mirror's axes, and what they are captioned. */
  std::string toggles;
  std::string_view toggles_caption;
  /** The mode of the row it is in, such as a rotation's. */
  Button *mode = nullptr;
  /** What locks it, and its component. */
  Button *lock = nullptr;
  int lock_index = -1;
};

/** A row of a list, as #Writer::list writes it. */
struct ListRow {
  int64_t index = 0;
  int depth = 0;
  bool renamable = false;
  /** The buttons drawn over it, and what it is called when none of them names it. */
  const std::vector<const Button *> *items = nullptr;
  std::string fallback;
};

class Writer {
 public:
  bContext *C;
  ViewBuilder &builder;
  native::PanelsData &data;
  /** The panel being written, by its id, which edits of its controls name. */
  std::string panel;
  const Object *object = nullptr;

  Writer(bContext *C, ViewBuilder &builder, native::PanelsData &data)
      : C(C), builder(builder), data(data)
  {
    data.clear();
  }

  /** A key of its own for \a base: a property drawn twice gets a second one. */
  std::string key(const std::string &base)
  {
    std::string key = base;
    for (int i = 2; !used_.insert(key).second; i++) {
      key = base + "#" + std::to_string(i);
    }
    return key;
  }

  NodeId group(const NodeId parent,
               const std::string &key,
               const std::string_view label,
               const protocol::Layout layout = protocol::Layout::Column)
  {
    return builder.add(parent, this->key(key), [&](Buffer &buffer, NodeFields &fields) {
      fields.label = label;
      return protocol::CreateGroup(buffer, layout);
    });
  }

  NodeId panel_node(const NodeId parent,
                    const std::string &id,
                    const bool outer,
                    const std::string_view title,
                    const bool open,
                    const bool fixed = false,
                    const bool active = false,
                    const int position = -1,
                    const bool openable = true,
                    const std::string_view icon = {})
  {
    const std::string key = this->key("panel:" + id);
    data.panels.add_overwrite(key, {id, outer, open});
    return builder.add(parent, key, [&](Buffer &buffer, NodeFields &fields) {
      fields.label = title;
      fields.icon = icon;
      return protocol::CreatePanel(buffer, open, fixed, active, position, openable);
    });
  }

  /** A section of the panel (`layout.panel`), a sub-panel of it (ROUND6 PANEL-3). */
  NodeId section_node(const NodeId parent,
                      const std::string &id,
                      const bool property,
                      const std::string_view title,
                      const bool open)
  {
    const std::string key = this->key("panel:" + id);
    data.panels.add_overwrite(key, {id, false, open, panel, property});
    return builder.add(parent, key, [&](Buffer &buffer, NodeFields &fields) {
      fields.label = title;
      return protocol::CreatePanel(buffer, open, false, false, -1, true);
    });
  }

  /** The name a property's button shows it by: a node socket's value by its socket. */
  static std::string property_name(const Button &but)
  {
    if (RNA_struct_is_a(but.rnapoin.type, RNA_NodeSocket) &&
        STREQ(RNA_property_identifier(but.rnaprop), "default_value"))
    {
      return ed::space_node::node_socket_get_label(
          static_cast<const bNodeSocket *>(but.rnapoin.data));
    }
    return RNA_property_ui_name(but.rnaprop);
  }

  /** The property \a but edits, at \a index of an array, or all of a color. */
  NodeId property(NodeId parent, Button &but, const int index, const Look &look = {})
  {
    PointerRNA *ptr = &but.rnapoin;
    PropertyRNA *prop = but.rnaprop;
    const PropertyType type = RNA_property_type(prop);
    const bool array = RNA_property_array_check(prop);
    const int length = RNA_property_array_length(ptr, prop);
    const bool color = is_color(ptr, prop);
    const std::string name = look.name.empty() ? property_name(but) : std::string(look.name);
    std::string label = name;
    /* A lock, a mode or a shape is shown with what it belongs to, on its own. */
    const bool attached = ELEM(
        look.role, protocol::Role::Lock, protocol::Role::Mode, protocol::Role::Shape);
    if (array && length <= 4 && !color) {
      label = (ELEM(RNA_property_subtype(prop), PROP_COLOR, PROP_COLOR_GAMMA) ? "RGBA" :
               length == 4                                                   ? "WXYZ" :
                                                                               "XYZW")[index];
    }
    if (!attached && !look.toggles.empty()) {
      /* Toggles drawn together, such as a mirror's X, Y and Z. */
      parent = row(parent, "toggles:" + look.toggles, [&](Buffer &buffer, NodeFields &fields) {
        fields.label = look.toggles_caption.empty() ? std::string_view(label) :
                                                      look.toggles_caption;
        return protocol::CreateGroup(buffer, protocol::Layout::Joined);
      });
    }
    else if (!attached && !color && (look.pair || (array && length <= 4))) {
      /* A vector's components, or a pair such as a minimum and maximum, share a row. */
      const bool rotation = STR_ELEM(RNA_property_identifier(prop),
                                     "rotation_euler",
                                     "rotation_quaternion",
                                     "rotation_axis_angle");
      const std::string title = look.pair ? look.pair->title : rotation ? "Rotation" : name;
      if (look.pair) {
        label = look.pair->component;
      }
      bool added = false;
      parent = row(parent,
                   "group:" + (look.pair ? look.pair->key : property_key(but, -1)),
                   [&](Buffer &buffer, NodeFields &fields) {
                     added = true;
                     fields.label = title;
                     return protocol::CreateGroup(buffer, protocol::Layout::Row);
                   });
      if (added && look.mode) {
        property(parent, *look.mode, -1, {.role = protocol::Role::Mode});
      }
    }

    const std::string edit_key = property_key(but, index);
    const std::string key = this->key(edit_key);
    data.edits.add_overwrite(key,
                             {Edit::Kind::Property,
                              panel,
                              edit_key,
                              occurrence(edit_key),
                              array && index >= 0,
                              but.type == ButtonType::NumSlider});
    /* A material slot's link follows the slot's material in its row, as Blender draws it. */
    const protocol::Role role = look.role == protocol::Role::None &&
                                        RNA_struct_is_a(ptr->type, RNA_MaterialSlot) &&
                                        STREQ(RNA_property_identifier(prop), "link") ?
                                    protocol::Role::Link :
                                    look.role;
    const SelectedOthers own = look.others ? SelectedOthers() : selected_others(C, but);
    const bool mixed = others_differ(but, index, look.others ? *look.others : own);
    const auto [animation, animatable] = property_animation(C, but, index);
    const std::string icon = icon_name(button_icon(&but));
    const auto common = [&](NodeFields &fields) {
      fields.label = label;
      fields.icon = icon;
      fields.enabled = RNA_property_editable(ptr, prop) &&
                       !(but.flag & (BUT_DISABLED | BUT_INACTIVE));
      fields.mixed = mixed;
      fields.animation = animation;
      fields.animatable = animatable;
      fields.property = RNA_property_identifier(prop);
      fields.short_label = look.short_label;
      fields.role = role;
    };

    NodeId node;
    if (color) {
      float values[4] = {0, 0, 0, 1};
      RNA_property_float_get_array(ptr, prop, values);
      if (RNA_property_subtype(prop) == PROP_COLOR) {
        IMB_colormanagement_scene_linear_to_srgb_v3(values, values);
      }
      double shown[4];
      for (int i = 0; i < length; i++) {
        shown[i] = std::isfinite(values[i]) ? values[i] : 0.0;
      }
      node = builder.add(parent, key, [&](Buffer &buffer, NodeFields &fields) {
        common(fields);
        return protocol::CreateColor(buffer, buffer.CreateVector(shown, length), length == 4);
      });
    }
    else if (type == PROP_BOOLEAN) {
      const bool value = array ? RNA_property_boolean_get_index(ptr, prop, index) :
                                 RNA_property_boolean_get(ptr, prop);
      node = builder.add(parent, key, [&](Buffer &buffer, NodeFields &fields) {
        common(fields);
        return protocol::CreateToggle(buffer, value);
      });
    }
    else if (ELEM(type, PROP_INT, PROP_FLOAT)) {
      double value, min, max, fallback;
      if (type == PROP_INT) {
        int minimum, maximum;
        RNA_property_int_range(ptr, prop, &minimum, &maximum);
        value = array ? RNA_property_int_get_index(ptr, prop, index) :
                        RNA_property_int_get(ptr, prop);
        /* What Reset to Default Value gives, as Backspace over it does. */
        fallback = array ? RNA_property_int_get_default_index(ptr, prop, index) :
                           RNA_property_int_get_default(ptr, prop);
        min = minimum;
        max = maximum;
      }
      else {
        float minimum, maximum;
        RNA_property_float_range(ptr, prop, &minimum, &maximum);
        value = array ? RNA_property_float_get_index(ptr, prop, index) :
                        RNA_property_float_get(ptr, prop);
        fallback = array ? RNA_property_float_get_default_index(ptr, prop, index) :
                           RNA_property_float_get_default(ptr, prop);
        min = minimum;
        max = maximum;
      }
      const bool slider = but.type == ButtonType::NumSlider && std::isfinite(but.softmin) &&
                          std::isfinite(but.softmax) && but.softmax > but.softmin;
      const PropertyScaleType scale = button_scale_type(&but);
      double step = 0.0;
      if (but.type == ButtonType::Num) {
        step = type == PROP_INT ? 0.5 : 0.01 * static_cast<ButtonNumber &>(but).step_size;
        step = std::isfinite(step) && step > 0 ? step : 0.01;
      }
      const bool angle = ELEM(RNA_property_subtype(prop), PROP_ANGLE, PROP_EULER);
      /* The decimals Blender draws this value with, as its own field shows it: none for an
       * integer, 3 for a float drawn as some other kind of button. */
      const int precision = type == PROP_INT ? 0 :
                            ELEM(but.type, ButtonType::Num, ButtonType::NumSlider) ?
                                                     ui_but_calc_float_precision(&but, value) :
                                                     3;
      node = builder.add(parent, key, [&](Buffer &buffer, NodeFields &fields) {
        common(fields);
        return protocol::CreateNumber(
            buffer,
            std::isfinite(value) ? value : 0.0,
            type == PROP_INT,
            angle ? protocol::NumberKind::Angle : protocol::NumberKind::Plain,
            min,
            max,
            slider ? but.softmin : min,
            slider ? but.softmax : max,
            step,
            uint8_t(std::clamp(precision, 0, UI_PRECISION_FLOAT_MAX)),
            slider,
            !slider                                         ? protocol::Scale::Linear :
            scale == PROP_SCALE_LOG && but.softmin > 0      ? protocol::Scale::Logarithmic :
            scale == PROP_SCALE_CUBIC                       ? protocol::Scale::Cubic :
                                                              protocol::Scale::Linear,
            0,
            std::isfinite(fallback) ? fallback : 0.0);
      });
    }
    else if (type == PROP_STRING) {
      const std::string value = RNA_property_string_get(ptr, prop);
      node = builder.add(parent, key, [&](Buffer &buffer, NodeFields &fields) {
        common(fields);
        return protocol::CreateTextFieldDirect(buffer, value.c_str());
      });
    }
    else if (type == PROP_ENUM) {
      node = builder.add(parent, key, [&](Buffer &buffer, NodeFields &fields) {
        common(fields);
        std::string value;
        const auto options = enum_options(buffer, ptr, prop, value);
        return protocol::CreateChoice(buffer,
                                      buffer.CreateString(value),
                                      options,
                                      look.expand ? protocol::ChoiceStyle::Expanded :
                                                    protocol::ChoiceStyle::Menu);
      });
    }
    else if (type == PROP_POINTER) {
      /* A data-block, chosen by name. */
      const ID *current = RNA_property_pointer_get(ptr, prop).owner_id;
      node = builder.add(parent, key, [&](Buffer &buffer, NodeFields &fields) {
        common(fields);
        options_.clear();
        options_.push_back(protocol::CreateOptionDirect(buffer, "", "None"));
        ID *id;
        FOREACH_MAIN_ID_BEGIN (CTX_data_main(C), id) {
          PointerRNA candidate = RNA_id_pointer_create(id);
          if (RNA_struct_is_a(candidate.type, RNA_property_pointer_type(ptr, prop)) &&
              RNA_property_pointer_poll(ptr, prop, &candidate))
          {
            options_.push_back(protocol::CreateOptionDirect(
                buffer,
                std::to_string(id->session_uid).c_str(),
                id->name + 2,
                icon_name(RNA_struct_ui_icon(candidate.type))));
          }
        }
        FOREACH_MAIN_ID_END;
        return protocol::CreateChoice(
            buffer,
            buffer.CreateString(current ? std::to_string(current->session_uid) : ""),
            buffer.CreateVector(options_));
      });
    }
    else {
      /* A property of a kind not shown, named for information. */
      node = builder.add(parent, key, [&](Buffer &buffer, NodeFields &fields) {
        common(fields);
        return protocol::CreateLabel(buffer);
      });
    }
    if (look.lock) {
      property(node, *look.lock, look.lock_index, {.role = protocol::Role::Lock});
    }
    return node;
  }

  /** A color ramp, as #template_color_ramp draws it: its colors, and its stops to edit. */
  NodeId ramp(const NodeId parent, Button &but)
  {
    const ColorBand &coba = *reinterpret_cast<const ColorBand *>(but.poin);
    const std::string edit_key = ramp_key(but);
    const std::string key = this->key(edit_key);
    data.edits.add_overwrite(key, {Edit::Kind::Ramp, panel, edit_key, occurrence(edit_key)});
    const auto shown = [](const float linear[4], double *r_color) {
      float color[4];
      copy_v4_v4(color, linear);
      IMB_colormanagement_scene_linear_to_srgb_v3(color, color);
      for (int i = 0; i < 4; i++) {
        r_color[i] = std::isfinite(color[i]) ? color[i] : 0.0;
      }
    };
    /* Enough to show it smooth, as Blender evaluates it. */
    constexpr int samples = 64;
    double colors[samples * 4];
    for (int i = 0; i < samples; i++) {
      float color[4] = {0, 0, 0, 1};
      BKE_colorband_evaluate(&coba, i / float(samples - 1), color);
      shown(color, colors + i * 4);
    }
    Vector<double> stops(coba.tot * 5);
    for (int i = 0; i < coba.tot; i++) {
      const CBData &stop = coba.data[i];
      stops[i * 5] = stop.pos;
      const float color[4] = {stop.r, stop.g, stop.b, stop.a};
      shown(color, &stops[i * 5 + 1]);
    }
    return builder.add(parent, key, [&](Buffer &buffer, NodeFields &fields) {
      fields.label = RNA_property_ui_name(but.rnaprop);
      fields.enabled = !(but.flag & (BUT_DISABLED | BUT_INACTIVE)) &&
                       (!but.rnapoin.owner_id || ID_IS_EDITABLE(but.rnapoin.owner_id));
      fields.property = RNA_property_identifier(but.rnaprop);
      return protocol::CreateRamp(buffer,
                                  buffer.CreateVector(colors, samples * 4),
                                  buffer.CreateVector(stops.data(), stops.size()),
                                  coba.cur);
    });
  }

  /** A data-block picker, of the template drawing \a prop of \a ptr in \a block. */
  NodeId picker(const NodeId parent,
                const Block &block,
                const PointerRNA &ptr_const,
                PropertyRNA *prop,
                const protocol::Role role = protocol::Role::None)
  {
    PointerRNA ptr = ptr_const;
    StructRNA *type = RNA_property_pointer_type(&ptr, prop);
    const short idcode = RNA_type_to_ID_code(type);
    ID *id = RNA_property_pointer_get(&ptr, prop).owner_id;
    const std::string edit_key = id_template_key(ptr, prop);
    const std::string key = this->key(edit_key);
    data.edits.add_overwrite(key, {Edit::Kind::Picker, panel, edit_key});
    const Button *new_button = id_template_part(block, ptr, prop, UI_ID_ADD_NEW);
    const Button *unlink = id_template_part(block, ptr, prop, UI_ID_DELETE);
    if (!unlink) {
      unlink = id_template_part(block, ptr, prop, UI_ID_NOP);
    }
    const bool fake_user = id && !ID_IS_LINKED(id) &&
                           !ELEM(GS(id->name), ID_GR, ID_SCE, ID_SCR, ID_OB, ID_WS);
    const std::string preview = id ? id_preview_path(C, id) : "";
    return builder.add(parent, key, [&](Buffer &buffer, NodeFields &fields) {
      fields.label = RNA_property_ui_name(prop);
      fields.icon = icon_name(RNA_struct_ui_icon(type));
      fields.enabled = RNA_property_editable(&ptr, prop) &&
                       (!ptr.owner_id || ID_IS_EDITABLE(ptr.owner_id));
      fields.role = role;
      options_.clear();
      if (ListBaseT<ID> *ids = idcode ? which_libbase(CTX_data_main(C), idcode) : nullptr) {
        for (ID &candidate : *ids) {
          /* Blender's search hides names starting with a dot unless typed. */
          if (candidate.name[2] == '.' && &candidate != id) {
            continue;
          }
          PointerRNA candidate_ptr = RNA_id_pointer_create(&candidate);
          if (!RNA_property_pointer_poll(&ptr, prop, &candidate_ptr)) {
            continue;
          }
          options_.push_back(
              protocol::CreateOptionDirect(buffer,
                                           std::to_string(candidate.session_uid).c_str(),
                                           candidate.name + 2,
                                           nullptr,
                                           id_preview_path(C, &candidate).c_str(),
                                           users_text(candidate).c_str()));
        }
      }
      return protocol::CreateReference(
          buffer,
          buffer.CreateString(RNA_struct_ui_name(type)),
          buffer.CreateString(id ? id->name + 2 : ""),
          buffer.CreateString(id ? std::to_string(id->session_uid) : ""),
          id ? id->us : 0,
          id && ID_IS_LINKED(id),
          fake_user && (id->flag & ID_FLAG_FAKEUSER),
          new_button && new_button->optype && new_button->optype->exec &&
              !(new_button->flag & BUT_DISABLED),
          id && unlink && !(RNA_property_flag(prop) & PROP_NEVER_NULL),
          id && id->us > 1 && id_template_part(block, ptr, prop, UI_ID_ALONE),
          fake_user,
          buffer.CreateVector(options_),
          buffer.CreateString(preview),
          /* Fonts are chosen with the system's font picker, see `load_font`. */
          idcode == ID_VF,
          buffer.CreateString(idcode == ID_VF && id ? reinterpret_cast<VFont *>(id)->filepath :
                                                      ""));
    });
  }

  /** An operator's button, run by \a but's key, or a switch when it shows as a checkbox. */
  NodeId button(const NodeId parent,
                const Button &but,
                const protocol::Role role = protocol::Role::None,
                const std::string_view label = {})
  {
    const std::string edit_key = operator_key(C, but, object);
    const std::string key = this->key(edit_key);
    data.edits.add_overwrite(key, {Edit::Kind::Operator, panel, edit_key});
    const std::string text = !label.empty()   ? std::string(label) :
                             but.str.empty() ? WM_operatortype_name(but.optype, but.opptr) :
                                               but.str;
    const int icon = button_icon(&but);
    const auto common = [&](NodeFields &fields) {
      fields.label = text;
      fields.icon = icon_name(icon);
      fields.enabled = !(but.flag & (BUT_DISABLED | BUT_INACTIVE)) && but.optype->exec;
      fields.role = role;
    };
    if (ELEM(icon, ICON_CHECKBOX_HLT, ICON_CHECKBOX_DEHLT)) {
      /* A toggle operator drawn as a checkbox, such as Dyntopo: a switch. */
      return builder.add(parent, key, [&](Buffer &buffer, NodeFields &fields) {
        common(fields);
        return protocol::CreateToggle(buffer, icon == ICON_CHECKBOX_HLT);
      });
    }
    const StringRef idname = but.optype->idname;
    const bool destructive = idname.find("remove") != StringRef::not_found ||
                             idname.find("delete") != StringRef::not_found ||
                             StringRef(text).startswith("Remove") ||
                             StringRef(text).startswith("Delete");
    return builder.add(parent, key, [&](Buffer &buffer, NodeFields &fields) {
      common(fields);
      return protocol::CreateButton(buffer,
                                    destructive ? protocol::ButtonStyle::Destructive :
                                                  protocol::ButtonStyle::Normal,
                                    0,
                                    0,
                                    0,
                                    false,
                                    label.empty() && but.str.empty() && icon != ICON_NONE);
    });
  }

  /** A list, or a tree as one, with \a rows, and the buttons \a side beside it. */
  NodeId list(const NodeId parent,
              const std::string &edit_key,
              const ListSide *side,
              const bool reorder,
              const int64_t active,
              const Span<ListRow> rows,
              const bool editable = true)
  {
    const std::string key = this->key(edit_key);
    Edit edit{Edit::Kind::List, panel, edit_key};
    if (side && side->add && side->add->optype) {
      edit.add = operator_key(C, *side->add, object);
    }
    if (side && side->remove && side->remove->optype) {
      edit.remove = operator_key(C, *side->remove, object);
    }
    const bool can_add = !edit.add.empty(), can_remove = !edit.remove.empty();
    data.edits.add_overwrite(key, std::move(edit));
    std::string active_key;
    bool tree = false;
    for (const ListRow &row : rows) {
      if (row.index == active) {
        active_key = key + ":" + std::to_string(active);
      }
      tree |= row.depth > 0;
    }
    const NodeId list = builder.add(parent, key, [&](Buffer &buffer, NodeFields &fields) {
      fields.enabled = editable;
      return protocol::CreateListDirect(
          buffer,
          active_key.c_str(),
          can_add,
          can_remove,
          reorder && side && side->up && side->down &&
              !(side->up->flag & (BUT_DISABLED | BUT_INACTIVE)),
          tree,
          side && side->menu ? side->menu->idname : nullptr);
    });
    for (const ListRow &row : rows) {
      list_row(list, key, row, row.index == active);
    }
    if (side) {
      /* Adding and removing are the list's own commands; the rest are buttons beside it. */
      for (const Button *extra : side->extras) {
        button(list, *extra);
      }
      if (const char *duplicate = side->add && side->add->optype ?
                                      duplicate_operator(side->add->optype->idname) :
                                      nullptr)
      {
        const std::string duplicate_key = this->key(key + ":duplicate");
        data.edits.add_overwrite(duplicate_key, {Edit::Kind::Call, panel, duplicate});
        builder.add(list, duplicate_key, [&](Buffer &buffer, NodeFields &fields) {
          fields.label = "Duplicate";
          fields.icon = "DUPLICATE";
          fields.role = protocol::Role::Duplicate;
          return protocol::CreateButton(buffer);
        });
      }
    }
    return list;
  }

  /** A row with its name and icon, and the controls drawn over it, from the buttons on it. */
  NodeId list_row(const NodeId parent,
                  const std::string &list_key,
                  const ListRow &row,
                  const bool selected)
  {
    std::string label;
    std::string name_key;
    int icon = ICON_NONE;
    static const std::vector<const Button *> none;
    const std::vector<const Button *> &items = row.items ? *row.items : none;
    for (const Button *item : items) {
      if (icon == ICON_NONE && button_icon(item) != ICON_NONE) {
        icon = button_icon(item);
      }
      if (!label.empty() || (item->flag & UI_HIDDEN)) {
        continue;
      }
      if (item->rnaprop && RNA_property_type(item->rnaprop) == PROP_STRING) {
        PointerRNA item_ptr = item->rnapoin;
        label = RNA_property_string_get(&item_ptr, item->rnaprop);
        if (STREQ(RNA_property_identifier(item->rnaprop), "name") &&
            RNA_property_editable(&item_ptr, item->rnaprop))
        {
          name_key = property_key(*item, -1);
        }
      }
      else if (ELEM(item->type, ButtonType::Label, ButtonType::Text) && !item->str.empty()) {
        label = item->str;
      }
    }
    if (label.empty()) {
      label = row.fallback;
    }
    const std::string preview = icon >= BIFICONID_LAST_STATIC ? preview_icon_path(C, icon) : "";
    const std::string key = this->key(list_key + ":" + std::to_string(row.index));
    data.rows.add_overwrite(
        key, {list_key, row.index, name_key, name_key.empty() ? 0 : occurrence(name_key)});
    const NodeId node = builder.add(parent, key, [&](Buffer &buffer, NodeFields &fields) {
      fields.label = label;
      fields.icon = icon_name(preview.empty() ? icon : ICON_NONE);
      return protocol::CreateRowDirect(buffer,
                                       row.depth,
                                       selected,
                                       row.renamable || !name_key.empty(),
                                       preview.c_str());
    });
    /* What it draws beside its name, such as a shape key's value or a vertex group's lock. */
    for (const Button *item : items) {
      if (!(item->flag & UI_HIDDEN) && item->rnaprop && item->rnapoin.data &&
          !RNA_property_array_check(item->rnaprop) &&
          ELEM(RNA_property_type(item->rnaprop), PROP_BOOLEAN, PROP_INT, PROP_FLOAT, PROP_ENUM))
      {
        property(node, const_cast<Button &>(*item), -1);
      }
    }
    return node;
  }

  /** The options of an enum, and the value of the chosen one. */
  flatbuffers::Offset<flatbuffers::Vector<flatbuffers::Offset<protocol::Option>>> enum_options(
      Buffer &buffer, PointerRNA *ptr, PropertyRNA *prop, std::string &r_value)
  {
    const int selected = RNA_property_enum_get(ptr, prop);
    const bool flags = RNA_property_flag(prop) & PROP_ENUM_FLAG;
    const EnumPropertyItem *items;
    int count;
    bool free;
    RNA_property_enum_items(C, ptr, prop, &items, &count, &free);
    options_.clear();
    for (int i = 0; i < count; i++) {
      const EnumPropertyItem &item = items[i];
      if (!item.identifier || !item.identifier[0]) {
        continue;
      }
      options_.push_back(protocol::CreateOptionDirect(buffer,
                                                      item.identifier,
                                                      item.name,
                                                      icon_name(item.icon),
                                                      preview_icon_path(C, item.icon).c_str()));
      if (flags ? (selected & item.value) != 0 : selected == item.value) {
        r_value = item.identifier;
      }
    }
    if (free) {
      MEM_delete(items);
    }
    return buffer.CreateVector(options_);
  }

 private:
  std::set<std::string> used_;
  /** How many buttons of each key each panel has, see #native::Edit::occurrence. */
  std::map<std::pair<std::string, std::string>, int> occurrences_;

  int occurrence(const std::string &edit_key)
  {
    return occurrences_[{panel, edit_key}]++;
  }
  /** Rows of components and of toggles, by their parent and key. */
  std::map<std::pair<NodeId, std::string>, NodeId> rows_;
  std::vector<flatbuffers::Offset<protocol::Option>> options_;

  template<typename Write> NodeId row(const NodeId parent, const std::string &key, Write write)
  {
    const auto [found, added] = rows_.try_emplace({parent, key}, 0);
    if (added) {
      found->second = builder.add(parent, this->key(key), write);
    }
    return found->second;
  }

  static std::string users_text(const ID &id)
  {
    std::string text = id.us > 1 ? std::to_string(id.us) + " users" :
                       id.us == 0 ? "No users" :
                                    "";
    if (ID_IS_LINKED(&id)) {
      text += text.empty() ? "Linked" : " · Linked";
    }
    return text;
  }
};

/** \} */
}  // namespace

std::string native_id_preview_path(bContext *C, ID *id)
{
  return id_preview_path(C, id);
}

namespace {
/* Engine-owned identity, invalidated before the operator's memory can be reused. */
wmOperator *native_redo_operator = nullptr;
uint64_t native_redo_generation = 0;
bool native_redo_dismissed = false;
/* Counts requests to open Adjust Last Operation, for the interface to notice a new one. */
int native_redo_show_requests = 0;
std::string native_redo_error;

/**
 * Calls \a fn with each of an operator's properties that \a draw lays out, as its buttons do,
 * with what it shares a row with. With \a groups, those of its property groups too, as Batch
 * Rename's steps.
 */
template<typename Draw, typename Fn>
void for_each_operator_field(bContext *C, const bool groups, Draw draw, Fn fn)
{
  Block *block = block_begin(C, nullptr, "native_operator", EmbossType::Emboss);
  Layout &layout = block_layout(
      block, LayoutDirection::Vertical, LayoutType::Panel, 0, 0, 320, 20, 0, style_get_dpi());
  draw(layout);
  const auto pairs = property_pairs(*block);
  block_end(C, block);
  std::set<std::string> seen;
  for (const auto &button : block->buttons) {
    Button &but = *button;
    if (!but.rnaprop || !but.rnapoin.data || (but.flag & UI_HIDDEN) ||
        !(RNA_struct_is_a(but.rnapoin.type, RNA_OperatorProperties) ||
          (groups && RNA_struct_is_a(but.rnapoin.type, RNA_PropertyGroup))) ||
        !ELEM(RNA_property_type(but.rnaprop),
              PROP_BOOLEAN,
              PROP_INT,
              PROP_FLOAT,
              PROP_STRING,
              PROP_ENUM))
    {
      continue;
    }
    const int length = RNA_property_array_length(&but.rnapoin, but.rnaprop);
    const bool color = is_color(&but.rnapoin, but.rnaprop);
    const int begin = !color && length ? std::max(0, but.rnaindex) : -1;
    const int end = !color && length && but.rnaindex < 0 ? length : begin + 1;
    for (int index = begin; index < end; ++index) {
      if (seen.insert(property_key(but, index)).second) {
        const auto pair = pairs.find(&but);
        fn(but, index, pair == pairs.end() ? nullptr : &pair->second);
      }
    }
  }
  block_free(C, block);
}

/** Writes an operator's properties under \a parent, which \a top writes on the first of them. */
template<typename Draw, typename Top>
void write_operator(Writer &writer, const bool groups, Draw draw, Top top)
{
  std::optional<NodeId> parent;
  const SelectedOthers none;
  for_each_operator_field(
      writer.C, groups, draw, [&](Button &but, const int index, const PropertyPair *pair) {
        if (!parent) {
          parent = top();
        }
        writer.property(*parent, but, index, {.others = &none, .pair = pair});
      });
}

/** Sets the operator's property \a request edits; false when it is not there. */
template<typename Draw>
bool edit_operator(bContext *C, const bool groups, Draw draw, const native::EditRequest &request)
{
  bool applied = false;
  for_each_operator_field(
      C, groups, draw, [&](Button &but, const int index, const PropertyPair * /*pair*/) {
        if (!applied && request.edit && property_key(but, index) == request.edit->key) {
          applied = set_property(C, but, index, request, false);
        }
      });
  return applied;
}

/** The last operation, while it can be adjusted. */
wmOperator *redo_operator(bContext *C)
{
  wmOperator *op = WM_operator_last_redo(C);
  if (!op || op != native_redo_operator || native_redo_dismissed || !CTX_wm_view3d(C) ||
      !CTX_wm_region(C) || G.moving || !WM_operator_repeat_check(C, op) ||
      !WM_operator_poll(C, op->type) || !WM_operator_check_ui_enabled(C, op->type->name))
  {
    return nullptr;
  }
  if (wmWindow *window = CTX_wm_window(C)) {
    for (wmEventHandler &handler : window->runtime->modalhandlers) {
      if (ELEM(handler.type, WM_HANDLER_TYPE_OP, WM_HANDLER_TYPE_UI)) {
        return nullptr;
      }
    }
  }
  return op;
}

void redo_draw(bContext *C, Layout &layout)
{
  /* The operator's own interface, macros and `poll_property` included. */
  template_operator_redo_properties(&layout, C);
}

}  // namespace

void native_properties_interaction_finish(bContext *C)
{
  finish_property_interaction(C);
}

void native_redo_operator_register(bContext *C, wmOperator *op)
{
  if ((op->type->flag & (OPTYPE_REGISTER | OPTYPE_UNDO)) != (OPTYPE_REGISTER | OPTYPE_UNDO)) {
    return;
  }
  native_redo_operator = CTX_wm_view3d(C) ? op : nullptr;
  ++native_redo_generation;
  native_redo_dismissed = false;
  native_redo_error.clear();
}

void native_redo_operator_free(wmOperator *op)
{
  if (native_redo_operator == op) {
    native_redo_operator = nullptr;
  }
}

void native_redo_show(bContext * /*C*/)
{
  native_redo_dismissed = false;
  ++native_redo_show_requests;
  WM_main_add_notifier(NC_WINDOW, nullptr);
}

void native_redo_operator_clear()
{
  native_redo_operator = nullptr;
}

namespace native {

void redo_write(bContext *C, PanelsData &data, ViewBuilder &builder)
{
  Writer writer(C, builder, data);
  wmOperator *op = redo_operator(C);
  data.identity = op ? std::to_string(native_redo_generation) : "";
  if (op) {
    write_operator(
        writer, false, [&](Layout &layout) { redo_draw(C, layout); }, [&]() {
          /* Held here: `fields.label` is a view, and the name a temporary (found by clang's
           * dangling-assignment warning in the 5.3 clone, `10592fe7415`). */
          const std::string operator_name = WM_operatortype_name(op->type, op->ptr);
          return builder.top(data.identity, [&](Buffer &buffer, NodeFields &fields) {
            fields.label = operator_name;
            return protocol::CreateOperatorDirect(buffer,
                                                  op->type->idname,
                                                  nullptr,
                                                  nullptr,
                                                  native_redo_error.c_str(),
                                                  uint32_t(native_redo_show_requests));
          });
        });
  }
  if (data.edits.is_empty()) {
    /* No operation, or none with settings. */
    builder.top("none", [](Buffer &buffer, NodeFields & /*fields*/) {
      return protocol::CreateGroup(buffer);
    });
  }
}

std::string redo_edit(bContext *C, PanelsData &data, const EditRequest &request)
{
  wmOperator *op = redo_operator(C);
  if (!op || data.identity != std::to_string(native_redo_generation)) {
    return "The operation can no longer be adjusted.";
  }
  native_redo_error.clear();
  if (request.action == "dismiss") {
    native_redo_dismissed = true;
    return "";
  }
  if (!edit_operator(C, false, [&](Layout &layout) { redo_draw(C, layout); }, request) ||
      !ED_undo_operator_repeat(C, op))
  {
    native_redo_error = "This operation could not be adjusted.";
  }
  return native_redo_error;
}

}  // namespace native

namespace {
/* An operator whose properties are set before it runs, in place of Blender's dialog: owned here
 * until it runs or is cancelled, see #native_operator_dialog_begin. */
wmOperator *native_dialog_operator = nullptr;
/* Set when the operator is not the dialog's: OK and Cancel hand it back (true for OK) instead of
 * running or freeing it, see #native_operator_dialog_handback. */
std::function<void(bContext *, bool)> native_dialog_then;
uint64_t native_dialog_generation = 0;
std::string native_dialog_title;
std::string native_dialog_confirm;
std::string native_dialog_message;
/* Where it was started, for it to run there. */
wmWindow *native_dialog_window = nullptr;
ScrArea *native_dialog_area = nullptr;
ARegion *native_dialog_region = nullptr;

void native_dialog_end()
{
  native_dialog_operator = nullptr;
  native_dialog_then = nullptr;
  native_dialog_window = nullptr;
  native_dialog_area = nullptr;
  native_dialog_region = nullptr;
  WM_main_add_notifier(NC_WINDOW, nullptr);
}

/** Back where the dialog was started, if its window and editor are still there. */
void native_dialog_context(bContext *C)
{
  wmWindowManager *wm = CTX_wm_manager(C);
  if (!native_dialog_window || BLI_findindex(&wm->windows, native_dialog_window) == -1) {
    return;
  }
  CTX_wm_window_set(C, native_dialog_window);
  bScreen *screen = WM_window_get_active_screen(native_dialog_window);
  ScrArea *area = screen && BLI_findindex(&screen->areabase, native_dialog_area) != -1 ?
                      native_dialog_area :
                      nullptr;
  CTX_wm_area_set(C, area);
  CTX_wm_region_set(
      C, area && BLI_findindex(&area->regionbase, native_dialog_region) != -1 ? native_dialog_region : nullptr);
}
}  // namespace

bool native_operator_dialog_begin(bContext *C,
                                  wmOperator *op,
                                  const std::string &title,
                                  const std::string &confirm,
                                  const std::string &message)
{
  if (native_dialog_operator || !CTX_wm_window(C)) {
    return false;
  }
  native_dialog_operator = op;
  ++native_dialog_generation;
  native_dialog_title = title;
  native_dialog_confirm = confirm;
  native_dialog_message = message;
  native_dialog_window = CTX_wm_window(C);
  native_dialog_area = CTX_wm_area(C);
  native_dialog_region = CTX_wm_region(C);
  WM_main_add_notifier(NC_WINDOW, nullptr);
  return true;
}

bool native_operator_dialog_handback(bContext *C,
                                     wmOperator *op,
                                     const std::string &title,
                                     const std::string &confirm,
                                     std::function<void(bContext *, bool)> then)
{
  if (!native_operator_dialog_begin(C, op, title, confirm, "")) {
    return false;
  }
  native_dialog_then = std::move(then);
  return true;
}

void native_operator_dialog_abandon(const wmOperator *op)
{
  if (op && native_dialog_operator == op) {
    native_dialog_end();
  }
}

namespace native {

static void dialog_draw(bContext *C, Layout &layout)
{
  /* The operator's own dialog, its draw function included, as Blender would show it. */
  uiTemplateOperatorPropertyButs(C, &layout, native_dialog_operator, BUT_LABEL_ALIGN_NONE, 0);
}

void dialog_write(bContext *C, PanelsData &data, ViewBuilder &builder)
{
  Writer writer(C, builder, data);
  wmOperator *op = native_dialog_operator;
  data.identity = op ? "dialog" + std::to_string(native_dialog_generation) : "";
  if (!op) {
    builder.top("none", [](Buffer &buffer, NodeFields & /*fields*/) {
      return protocol::CreateGroup(buffer);
    });
    return;
  }
  const NodeId top = builder.top(data.identity, [&](Buffer &buffer, NodeFields &fields) {
    fields.label = native_dialog_title;
    return protocol::CreateOperatorDirect(buffer,
                                          op->type->idname,
                                          native_dialog_confirm.c_str(),
                                          native_dialog_message.c_str());
  });
  write_operator(
      writer, true, [&](Layout &layout) { dialog_draw(C, layout); }, [&]() { return top; });
}

std::string dialog_edit(bContext *C, PanelsData &data, const EditRequest &request)
{
  wmOperator *op = native_dialog_operator;
  if (!op || data.identity != "dialog" + std::to_string(native_dialog_generation)) {
    return "The dialog is no longer open.";
  }
  if (native_dialog_then && (ELEM(request.action, "cancel", "dismiss", "confirm"))) {
    /* Handed back where it is owned, in the context the dialog was started in. */
    std::function<void(bContext *, bool)> then = std::move(native_dialog_then);
    native_dialog_end();
    then(C, request.action == "confirm");
    return "";
  }
  if (ELEM(request.action, "cancel", "dismiss")) {
    native_dialog_end();
    if (op->type->cancel) {
      op->type->cancel(C, op);
    }
    WM_operator_free(op);
    return "";
  }
  if (request.action == "confirm") {
    native_dialog_end();
    wmWindow *previous_window = CTX_wm_window(C);
    ScrArea *previous_area = CTX_wm_area(C);
    ARegion *previous_region = CTX_wm_region(C);
    native_dialog_context(C);
    /* As Blender's OK button: the operator is registered, or freed. */
    WM_operator_call_ex(C, op, true);
    CTX_wm_window_set(C, previous_window);
    CTX_wm_area_set(C, previous_area);
    CTX_wm_region_set(C, previous_region);
    return "";
  }
  if (!edit_operator(C, true, [&](Layout &layout) { dialog_draw(C, layout); }, request)) {
    return "This setting is no longer available.";
  }
  /* As Blender's dialog: the operator may change its properties as others change. */
  if (op->type->check) {
    op->type->check(C, op);
  }
  return "";
}

}  // namespace native

namespace {

/** Preferences tabs are the Preferences' section identifiers with this prefix. */
constexpr const char *PREFERENCES_TAB_PREFIX = "PREFERENCES_";
/* The 3D Viewport sidebar's tabs other than Tool, add-ons' among them (LoopTools' Edit and the
 * like), as Properties tabs named apart: `SIDEBAR:Edit`. */
constexpr const char *SIDEBAR_TAB_PREFIX = "SIDEBAR:";

/** The sidebar's categories beside Tool that have panels, in the order Blender registered them. */
static Vector<std::string> sidebar_categories()
{
  Vector<std::string> categories;
  ARegionType *region_type = BKE_regiontype_from_id(BKE_spacetype_from_id(SPACE_VIEW3D), RGN_TYPE_UI);
  if (region_type == nullptr) {
    return categories;
  }
  for (PanelType &pt : region_type->paneltypes) {
    if (pt.parent_id[0] || !pt.category[0] || STREQ(pt.category, "Tool") || !pt.draw ||
        categories.contains(pt.category))
    {
      continue;
    }
    categories.append(pt.category);
  }
  return categories;
}

/**
 * List the Preferences' sections as tabs and return the requested one's tab id. \a panel_context
 * is the section's panel context, or empty for a section drawn with lists of its own (the
 * add-ons), which the native interface shows in its own way.
 */
/** A tab of Properties or of the Preferences. */
struct Tab {
  std::string id, title, icon;
  /** Tabs group by this number, as the Preferences' sections between separators. */
  int group = 0;
  /** Shown by Blender's own Preferences only, see #protocol::Option. */
  bool external = false;
};

std::string preferences_tabs(bContext *C,
                             const std::string &requested_tab,
                             Vector<Tab> &tabs,
                             std::string &panel_context)
{
  /* Icons for the sections, which Blender's Preferences list as text only. */
  static const std::map<std::string, const char *> section_icons = {
      {"INTERFACE", "WORKSPACE"},
      {"VIEWPORT", "VIEW3D"},
      {"LIGHTS", "LIGHT"},
      {"EDITING", "EDITMODE_HLT"},
      {"ANIMATION", "ANIM"},
      {"EXTENSIONS", "INTERNET"},
      {"ADDONS", "PLUGIN"},
      {"THEMES", "COLOR"},
      {"INPUT", "MOUSE_LMB"},
      {"NAVIGATION", "VIEW_PAN"},
      {"KEYMAP", "KEYINGSET"},
      {"SYSTEM", "SYSTEM"},
      {"SAVE_LOAD", "FILE_BLEND"},
      {"FILE_PATHS", "FILE_FOLDER"},
      {"DEVELOPER_TOOLS", "CONSOLE"},
      {"EXPERIMENTAL", "EXPERIMENTAL"},
  };
  static const std::set<std::string> external_sections = {"ADDONS"};
  /* Getting extensions downloads code to run, which apps on iPad may not do. */
  /* Getting extensions downloads code to run. Themes and the interface's own settings are for
   * Blender's drawn interface, which the native one does not use, and file paths for folders on a
   * desktop computer, where on the iPad documents are in Files. */
  static const std::set<std::string> hidden_sections = {
      "EXTENSIONS", "THEMES", "INTERFACE", "FILE_PATHS"};
  const std::string requested = requested_tab.substr(strlen(PREFERENCES_TAB_PREFIX));
  PointerRNA prefs_ptr = RNA_pointer_create_discrete(nullptr, RNA_Preferences, &U);
  PropertyRNA *section_prop = RNA_struct_find_property(&prefs_ptr, "active_section");
  const EnumPropertyItem *sections;
  int section_count;
  bool free_sections;
  RNA_property_enum_items(C, &prefs_ptr, section_prop, &sections, &section_count, &free_sections);
  std::string selected;
  /* Sections between separators, grouped as Blender's Preferences list them. */
  int group = 0;
  for (int i = 0; i < section_count; i++) {
    const EnumPropertyItem &section = sections[i];
    if (!section.identifier || !section.identifier[0]) {
      group += tabs.is_empty() ? 0 : 1;
      continue;
    }
    if (hidden_sections.count(section.identifier)) {
      continue;
    }
    if (selected.empty() || requested == section.identifier) {
      selected = section.identifier;
    }
    const auto icon = section_icons.find(section.identifier);
    tabs.append({PREFERENCES_TAB_PREFIX + std::string(section.identifier),
                 section.name,
                 icon != section_icons.end() ? icon->second : "PREFERENCES",
                 group,
                 external_sections.count(section.identifier) != 0});
  }
  if (free_sections) {
    MEM_delete(sections);
  }
  panel_context.clear();
  if (!external_sections.count(selected)) {
    panel_context = selected;
    std::transform(panel_context.begin(), panel_context.end(), panel_context.begin(), ::tolower);
  }
  return PREFERENCES_TAB_PREFIX + selected;
}

/** A button showing a property's value, which is a control of its own. */
bool value_button(const Button &but)
{
  if (!but.rnaprop || !but.rnapoin.data || but.optype || (but.flag & UI_HIDDEN) ||
      ELEM(but.type, ButtonType::ListRow, ButtonType::ListBox, ButtonType::ViewItem) ||
      button_menutype_get(&but))
  {
    return false;
  }
  PointerRNA template_ptr;
  PropertyRNA *template_prop;
  int template_event;
  if (template_id_property_get(but, template_ptr, template_prop, template_event)) {
    return false;
  }
  const PropertyType type = RNA_property_type(but.rnaprop);
  return ELEM(type, PROP_BOOLEAN, PROP_INT, PROP_FLOAT, PROP_STRING, PROP_ENUM) ||
         (type == PROP_POINTER &&
          RNA_struct_is_ID(RNA_property_pointer_type(const_cast<PointerRNA *>(&but.rnapoin),
                                                      but.rnaprop)));
}

/**
 * Preferences left out of their sections: the iPad sets these itself on every redraw (see
 * `ios_ui_apply_viewport_preferences`), the keymap's filter belongs to a Preferences editor,
 * which is made anew for every read here and so would not keep its text, and the keymaps
 * themselves are listed by the native interface in its own way.
 */
bool preferences_hidden(const PointerRNA &ptr, PropertyRNA *prop)
{
  if (RNA_struct_is_a(ptr.type, RNA_SpacePreferences) || RNA_struct_is_a(ptr.type, RNA_KeyMap) ||
      RNA_struct_is_a(ptr.type, RNA_KeyMapItem))
  {
    return true;
  }
#ifndef APPLE_TARGET_MACOS_NATIVE
  if (ptr.data == &U) {
    static const std::set<std::string> set_by_ipad = {"show_tooltips",
                                                      "show_tooltips_python",
                                                      "show_navigate_ui",
                                                      "show_gizmo",
                                                      "mini_axis_type",
                                                      "drag_threshold_mouse",
                                                      "drag_threshold_tablet",
                                                      "drag_threshold",
                                                      "move_threshold"};
    return set_by_ipad.count(RNA_property_identifier(prop)) != 0;
  }
#endif
  return false;
}

/* -------------------------------------------------------------------- */
/** \name The census (ROUND6 PANEL-1, decision R6-9)
 *
 * What became of each button a panel drew: shown as a node (`projected`, and as which kind),
 * taken into another node (`consumed`: a caption, a template's part, a list's side buttons),
 * shown in part (`reduced`), left out on purpose (`hidden`), or `dropped`, and why. Whatever a
 * panel dropped, it says in one row at its foot, with a button to the Desktop Interface; a whole
 * panel dropped is said at the foot of the tab. The Mac harness's `census` scenario reads every
 * fate and fails on a reason it has no entry for.
 * \{ */

/** What became of one button, see above. The reason is a stable name the harness keys on. */
struct Fate {
  const char *outcome = "";
  std::string kind;
  const char *reason = "";
  /** For a dropped one, what the row counts it as. */
  enum class Counted : uint8_t { No, Control, Note, Section, Panel } counted = Counted::No;
};

Fate fate_projected(const std::string &kind)
{
  return {"projected", kind, ""};
}

Fate fate_consumed(const char *reason)
{
  return {"consumed", "", reason};
}

Fate fate_dropped(const char *reason, const Fate::Counted counted = Fate::Counted::Control)
{
  return {"dropped", "", reason, counted};
}

/** What a panel (or a tab) could not show, as its row says it. */
struct Said {
  int controls = 0, notes = 0, sections = 0, panels = 0;

  void add(const Fate::Counted counted)
  {
    switch (counted) {
      case Fate::Counted::Control: controls++; break;
      case Fate::Counted::Note: notes++; break;
      case Fate::Counted::Section: sections++; break;
      case Fate::Counted::Panel: panels++; break;
      case Fate::Counted::No: break;
    }
  }

  int total() const
  {
    return controls + notes + sections + panels;
  }

  /** "2 controls and 1 note of this panel are only in the Desktop Interface." */
  std::string text(const char *where) const
  {
    std::vector<std::string> parts;
    const auto part = [&](const int count, const char *one, const char *many) {
      if (count) {
        parts.push_back(std::to_string(count) + " " + (count == 1 ? one : many));
      }
    };
    part(controls, "control", "controls");
    part(notes, "note", "notes");
    part(sections, "section", "sections");
    part(panels, "panel", "panels");
    std::string text;
    for (size_t i = 0; i < parts.size(); i++) {
      text += (i == 0 ? "" : i + 1 == parts.size() ? " and " : ", ") + parts[i];
    }
    return text + " of this " + where + (total() == 1 ? " is" : " are") +
           " only in the Desktop Interface.";
  }
};

/** Every fate while the harness records them (`UI_native_panel_census_record`). */
bool census_recording = false;
std::shared_ptr<io::serialize::ArrayValue> census_log;

const char *button_type_name(const ButtonType type)
{
  switch (type) {
#define BUTTON_TYPE(name) \
  case ButtonType::name: \
    return #name;
    BUTTON_TYPE(But)
    BUTTON_TYPE(Row)
    BUTTON_TYPE(Text)
    BUTTON_TYPE(Menu)
    BUTTON_TYPE(ButMenu)
    BUTTON_TYPE(Num)
    BUTTON_TYPE(NumSlider)
    BUTTON_TYPE(Toggle)
    BUTTON_TYPE(ToggleN)
    BUTTON_TYPE(IconToggle)
    BUTTON_TYPE(IconToggleN)
    BUTTON_TYPE(ButToggle)
    BUTTON_TYPE(Checkbox)
    BUTTON_TYPE(CheckboxN)
    BUTTON_TYPE(Color)
    BUTTON_TYPE(Tab)
    BUTTON_TYPE(Popover)
    BUTTON_TYPE(Scroll)
    BUTTON_TYPE(Block)
    BUTTON_TYPE(Label)
    BUTTON_TYPE(KeyEvent)
    BUTTON_TYPE(HsvCube)
    BUTTON_TYPE(Pulldown)
    BUTTON_TYPE(Roundbox)
    BUTTON_TYPE(ColorBand)
    BUTTON_TYPE(Unitvec)
    BUTTON_TYPE(Curve)
    BUTTON_TYPE(CurveProfile)
    BUTTON_TYPE(ListBox)
    BUTTON_TYPE(ListRow)
    BUTTON_TYPE(HsvCircle)
    BUTTON_TYPE(TrackPreview)
    BUTTON_TYPE(SearchMenu)
    BUTTON_TYPE(Extra)
    BUTTON_TYPE(PreviewTile)
    BUTTON_TYPE(HotkeyEvent)
    BUTTON_TYPE(Image)
    BUTTON_TYPE(Histogram)
    BUTTON_TYPE(Waveform)
    BUTTON_TYPE(Vectorscope)
    BUTTON_TYPE(Progress)
    BUTTON_TYPE(NodeSocket)
    BUTTON_TYPE(Sepr)
    BUTTON_TYPE(SeprLine)
    BUTTON_TYPE(SeprSpacer)
    BUTTON_TYPE(Grip)
    BUTTON_TYPE(Decorator)
    BUTTON_TYPE(ViewItem)
#undef BUTTON_TYPE
  }
  return "Unknown";
}

/** What a button is about, for the census: its property, operator, menu or text. */
std::string button_detail(const Button &but)
{
  if (but.rnaprop) {
    return std::string(but.rnapoin.type ? RNA_struct_identifier(but.rnapoin.type) : "") + "." +
           RNA_property_identifier(but.rnaprop);
  }
  if (but.optype) {
    return but.optype->idname;
  }
  if (const MenuType *menu = button_menutype_get(const_cast<Button *>(&but))) {
    return menu->idname;
  }
  if (const PanelType *panel = button_paneltype_get(const_cast<Button *>(&but))) {
    return panel->idname;
  }
  return but.str;
}

void census_record(const std::string &tab,
                   const std::string &panel,
                   const std::string &button,
                   const std::string &detail,
                   const Fate &fate)
{
  if (!census_recording) {
    return;
  }
  if (!census_log) {
    census_log = std::make_shared<io::serialize::ArrayValue>();
  }
  io::serialize::DictionaryValue &entry = *census_log->append_dict();
  entry.append_str("tab", tab);
  entry.append_str("panel", panel);
  entry.append_str("button", button);
  entry.append_str("detail", detail);
  entry.append_str("outcome", fate.outcome);
  entry.append_str("kind", fate.kind);
  entry.append_str("reason", fate.reason);
  entry.append_str("counted",
                   fate.counted == Fate::Counted::Control ? "control" :
                   fate.counted == Fate::Counted::Note    ? "note" :
                   fate.counted == Fate::Counted::Section ? "section" :
                   fate.counted == Fate::Counted::Panel   ? "panel" :
                                                            "");
}

/** The node kind a property is written as, see #Writer::property. */
std::string property_kind(const Button &but)
{
  if (is_color(const_cast<PointerRNA *>(&but.rnapoin), but.rnaprop)) {
    return "Color";
  }
  switch (RNA_property_type(but.rnaprop)) {
    case PROP_BOOLEAN: return "Toggle";
    case PROP_INT:
    case PROP_FLOAT: return "Number";
    case PROP_STRING: return "TextField";
    case PROP_ENUM: return "Choice";
    case PROP_POINTER: return "Choice";
    default: return "Label";
  }
}

/** A property the walker writes, shown in part where its node cannot carry all of it. */
Fate property_fate(const Button &but)
{
  Fate fate = fate_projected(property_kind(but));
  const auto reduced = [&](const char *reason) {
    fate.outcome = "reduced";
    fate.reason = reason;
  };
  const PropertyType type = RNA_property_type(but.rnaprop);
  if (but.type == ButtonType::Color && static_cast<const ButtonColor &>(but).is_pallete_color) {
    /* A palette's swatch picks its colour in Blender; here it edits it (B17). */
    reduced("palette");
  }
  else if (type == PROP_STRING &&
           ELEM(RNA_property_subtype(but.rnaprop), PROP_FILEPATH, PROP_DIRPATH, PROP_FILENAME))
  {
    /* Typed, not chosen with a picker (B10). */
    reduced("path");
  }
  else if (but.type == ButtonType::SearchMenu && type == PROP_STRING) {
    /* A name to pick from a list, typed without the list (B11). */
    reduced("search");
  }
  else if (type == PROP_ENUM && (RNA_property_flag(but.rnaprop) & PROP_ENUM_FLAG)) {
    /* Several choices at once, shown as one (B16). */
    reduced("enum_flag");
  }
  return fate;
}

/** A button the walker left without a decision: layout (nullopt), or dropped and why. */
std::optional<Fate> unhandled_fate(const Button &but)
{
  switch (but.type) {
    case ButtonType::Sepr:
    case ButtonType::SeprLine:
    case ButtonType::SeprSpacer:
    case ButtonType::Roundbox:
    case ButtonType::Decorator:
    case ButtonType::Grip:
    case ButtonType::Scroll:
      return std::nullopt;
    case ButtonType::Label:
      /* An icon alone, or nothing, lays the panel out (B6 is about what labels say). */
      if (but.str.empty()) {
        return std::nullopt;
      }
      return fate_dropped("label", Fate::Counted::Note);
    case ButtonType::Curve:
    case ButtonType::CurveProfile:
      return fate_dropped("curve");
    case ButtonType::Popover:
      return fate_dropped("popover");
    case ButtonType::Image:
    case ButtonType::Histogram:
    case ButtonType::Waveform:
    case ButtonType::Vectorscope:
    case ButtonType::TrackPreview:
      return fate_dropped("display");
    case ButtonType::Progress:
      return fate_dropped("progress");
    case ButtonType::ViewItem:
      /* The blank rows Blender pads a short tree with, see #tree_item. */
      if (dynamic_cast<const AbstractTreeViewItem *>(
              static_cast<const ButtonViewItem &>(but).view_item))
      {
        return std::nullopt;
      }
      return fate_dropped("grid");
    case ButtonType::PreviewTile:
      return fate_dropped("grid");
    case ButtonType::KeyEvent:
    case ButtonType::HotkeyEvent:
      return fate_dropped("key");
    case ButtonType::Extra:
      return fate_dropped("preview");
    default:
      break;
  }
  if (but.menu_create_func) {
    /* A menu Blender builds in C, where the walker does not write it, such as over a list's
     * row (B4). */
    return fate_dropped("c_menu");
  }
  if (but.block_create_func) {
    /* A popup Blender builds in C, such as a colour ramp's or a curve's tools, or a search
     * among a collection's items (B4). */
    return fate_dropped("c_block");
  }
  if (but.rnaprop) {
    /* A pointer to something other than a data-block, chosen by a search, such as an Action
     * Slot (B11); else a kind of property the walker does not write, such as a collection. */
    return fate_dropped(RNA_property_type(but.rnaprop) == PROP_POINTER ? "pointer" :
                                                                         "property_type");
  }
  if (ELEM(but.type, ButtonType::Text, ButtonType::Num, ButtonType::NumSlider, ButtonType::SearchMenu))
  {
    /* A field whose value is not a property, such as a vertex's weight (B14). */
    return fate_dropped("non_rna_field");
  }
  if (!but.optype) {
    /* A button that runs a C callback, such as a curve's zoom or a light link's state. */
    return fate_dropped("callback");
  }
  return fate_dropped("unknown");
}

/** \} */

}  // namespace

/**
 * The contexts of the 3D Viewport's Tool panels for the mode, which Properties' Tool tab draws,
 * as #ED_view3d_buttons_region_layout_ex chooses them.
 */
static Vector<std::string> tool_tab_contexts(const bContext *C)
{
  Vector<std::string> contexts = {CTX_data_mode_string(C)};
  switch (CTX_data_mode_enum(C)) {
    case CTX_MODE_EDIT_MESH: contexts.append(".mesh_edit"); break;
    case CTX_MODE_EDIT_CURVE:
    case CTX_MODE_EDIT_SURFACE: contexts.append(".curve_edit"); break;
    case CTX_MODE_EDIT_CURVES: contexts.append(".curves_edit"); break;
    case CTX_MODE_EDIT_TEXT: contexts.append(".text_edit"); break;
    case CTX_MODE_EDIT_ARMATURE: contexts.append(".armature_edit"); break;
    case CTX_MODE_EDIT_METABALL: contexts.append(".mball_edit"); break;
    case CTX_MODE_EDIT_LATTICE: contexts.append(".lattice_edit"); break;
    case CTX_MODE_EDIT_GREASE_PENCIL: contexts.append(".grease_pencil_edit"); break;
    case CTX_MODE_PAINT_GREASE_PENCIL: contexts.append(".grease_pencil_paint"); break;
    case CTX_MODE_SCULPT_GREASE_PENCIL:
      contexts.extend({".paint_common", ".grease_pencil_sculpt"});
      break;
    case CTX_MODE_WEIGHT_GREASE_PENCIL: contexts.append(".greasepencil_weight"); break;
    case CTX_MODE_VERTEX_GREASE_PENCIL: contexts.append(".greasepencil_vertex"); break;
    case CTX_MODE_EDIT_POINTCLOUD: contexts.append(".pointcloud_edit"); break;
    case CTX_MODE_POSE: contexts.append(".posemode"); break;
    case CTX_MODE_SCULPT: contexts.extend({".paint_common", ".sculpt_mode"}); break;
    case CTX_MODE_PAINT_WEIGHT: contexts.extend({".paint_common", ".weightpaint"}); break;
    case CTX_MODE_PAINT_VERTEX: contexts.extend({".paint_common", ".vertexpaint"}); break;
    case CTX_MODE_PAINT_TEXTURE: contexts.extend({".paint_common", ".imagepaint"}); break;
    case CTX_MODE_PARTICLE: contexts.extend({".paint_common", ".particlemode"}); break;
    case CTX_MODE_OBJECT: contexts.append(".objectmode"); break;
    case CTX_MODE_SCULPT_CURVES: contexts.extend({".paint_common", ".curves_sculpt"}); break;
    default: break;
  }
  return contexts;
}

/**
 * Properties, the tool settings, a viewport popover or Preferences, as \a data asks for them:
 * written with \a writer, or edited as \a request asks. Says why when an edit cannot be made.
 */
static std::string panels_walk(bContext *C,
                               native::PanelsData &data,
                               Writer *writer,
                               const native::EditRequest *request)
{
  const bool execute = request != nullptr;
  /* With nothing to show, a view is its top alone. */
  const auto nothing = [&](const char *error) -> std::string {
    if (writer) {
      writer->builder.top("properties", [](Buffer &buffer, NodeFields & /*fields*/) {
        return protocol::CreateGroup(buffer);
      });
    }
    return execute ? error : "";
  };
  if (!CTX_data_scene(C)) {
    return nothing("There is no scene.");
  }
  /* The panels draw their items' previews, such as materials', which need the scene evaluated:
   * evaluated first, as before Blender's own redraw, since an edit may have just changed it. */
  CTX_data_ensure_evaluated_depsgraph(C);
  if (execute) {
    const std::string &token = request->interaction;
    if (!token.empty() && token == native_property_interaction.closed_token) {
      return "";
    }
    if (token != native_property_interaction.token) {
      finish_property_interaction(C);
    }
    if (request->phase == "cancel" && native_property_interaction.token.empty()) {
      return "";
    }
  }
  const std::string requested_tab = data.tab.empty() ? "OBJECT" : data.tab;
  const bool shading = requested_tab == "SHADING";
  /* The viewport's overlays, a popover beside its shading in Blender's header. */
  const bool overlays = requested_tab == "OVERLAYS";
  const bool header_popover = shading || overlays;
  /* The toolbar's tool settings; the Properties' Tool tab is Blender's own, see #tool_tab. */
  const bool tool_settings = requested_tab == "TOOL" && !data.tool_tab;
  const bool viewport = header_popover || tool_settings;
  /* The Preferences' sections, their tabs named apart from the Properties' ones. */
  const bool preferences = StringRef(requested_tab).startswith(PREFERENCES_TAB_PREFIX);
  std::unique_ptr<DetachedAreaContext> detached_context;
  if (preferences) {
    detached_context = std::make_unique<DetachedAreaContext>(C, SPACE_USERPREF);
  }
  else if (!viewport) {
    detached_context = std::make_unique<PropertiesContext>(C);
  }
  else if (!CTX_wm_view3d(C)) {
    return nothing("There is no 3D Viewport.");
  }
  ARegion *panel_region = viewport ? CTX_wm_region(C) : detached_context->region;
  ARegionType *panel_region_type = viewport ?
      BKE_regiontype_from_id(CTX_wm_area(C)->type, tool_settings ? RGN_TYPE_UI : RGN_TYPE_HEADER) :
      panel_region->runtime->type;
  std::string tab_id = tool_settings ? "TOOL" : shading ? "SHADING" : overlays ? "OVERLAYS" : "OBJECT";
  std::string panel_context;
  Vector<Tab> tabs;
  /* The Properties editor's own space, for its context path. */
  const SpaceProperties *properties_space = nullptr;
  if (preferences) {
    tab_id = preferences_tabs(C, requested_tab, tabs, panel_context);
  }
  else if (!viewport) {
    PropertiesContext &context = *static_cast<PropertiesContext *>(detached_context.get());
    PointerRNA space_ptr = RNA_pointer_create_discrete(nullptr, RNA_SpaceProperties, context.space);
    PropertyRNA *tab_prop = RNA_struct_find_property(&space_ptr, "context");
    const EnumPropertyItem *items;
    int tab_count;
    bool free_tabs;
    RNA_property_enum_items(C, &space_ptr, tab_prop, &items, &tab_count, &free_tabs);
    int selected = BCONTEXT_OBJECT;
    /* A sidebar tab shows as Blender's Tool tab does, the Properties' place for the 3D Viewport's
     * sidebar panels. */
    const bool sidebar_requested = StringRef(requested_tab).startswith(SIDEBAR_TAB_PREFIX);
    if (!RNA_enum_value_from_identifier(
            items, sidebar_requested ? "TOOL" : requested_tab.c_str(), &selected))
    {
      selected = context.space->mainb;
    }
    context.space->mainbuser = context.space->mainb = selected;
    ED_buttons_native_context_prepare(C, context.space);
    properties_space = context.space;
    /* Blender's separators part the tabs into groups, which its tab column draws apart. */
    int group = 0;
    for (int i = 0; i < tab_count; i++) {
      const auto &tab = items[i];
      if (!tab.identifier || !tab.identifier[0]) {
        if (!tabs.is_empty()) {
          group = tabs.last().group + 1;
        }
        continue;
      }
      tabs.append({tab.identifier, tab.name, icon_name(tab.icon), group});
      if (tab.value == context.space->mainb) {
        tab_id = tab.identifier;
      }
    }
    if (free_tabs) {
      MEM_delete(items);
    }
    for (const std::string &category : sidebar_categories()) {
      tabs.append({SIDEBAR_TAB_PREFIX + category, category, "", group + 1});
    }
    if (sidebar_requested &&
        std::any_of(tabs.begin(), tabs.end(), [&](const Tab &tab) { return tab.id == requested_tab; }))
    {
      tab_id = requested_tab;
    }
  }
  /* Native lists scroll themselves, so draw all their items. */
  struct ShowAllListRows {
    ShowAllListRows() { ui_list_show_all_rows = true; }
    ~ShowAllListRows() { ui_list_show_all_rows = false; }
  } show_all_list_rows;
  if (!preferences) {
    panel_context = tab_id;
    std::transform(panel_context.begin(), panel_context.end(), panel_context.begin(), ::tolower);
    if (panel_context == "particles") {
      panel_context = "particle";
    }
  }
  Object *object = preferences ? nullptr : CTX_data_active_object(C);
  std::string identity = tab_id + ":" + std::to_string(object ? object->id.session_uid : 0);
  if (tool_settings) {
    const bToolRef *tool = WM_toolsystem_ref_from_context(C);
    if (!tool) {
      return nothing("The active tool is no longer available.");
    }
    identity += ":" + std::string(tool->idname) + ":" + CTX_data_mode_string(C);
    if (execute && data.identity != identity) {
      return "The active tool has changed.";
    }
  }
  /* The panels' nodes, by the panels' ids; a viewport popover's sub-panels are their outer's. */
  std::map<std::string, NodeId> panel_nodes;
  /* What each panel's node, and the tab, could not show, which their rows say (R6-9). */
  std::map<NodeId, Said> said;
  Said tab_said;
  NodeId top = 0;
  if (writer) {
    data.tab = tab_id;
    data.identity = identity;
    writer->object = object;
    /* Where this walk's notes begin, as each build of the view walks again. */
    census_record(tab_id, "", "Walk", identity, {"walk", "", ""});
    top = writer->builder.top("properties", [&](Buffer &buffer, NodeFields &fields) {
      fields.label = tool_settings ? "Tool Settings" :
                     shading       ? "Viewport Shading" :
                     overlays      ? "Overlays" :
                     preferences   ? "Preferences" :
                                     "Properties";
      /* What it shows: another object's controls start again. */
      fields.property = identity;
      return protocol::CreateGroup(buffer);
    });
    if (!tabs.is_empty()) {
      writer->builder.add(top, "tabs", [&](Buffer &buffer, NodeFields & /*fields*/) {
        std::vector<flatbuffers::Offset<protocol::Option>> options;
        for (const Tab &tab : tabs) {
          options.push_back(protocol::CreateOptionDirect(buffer,
                                                         tab.id.c_str(),
                                                         tab.title.c_str(),
                                                         tab.icon.c_str(),
                                                         nullptr,
                                                         nullptr,
                                                         tab.group,
                                                         tab.external));
        }
        return protocol::CreateChoice(buffer,
                                      buffer.CreateString(tab_id),
                                      buffer.CreateVector(options),
                                      protocol::ChoiceStyle::Tabs);
      });
    }
    /* Blender's context path under the tabs, such as the object and its material: each element
     * its type's icon and its name, as #buttons_panel_context_draw draws them. None on the Tool
     * tab and the sidebar's, which have none in Blender. */
    const Vector<PointerRNA> path = properties_space ?
                                        ED_buttons_native_context_path(properties_space) :
                                        Vector<PointerRNA>();
    if (!path.is_empty()) {
      const NodeId path_node = writer->builder.add(
          top, "path", [&](Buffer &buffer, NodeFields & /*fields*/) {
            return protocol::CreateGroup(buffer, protocol::Layout::Row);
          });
      for (const int i : path.index_range()) {
        PointerRNA element = path[i];
        char buffer_name[128];
        char *name = RNA_struct_name_get_alloc(&element, buffer_name, sizeof(buffer_name), nullptr);
        const std::string label = name ? name : "";
        if (name && name != buffer_name) {
          MEM_delete(name);
        }
        const char *icon = icon_name(RNA_struct_ui_icon(element.type));
        writer->builder.add(
            path_node, "path:" + std::to_string(i), [&](Buffer &buffer, NodeFields &fields) {
              fields.label = label;
              fields.icon = icon;
              return protocol::CreateLabel(buffer);
            });
      }
    }
  }
  const std::set<std::string> *expanded = data.expanded().lookup_ptr(tab_id);
  /* Sub-panels opened or closed, by their ids; others are as their types have them. */
  const Map<std::string, bool> *subpanel_states = data.subpanels().lookup_ptr(tab_id);
  const std::string *requested_panel = execute ? &request->edit->panel : nullptr;
  const std::string *requested_key = execute ? &request->edit->key : nullptr;
  /* Physics' switches, which head their settings' panels, by those panels' ids. */
  std::map<std::string, NodeId> physics_panels;
  int outer_count = 0;
  bool applied = false;
  wmOperatorType *operator_type = nullptr;
  PointerRNA *operator_properties = nullptr;
  std::unique_ptr<bContextStore> operator_context;
  /* Operators chosen from an enum menu run directly, as picking the menu item does. */
  bool operator_exec = false;
  PendingNewID pending_new_id;
  std::set<std::string> open_panels;
  /* Whether each candidate's body is visible, so nested sub-panels follow their parent. */
  std::map<std::string, bool> visible_panels;
  std::map<std::string, std::string> outer_panels;
  struct Candidate {
    PanelType *type;
    Panel *instance;
    std::string id;
    std::string parent;
    bool enabled = true;
  };
  std::vector<Candidate> candidates;
  /* Each stack panel's place among the stack's, which reordering them takes. */
  int stack_index = 0;
  std::set<Panel *> instances;
  /* Properties' Tool tab: the 3D Viewport's Tool panels for the mode, with their sub-panels, as
   * Blender draws them there. */
  const bool tool_tab = !viewport && !preferences && tab_id == "TOOL";
  const bool sidebar_tab = !viewport && !preferences && StringRef(tab_id).startswith(SIDEBAR_TAB_PREFIX);
  const std::string sidebar_category = sidebar_tab ? tab_id.substr(strlen(SIDEBAR_TAB_PREFIX)) : "";
  if (sidebar_tab) {
    /* The sidebar's panels are the 3D Viewport's: they are polled and drawn, and their buttons
     * run, with it as the context's area, as in Blender's own sidebar. Item's Transform panel and
     * add-ons' panels read the view from the context. The Properties context above is restored as
     * it is freed. */
    ScrArea *area = detached_context->previous_area;
    ARegion *region = detached_context->previous_region;
    if (area == nullptr || area->spacetype != SPACE_VIEW3D) {
      area = nullptr;
      region = nullptr;
      if (bScreen *screen = CTX_wm_screen(C)) {
        for (ScrArea &candidate : screen->areabase) {
          if (candidate.spacetype == SPACE_VIEW3D) {
            area = &candidate;
            break;
          }
        }
      }
    }
    if (area && (region == nullptr || region->regiontype != RGN_TYPE_WINDOW)) {
      region = BKE_area_find_region_type(area, RGN_TYPE_WINDOW);
    }
    if (area == nullptr || region == nullptr) {
      return execute ? "There is no 3D Viewport." : "";
    }
    CTX_wm_area_set(C, area);
    CTX_wm_region_set(C, region);
  }
  std::set<std::string> sidebar_panels;
  const Vector<std::string> tool_contexts = tool_tab ? tool_tab_contexts(C) : Vector<std::string>();
  std::set<std::string> tool_panels;
  ARegionType *candidate_region_type = (tool_tab || sidebar_tab) ?
                                           BKE_regiontype_from_id(BKE_spacetype_from_id(SPACE_VIEW3D),
                                                                  RGN_TYPE_UI) :
                                           panel_region_type;
  WorkSpace *workspace = CTX_wm_workspace(C);
  for (PanelType &pt : candidate_region_type->paneltypes) {
    if (sidebar_tab) {
      /* The category's panels and their sub-panels. */
      if (pt.parent_id[0] ? !sidebar_panels.count(pt.parent_id) : sidebar_category != pt.category) {
        continue;
      }
      /* Item's Transform in Edit Mode is fields without properties (the median of what is
       * selected), which are not written here: `bl_ui.native_panels` has them instead. */
      if (STREQ(pt.idname, "VIEW3D_PT_transform")) {
        const Object *edit_object = CTX_data_edit_object(C);
        if (edit_object && !ELEM(edit_object->type, OB_ARMATURE, OB_MBALL)) {
          continue;
        }
      }
      sidebar_panels.insert(pt.idname);
      if (!(pt.flag & PANEL_TYPE_INSTANCED)) {
        candidates.push_back({&pt, nullptr, pt.idname, pt.parent_id});
      }
      continue;
    }
    if (tool_tab) {
      if (pt.parent_id[0] ? !tool_panels.count(pt.parent_id) :
                            !STREQ(pt.category, "Tool") ||
                                (pt.context[0] && !std::any_of(tool_contexts.begin(), tool_contexts.end(),
                                                               [&](const std::string &context) {
                                                                 return context == pt.context;
                                                               })) ||
                                (pt.owner_id[0] && workspace &&
                                 !BKE_workspace_owner_id_check(workspace, pt.owner_id)))
      {
        continue;
      }
      tool_panels.insert(pt.idname);
      if (!(pt.flag & PANEL_TYPE_INSTANCED)) {
        candidates.push_back({&pt, nullptr, pt.idname, pt.parent_id});
      }
      continue;
    }
    /* Besides the active tool, the panels `bl_ui.native_panels` writes for the top bar. */
    if (tool_settings && !STREQ(pt.idname, "VIEW3D_PT_active_tool") &&
        !(StringRef(pt.idname).startswith("VIEW3D_PT_native_") &&
          StringRef(pt.idname).endswith("_settings")))
    {
      continue;
    }
    if (shading && !STREQ(pt.idname, "VIEW3D_PT_shading") &&
        !STREQ(pt.parent_id, "VIEW3D_PT_shading")) {
      continue;
    }
    /* The overlays and those of the mode, each a panel under Blender's Overlays popover. */
    if (overlays && !StringRef(pt.idname).startswith("VIEW3D_PT_overlay")) {
      continue;
    }
    /* The Overlays popover's own panel only names it; the interface shows the overlays' switch
     * there instead. */
    if (overlays && STREQ(pt.idname, "VIEW3D_PT_overlay")) {
      continue;
    }
    if (!(pt.flag & PANEL_TYPE_INSTANCED)) {
      candidates.push_back({&pt, nullptr, pt.idname, header_popover ? "" : pt.parent_id});
    }
  }
  /* An outer panel's open: as an interface left it, or else only the first. */
  const auto is_open = [&](const std::string &id) {
    return expanded ? expanded->count(id) != 0 : viewport || preferences || outer_count == 0;
  };
  /* A physics' switch heads the panel of its settings, so the switches come first. */
  std::stable_partition(candidates.begin(), candidates.end(), [](const Candidate &candidate) {
    return candidate.id == "PHYSICS_PT_add";
  });
  for (size_t candidate_index = 0; candidate_index < candidates.size(); candidate_index++) {
    const Candidate candidate = candidates[candidate_index];
    PanelType &pt = *candidate.type;
    /* Blender draws a sub-panel with its parent whatever its context, and a top-level panel that
     * names none on every tab (#panel_add_check): those the test of the context below leaves out
     * are said, at their parent's foot or the tab's (B21). */
    if (STREQ(pt.idname, "PROPERTIES_PT_context")) {
      /* Blender's context path, which the view sends as its `path` above. */
      if (writer) {
        census_record(tab_id, "", "Panel", pt.idname, fate_consumed("context_path"));
      }
      continue;
    }
    if (writer && pt.draw && !viewport && !tool_tab && !sidebar_tab && !candidate.instance &&
        panel_context != pt.context && !(preferences && panel_context.empty()) &&
        (candidate.parent.empty() ? !pt.context[0] : panel_nodes.count(candidate.parent) != 0) &&
        panel_poll(C, &pt))
    {
      const Fate fate = fate_dropped("panel_context",
                                     candidate.parent.empty() ? Fate::Counted::Panel :
                                                                Fate::Counted::Section);
      census_record(tab_id, candidate.parent, "Panel", pt.idname, fate);
      (candidate.parent.empty() ? tab_said : said[panel_nodes.at(candidate.parent)])
          .add(fate.counted);
      continue;
    }
    if (!pt.draw ||
        (!viewport && !tool_tab && !sidebar_tab && !candidate.instance && panel_context != pt.context) ||
        (preferences && panel_context.empty()) ||
        /* Header-less Properties panels hold data-block pickers and slots (e.g. a material's
         * context panel); viewport ones are decorative. */
        ((pt.flag & PANEL_TYPE_NO_HEADER) && !pt.label[0] && viewport) ||
        /* Objects are picked in the viewport and hierarchy, not by browsing them by name. */
        STREQ(pt.idname, "OBJECT_PT_context_object") || !panel_poll(C, &pt)) {
      continue;
    }
    const std::string outer = candidate.parent.empty() ? candidate.id : outer_panels[candidate.parent];
    outer_panels[candidate.id] = outer;
    const bool is_outer = outer == candidate.id;
    if (!is_outer && outer.empty()) {
      continue;
    }
    /* Properties tabs give every sub-panel its own disclosure; viewport popovers keep them
     * flattened into the outer panel. */
    const bool collapsible_subpanel = !is_outer && !viewport;
    if (collapsible_subpanel && !execute && !visible_panels[candidate.parent]) {
      continue;
    }
    bool subpanel_open = !(pt.flag & PANEL_TYPE_DEFAULT_CLOSED);
    if (collapsible_subpanel && subpanel_states) {
      subpanel_open = subpanel_states->lookup_default(candidate.id, subpanel_open);
    }
    /* Header-less panels (e.g. Add Modifier above the stack) cannot be collapsed. */
    const bool header_hidden = is_outer && (pt.flag & PANEL_TYPE_NO_HEADER);
    const bool open = header_hidden ? true :
                      is_outer      ? is_open(candidate.id) :
                                      open_panels.count(outer) != 0 &&
                                     (!collapsible_subpanel || subpanel_open);
    if (open && is_outer) {
      open_panels.insert(outer);
    }
    visible_panels[candidate.id] = open;
    std::string panel_title = pt.label;
    bool panel_active = false;
    if (candidate.instance && !pt.parent) {
      if (PointerRNA *data = panel_custom_data_get(candidate.instance)) {
        char *name = RNA_struct_name_get_alloc(data, nullptr, 0, nullptr);
        if (name) {
          panel_title = name;
          MEM_delete(name);
        }
        /* Modifiers (is_active) and constraints (active) mark the stack's active item. */
        for (const char *identifier : {"is_active", "active"}) {
          PropertyRNA *prop = RNA_struct_find_property(data, identifier);
          if (prop && RNA_property_type(prop) == PROP_BOOLEAN) {
            panel_active = RNA_property_boolean_get(data, prop);
            break;
          }
        }
      }
    }
    if (is_outer) {
      outer_count++;
    }
    else if (writer && !panel_nodes.count(collapsible_subpanel ? candidate.parent : outer)) {
      /* Its panel was left out. */
      continue;
    }
    const bool target_panel = requested_panel && *requested_panel == candidate.id;
    if (execute && target_panel && candidate.instance && !pt.parent && pt.reorder &&
        request->action == "reorder")
    {
      /* Dragged to another place in the stack, as dragging its header in Blender does. */
      const int64_t to = request->to;
      if (to >= 0) {
        pt.reorder(C, candidate.instance, int(to));
        applied = true;
      }
      break;
    }
    const bool instance_container = !candidate.instance &&
        ELEM(tab_id, "MODIFIER", "CONSTRAINT", "BONE_CONSTRAINT", "SHADERFX");
    if ((!execute && !open && !is_outer && !instance_container && !collapsible_subpanel) ||
        (execute && !target_panel && !instance_container && !header_popover)) {
      continue;
    }
    Block *block = block_begin(C, nullptr, "native_properties", EmbossType::Emboss);
    Panel *panel = candidate.instance ? candidate.instance : BKE_panel_new(&pt);
    block->panel = panel;
    Layout &layout = block_layout(block, LayoutDirection::Vertical, LayoutType::Panel,
                                   0, 0, 320, 20, 0, style_get_dpi());
    panel->layout = &layout;
    layout.operator_context_set(wm::OpCallContext::ExecDefault);
    /* The sections (`layout.panel`) this draw makes, as Blender's own draw starts them afresh
     * (`area.cc`); a stack's panel keeps those of its last draw otherwise. */
    panel->runtime->layout_panels.clear();
    /* Its sections as the view left them, where their state is the panel's own (PANEL-3): the
     * panel is drawn anew for every walk, so the view keeps them. */
    if (subpanel_states) {
      const std::string prefix = "section:" + candidate.id + ":";
      for (const auto item : subpanel_states->items()) {
        if (StringRef(item.key).startswith(prefix)) {
          LayoutPanelState *state = BKE_panel_layout_panel_state_ensure(
              panel, StringRef(item.key).drop_prefix(prefix.size()), !item.value);
          SET_FLAG_FROM_TEST(state->flag, item.value, LAYOUT_PANEL_STATE_FLAG_OPEN);
        }
      }
    }
    if (pt.draw_header) {
      pt.draw_header(C, panel);
    }
    std::set<Button *> header_buttons;
    for (const auto &button : block->buttons) {
      header_buttons.insert(button.get());
    }
    if (open || execute || instance_container) {
      /* Body activation must never disable its own enable switch. */
      Layout &body = block_layout(block, LayoutDirection::Vertical, LayoutType::Panel,
                                  0, 0, 320, 20, 0, style_get_dpi());
      body.operator_context_set(wm::OpCallContext::ExecDefault);
      panel->layout = &body;
      pt.draw(C, panel);
      if (shading && candidate.id == "VIEW3D_PT_shading") {
        PointerRNA ptr = RNA_pointer_create_discrete(
            &CTX_wm_screen(C)->id, RNA_View3DShading, &CTX_wm_view3d(C)->shading);
        body.prop(&ptr, "type", eUI_Item_Flag(0), "Shading", ICON_NONE);
      }
    }
    /* What became of each button (the census, R6-9): the first decision taken for it stands;
     * those without one are judged by #unhandled_fate once the panel is written. */
    std::map<const Button *, Fate> fates;
    const auto decide = [&](const Button *but, Fate fate) {
      if (writer) {
        fates.emplace(but, std::move(fate));
      }
    };
    const auto pairs = property_pairs(*block);
    std::map<Button *, std::string> tool_labels;
    std::map<PropertyRNA *, std::string> layout_names;
    {
      /* Split property layouts put the authored caption in a preceding label. An enum
       * button's own text is its selected value, not the property caption. */
      Button *previous = nullptr;
      for (const auto &button : block->buttons) {
        if (button->rnaprop) {
          std::string caption;
          if (previous && previous->type == ButtonType::Label &&
              (previous->drawflag & BUT_TEXT_RIGHT)) {
            caption = previous->str;
            decide(previous, fate_consumed("caption"));
          }
          else if (RNA_property_type(button->rnaprop) != PROP_ENUM &&
                   !RNA_property_array_check(button->rnaprop) && !button->str.empty()) {
            caption = button->str;
          }
          while (!caption.empty() && ELEM(caption.back(), ':', ' ')) {
            caption.pop_back();
          }
          if (!caption.empty()) {
            if (!RNA_property_array_check(button->rnaprop)) {
              /* A row's heading, such as Axis, names the row: a toggle in it keeps its own
               * text, such as X. */
              const bool own = button->type == ButtonType::Toggle && !button->str.empty();
              tool_labels[button.get()] = own ? button->str : caption;
            }
            /* A vector's first row carries the caption ("Offset X"); later rows only axes. */
            if (!layout_names.count(button->rnaprop) && button->rnaindex <= 0) {
              std::string name = caption;
              if (RNA_property_array_check(button->rnaprop) && name.size() > 2 &&
                  name[name.size() - 2] == ' ' && strchr("XYZW", name.back())) {
                name.resize(name.size() - 2);
              }
              layout_names[button->rnaprop] = name;
            }
          }
        }
        previous = button.get();
      }
      /* A split layout's captions stand apart from their properties, in a column of their own,
       * for a vector's rows ("Location X", "Y", "Z") and a column's heading: each property is
       * written with its own name (B20 is the difference). */
      for (const auto &button : block->buttons) {
        if (button->type == ButtonType::Label && (button->drawflag & BUT_TEXT_RIGHT)) {
          decide(button.get(), fate_consumed("caption"));
        }
      }
    }
    block_end(C, block);
    /* A heading naming the property after it ("Location:"), and a name beside a checkbox drawn
     * without one, on its line, as Preferences' Copy on Duplicate draws them. */
    for (int64_t i = 0; writer && i < block->buttons.size(); i++) {
      const Button &label = *block->buttons[i];
      if (label.type != ButtonType::Label || label.str.empty()) {
        continue;
      }
      std::string text = label.str;
      while (!text.empty() && ELEM(text.back(), ':', ' ')) {
        text.pop_back();
      }
      const Button *next = i + 1 < block->buttons.size() ? block->buttons[i + 1].get() : nullptr;
      const Button *before = i > 0 ? block->buttons[i - 1].get() : nullptr;
      const float line = BLI_rctf_cent_y(&label.rect);
      if ((next && next->rnaprop && text == RNA_property_ui_name(next->rnaprop)) ||
          (before && before->rnaprop && before->str.empty() &&
           RNA_property_type(before->rnaprop) == PROP_BOOLEAN && line >= before->rect.ymin &&
           line <= before->rect.ymax))
      {
        decide(&label, fate_consumed("caption"));
      }
    }
    /* Blender's sections (`layout.panel`, B3), each a sub-panel of its panel or of the section
     * it is in: its header's title and switch, its open state, and the rows of its body. A closed
     * one draws its header alone. Its open state is a state of the panel, which the view keeps
     * (see above), or a property of what it belongs to, such as a modifier's, which opening it
     * sets as Blender's click on the header does (PANEL-3). */
    struct Section {
      std::string id;
      std::string title;
      bool open = false;
      bool property = false;
      PointerRNA owner;
      std::string prop;
      float header_min = 0, header_max = 0;
      /* Its body, while open. */
      float body_min = 1, body_max = 0;
      int parent = -1;
      std::optional<NodeId> node;
    };
    std::vector<Section> sections;
    const bool section_request = execute && target_panel &&
                                 StringRef(request->action).startswith("section_");
    if (writer || section_request) {
      const LayoutPanels &layout_panels = panel->runtime->layout_panels;
      for (const LayoutPanelHeader &header : layout_panels.headers) {
        Section section;
        section.owner = header.open_owner_ptr;
        section.prop = header.open_prop_name;
        if (!section.owner.data || !RNA_struct_find_property(&section.owner, section.prop.c_str()))
        {
          continue;
        }
        section.open = RNA_boolean_get(&section.owner, section.prop.c_str());
        section.header_min = header.start_y;
        section.header_max = header.end_y;
        std::string name;
        if (RNA_struct_is_a(section.owner.type, RNA_LayoutPanelState)) {
          const char *idname = static_cast<const LayoutPanelState *>(section.owner.data)->idname;
          name = idname ? idname : "";
        }
        else {
          section.property = true;
          name = RNA_path_from_ID_to_struct(&section.owner).value_or("") + "." + section.prop;
        }
        section.id = "section:" + candidate.id + ":" + name;
        for (const auto &button : block->buttons) {
          const float y = BLI_rctf_cent_y(&button->rect);
          if (y < header.start_y || y > header.end_y || button->type != ButtonType::Label) {
            continue;
          }
          if (section.title.empty() && !button->str.empty()) {
            section.title = button->str;
          }
          /* Its header's arrow and title, which the sub-panel's header shows. */
          decide(button.get(), fate_consumed("section"));
        }
        if (section.title.empty()) {
          /* A header with a switch names it by the switch's text, which the switch shows. */
          for (const auto &button : block->buttons) {
            const float y = BLI_rctf_cent_y(&button->rect);
            if (y >= header.start_y && y <= header.end_y && !button->str.empty()) {
              section.title = button->str;
              break;
            }
          }
        }
        if (section.open) {
          /* Its body: the one just under its header. */
          const float tolerance = 0.5f * UI_UNIT_Y;
          for (const LayoutPanelBody &body : layout_panels.bodies) {
            if (std::abs(body.end_y - header.start_y) <= tolerance) {
              section.body_min = body.start_y;
              section.body_max = body.end_y;
              break;
            }
          }
        }
        sections.push_back(std::move(section));
      }
      /* Each in the innermost open section whose body holds its header. */
      for (Section &section : sections) {
        const float y = 0.5f * (section.header_min + section.header_max);
        for (int i = 0; i < int(sections.size()); i++) {
          const Section &outer = sections[i];
          if (&outer != &section && y >= outer.body_min && y <= outer.body_max &&
              (section.parent < 0 || outer.body_max - outer.body_min <
                                         sections[section.parent].body_max -
                                             sections[section.parent].body_min))
          {
            section.parent = i;
          }
        }
      }
    }
    /* The section a button is in, by its header or by its body, innermost first; and whether it
     * is in the section's header. */
    const auto section_of = [&](const Button &but, bool *r_header = nullptr) -> int {
      const float y = BLI_rctf_cent_y(&but.rect);
      int found = -1;
      for (int i = 0; i < int(sections.size()); i++) {
        const Section &section = sections[i];
        if (y >= section.header_min && y <= section.header_max) {
          if (r_header) {
            *r_header = true;
          }
          return i;
        }
        if (y >= section.body_min && y <= section.body_max &&
            (found < 0 ||
             section.body_max - section.body_min < sections[found].body_max - sections[found].body_min))
        {
          found = i;
        }
      }
      return found;
    };
    if (section_request) {
      /* Opened or closed by its property (#PanelState::section_property). */
      for (Section &section : sections) {
        if (section.id == *requested_key && section.property) {
          RNA_boolean_set(&section.owner, section.prop.c_str(), request->action == "section_open");
          RNA_property_update(
              C, &section.owner, RNA_struct_find_property(&section.owner, section.prop.c_str()));
          applied = true;
        }
      }
    }
    for (const auto &button : block->buttons) {
      /* Icon templates keep their RNA target in callback data, not in the button itself. */
      if (template_icon_view_property_get(*button, button->rnapoin, button->rnaprop)) {
        button->rnaindex = -1;
      }
    }
    if (header_popover) {
      for (const auto &button : block->buttons) {
        if (!candidate.enabled) { button->flag |= BUT_DISABLED; }
        PanelType *nested = button_paneltype_get(button.get());
        if (nested) {
          /* Its panel is drawn into the popover, see below. */
          decide(button.get(), fate_consumed("popover_flattened"));
        }
        if (nested && std::none_of(candidates.begin(), candidates.end(), [&](const Candidate &item) {
              return item.id == nested->idname;
            })) {
          candidates.push_back({nested, nullptr, nested->idname, "",
                                !(button->flag & (BUT_DISABLED | BUT_INACTIVE))});
        }
      }
    }
    /* Only replace locks which have a corresponding value in this actual panel layout. */
    std::map<std::string, std::pair<Button *, int>> field_locks;
    std::set<std::string> attached_locks;
    std::map<std::string, Button *> field_modes;
    std::set<std::string> attached_modes;
    for (const auto &value_button : block->buttons) {
      Button &value = *value_button;
      if (!value.rnaprop || !value.rnapoin.data || (value.flag & UI_HIDDEN) ||
          !ELEM(RNA_property_type(value.rnaprop), PROP_FLOAT, PROP_INT, PROP_STRING) ||
          is_color(&value.rnapoin, value.rnaprop)) {
        continue;
      }
      const std::string identifier = RNA_property_identifier(value.rnaprop);
      const int length = RNA_property_array_length(&value.rnapoin, value.rnaprop);
      const int begin = length ? std::max(0, value.rnaindex) : -1;
      const int end = length && value.rnaindex < 0 ? std::min(length, 16) : begin + 1;
      for (int index = begin; index < end; index++) {
        if (ELEM(identifier, "rotation_euler", "rotation_quaternion", "rotation_axis_angle")) {
          for (const auto &mode_button : block->buttons) {
            Button &mode = *mode_button;
            if (mode.rnaprop && mode.rnapoin.data == value.rnapoin.data &&
                mode.rnapoin.type == value.rnapoin.type && !(mode.flag & UI_HIDDEN) &&
                RNA_property_type(mode.rnaprop) == PROP_ENUM &&
                std::string(RNA_property_identifier(mode.rnaprop)) == "rotation_mode") {
              field_modes[property_key(value, index)] = &mode;
              attached_modes.insert(property_key(mode, -1));
              break;
            }
          }
        }
        std::string lock_name = "lock_" + identifier;
        int lock_index = index;
        if (identifier == "rotation_euler") {
          lock_name = "lock_rotation";
        }
        else if (ELEM(identifier, "rotation_quaternion", "rotation_axis_angle")) {
          lock_name = index == 0 ? "lock_rotation_w" : "lock_rotation";
          lock_index = index - 1;
        }
        for (const auto &lock_button : block->buttons) {
          Button &lock = *lock_button;
          if (!lock.rnaprop || lock.rnapoin.data != value.rnapoin.data ||
              lock.rnapoin.type != value.rnapoin.type || (lock.flag & UI_HIDDEN) ||
              RNA_property_type(lock.rnaprop) != PROP_BOOLEAN ||
              lock_name != RNA_property_identifier(lock.rnaprop)) {
            continue;
          }
          const int lock_length = RNA_property_array_length(&lock.rnapoin, lock.rnaprop);
          const int component = lock_length ? lock_index : -1;
          if ((lock_length && (component < 0 || component >= lock_length)) ||
              (lock_length && lock.rnaindex >= 0 && lock.rnaindex != component)) {
            continue;
          }
          field_locks[property_key(value, index)] = {&lock, component};
          attached_locks.insert(property_key(lock, component));
          break;
        }
      }
    }
    /* Buttons shown as part of one native control (an ID picker, a list row), not alone. */
    std::set<const Button *> combined;
    std::map<const Button *, std::vector<const Button *>> row_items;
    if (preferences) {
      for (const auto &button : block->buttons) {
        if (button->rnaprop && preferences_hidden(button->rnapoin, button->rnaprop)) {
          decide(button.get(), {"hidden", "", "preferences"});
          combined.insert(button.get());
        }
        /* Paths are typed: Blender's file browser has no place in the native interface. */
        else if (button->optype && ELEM(StringRef(button->optype->idname),
                                        "BUTTONS_OT_file_browse",
                                        "BUTTONS_OT_directory_browse"))
        {
          decide(button.get(), fate_dropped("path_button"));
          combined.insert(button.get());
        }
      }
    }
    {
      std::set<ID *> template_ids;
      for (const auto &button : block->buttons) {
        PointerRNA template_ptr;
        PropertyRNA *template_prop;
        int event;
        if (template_id_property_get(*button, template_ptr, template_prop, event)) {
          if (event != UI_ID_BROWSE) {
            combined.insert(button.get());
            /* The parts the picker shows (#Writer::picker), and those it does not: Open but for a
             * font, which the system's font picker opens (B10); making local, overriding. */
            const bool font = RNA_type_to_ID_code(
                                  RNA_property_pointer_type(&template_ptr, template_prop)) == ID_VF;
            decide(button.get(),
                   event == UI_ID_OPEN && !font                      ? fate_dropped("id_open") :
                   ELEM(event, UI_ID_LOCAL, UI_ID_OVERRIDE, UI_ID_PIN) ? fate_dropped("id_part") :
                                                                       fate_consumed("template"));
          }
          if (ID *id = RNA_property_pointer_get(&template_ptr, template_prop).owner_id) {
            template_ids.insert(id);
          }
        }
      }
      for (const auto &button : block->buttons) {
        const Button &but = *button;
        if (!template_ids.empty() &&
            ((but.rnaprop && template_ids.count(but.rnapoin.owner_id) &&
              but.rnapoin.data == but.rnapoin.owner_id &&
              ELEM(StringRef(RNA_property_identifier(but.rnaprop)), "name", "use_fake_user")) ||
             (but.optype && STREQ(but.optype->idname, "ASSET_OT_clear_single"))))
        {
          decide(&but, fate_consumed("template"));
          combined.insert(&but);
        }
        if (but.type != ButtonType::ListRow &&
            !(but.type == ButtonType::ViewItem &&
              tree_item(static_cast<const ButtonViewItem &>(but))))
        {
          continue;
        }
        /* An item's buttons are drawn over its row. */
        for (const auto &item : block->buttons) {
          if (item.get() != &but &&
              !ELEM(item->type, ButtonType::ListRow, ButtonType::ListBox, ButtonType::ViewItem) &&
              BLI_rctf_isect_pt(&but.rect, BLI_rctf_cent_x(&item->rect), BLI_rctf_cent_y(&item->rect)))
          {
            /* As #Writer::list_row takes them: its name, and the values beside it; any other
             * button over a row, such as an operator's or a callback's, is not on it (B18). */
            const PropertyType item_type = item->rnaprop ? RNA_property_type(item->rnaprop) :
                                                           PROP_BOOLEAN;
            decide(item.get(),
                   (item->flag & UI_HIDDEN) ?
                       Fate{"hidden", "", "row_hidden"} :
                   item->rnaprop && item->rnapoin.data && !RNA_property_array_check(item->rnaprop) &&
                           ELEM(item_type, PROP_BOOLEAN, PROP_INT, PROP_FLOAT, PROP_ENUM) ?
                       fate_projected("RowControl") :
                   (item->rnaprop && item_type == PROP_STRING) ||
                           (ELEM(item->type, ButtonType::Label, ButtonType::Text) && !item->rnaprop) ?
                       fate_consumed("row_name") :
                   item->type == ButtonType::Label || ELEM(item->type, ButtonType::Sepr,
                                                           ButtonType::SeprSpacer,
                                                           ButtonType::Decorator) ?
                       fate_consumed("row_layout") :
                       fate_dropped("row_button"));
            combined.insert(item.get());
            row_items[&but].push_back(item.get());
          }
        }
      }
    }
    /* The column beside each list (#Layout::template_list's side buttons), by list box. */
    std::map<const Button *, ListSide> list_sides;
    auto find_side = [&](const rctf &box, ListSide &side) {
      for (const auto &button : block->buttons) {
        Button &but = *button;
        if (but.rect.xmin < box.xmax - 2 || but.rect.ymax > box.ymax + 2 ||
            but.rect.ymin < box.ymin - 8 * UI_UNIT_Y || (but.flag & UI_HIDDEN))
        {
          continue;
        }
        MenuType *menu = button_menutype_get(&but);
        if (!menu && but.optype && but.opptr && STREQ(but.optype->idname, "WM_OT_call_menu")) {
          menu = WM_menutype_find(RNA_string_get(but.opptr, "name").c_str(), true);
        }
        if (menu) {
          side.menu = menu;
        }
        else if (!but.optype) {
          continue;
        }
        else if (button_icon(&but) == ICON_ADD && !side.add) {
          side.add = &but;
        }
        else if (button_icon(&but) == ICON_REMOVE && !side.remove) {
          side.remove = &but;
        }
        else if (button_icon(&but) == ICON_TRIA_UP && !side.up) {
          side.up = &but;
        }
        else if (button_icon(&but) == ICON_TRIA_DOWN && !side.down) {
          side.down = &but;
        }
        else {
          side.extras.push_back(&but);
        }
        /* The list's own Add, Remove, arrows and menu; the rest stand beside it as buttons. */
        decide(&but, std::find(side.extras.begin(), side.extras.end(), &but) != side.extras.end() ?
                         fate_projected("Button") :
                         fate_consumed("list_side"));
        combined.insert(&but);
      }
    };
    for (const auto &box : block->buttons) {
      if (box->type == ButtonType::ListBox) {
        find_side(box->rect, list_sides[box.get()]);
      }
    }
    /* Tree views (shape keys, bone collections, layers), by view, in drawing order. */
    std::vector<TreeRows> trees;
    {
      std::map<const AbstractView *, size_t> tree_index;
      for (const auto &button : block->buttons) {
        if (button->type != ButtonType::ViewItem ||
            !tree_item(static_cast<const ButtonViewItem &>(*button)))
        {
          continue;
        }
        const auto *item = static_cast<const ButtonViewItem *>(button.get());
        const auto [found, added] = tree_index.try_emplace(&item->view_item->get_view(),
                                                           trees.size());
        if (added) {
          trees.emplace_back();
          trees.back().rect = button->rect;
        }
        TreeRows &tree = trees[found->second];
        tree.items.push_back(item);
        BLI_rctf_union(&tree.rect, &button->rect);
      }
      for (TreeRows &tree : trees) {
        /* A tree's rows sit inside its box, below the top of the buttons beside it. */
        rctf box = tree.rect;
        box.ymax += 0.75f * UI_UNIT_Y;
        find_side(box, tree.side);
      }
    }
    /* A list with nothing in it yet, such as shape keys before the first: Blender draws no rows,
     * only its column of buttons, an Add above a Remove. Shown as an empty list with its buttons,
     * as lists with items are. */
    std::vector<std::pair<const Button *, ListSide>> empty_lists;
    /* Only where the panel shows no list at all: a list's own column is its list's. */
    for (int64_t i = 0; trees.empty() && list_sides.empty() && i + 1 < block->buttons.size(); i++) {
      Button &add = *block->buttons[i];
      const Button &remove = *block->buttons[i + 1];
      if (!add.optype || !remove.optype || button_icon(&add) != ICON_ADD ||
          button_icon(&remove) != ICON_REMOVE || !add.str.empty() || combined.count(&add) ||
          (add.flag & UI_HIDDEN) || std::abs(add.rect.xmin - remove.rect.xmin) > 2)
      {
        continue;
      }
      ListSide side;
      for (const auto &button : block->buttons) {
        Button &but = *button;
        /* Only the column it heads, as far down as a list's buttons go. */
        if (std::abs(but.rect.xmin - add.rect.xmin) > 2 || but.rect.ymax > add.rect.ymax + 2 ||
            but.rect.ymin < add.rect.ymin - 6 * UI_UNIT_Y || (but.flag & UI_HIDDEN))
        {
          continue;
        }
        MenuType *menu = button_menutype_get(&but);
        if (menu) {
          side.menu = menu;
        }
        else if (!but.optype) {
          continue;
        }
        else if (button_icon(&but) == ICON_ADD && !side.add) {
          side.add = &but;
        }
        else if (button_icon(&but) == ICON_REMOVE && !side.remove) {
          side.remove = &but;
        }
        else {
          side.extras.push_back(&but);
        }
        decide(&but, std::find(side.extras.begin(), side.extras.end(), &but) != side.extras.end() ?
                         fate_projected("Button") :
                         fate_consumed("list_side"));
        combined.insert(&but);
      }
      empty_lists.emplace_back(&add, side);
    }
    /* A name with buttons beside it that have no text of their own, such as each of a bone's
     * collections with its visibility and solo toggles: one row, named by its label. */
    std::map<const Button *, std::vector<const Button *>> named_rows;
    for (int64_t i = 0; i < block->buttons.size(); i++) {
      const Button &label = *block->buttons[i];
      if (label.type != ButtonType::Label || label.str.empty() || (label.drawflag & BUT_TEXT_RIGHT) ||
          (label.flag & UI_HIDDEN) || combined.count(&label))
      {
        continue;
      }
      const float line = BLI_rctf_cent_y(&label.rect);
      std::vector<const Button *> items;
      bool toggles = false;
      for (int64_t j = i + 1; j < block->buttons.size(); j++) {
        const Button &item = *block->buttons[j];
        if (item.rect.ymin > line || item.rect.ymax < line || !item.str.empty() ||
            button_icon(&item) == ICON_NONE || combined.count(&item) || item.type == ButtonType::Row)
        {
          break;
        }
        const bool toggle = item.rnaprop && item.rnapoin.data &&
                            RNA_property_type(item.rnaprop) == PROP_BOOLEAN &&
                            !RNA_property_array_check(item.rnaprop);
        if (!toggle && !item.optype) {
          break;
        }
        toggles |= toggle;
        items.push_back(&item);
      }
      if (toggles) {
        named_rows[&label] = items;
        combined.insert(items.begin(), items.end());
        decide(&label, fate_projected("Row"));
        for (const Button *item : items) {
          decide(item, fate_projected(item->optype ? "Button" : "Toggle"));
        }
      }
    }
    auto tree_key = [&](const size_t index) {
      return "tree:" + candidate.id + ":" + std::to_string(index);
    };
    auto list_side_for = [&](const Button &row) -> ListSide * {
      for (auto &[box, side] : list_sides) {
        if (box->rnapoin.data == row.rnapoin.data && box->rnaprop == row.rnaprop) {
          return &side;
        }
      }
      return nullptr;
    };
    /* Where the panel's controls go, see below. */
    NodeId node = top;
    /* A list from its first row, or its box while it has none. */
    const auto write_list = [&](const Button &first) {
      Vector<ListRow> rows;
      for (const auto &button : block->buttons) {
        if (button->type == ButtonType::ListRow && button->rnapoin.data == first.rnapoin.data &&
            button->rnaprop == first.rnaprop)
        {
          const auto items = row_items.find(button.get());
          rows.append({int64_t(button->hardmax),
                       0,
                       false,
                       items == row_items.end() ? nullptr : &items->second});
        }
      }
      PointerRNA active_ptr = first.rnapoin;
      writer->list(node,
                   property_key(first, -1),
                   list_side_for(first),
                   true,
                   RNA_property_int_get(&active_ptr, first.rnaprop),
                   rows,
                   RNA_property_editable(&active_ptr, first.rnaprop));
    };
    /* A tree as a list: its items in order, indented by depth. */
    const auto write_tree = [&](const TreeRows &tree, const std::string &key) {
      Vector<ListRow> rows;
      int64_t active = -1;
      bool nested = false;
      for (const int64_t index : IndexRange(tree.items.size())) {
        const ButtonViewItem *button = tree.items[index];
        const AbstractTreeViewItem *item = tree_item(*button);
        const AbstractViewItem &view_item = *item;
        /* What the item says should be active (a shape key: the object's active key), rather
         * than the view's own flag, which only follows it as Blender's editor redraws. */
        if (view_item.should_be_active().value_or(item->is_active())) {
          active = index;
        }
        const auto items = row_items.find(button);
        rows.append({index,
                     item->count_parents(),
                     item->supports_renaming(),
                     items == row_items.end() ? nullptr : &items->second,
                     view_item.get_rename_string()});
        nested |= item->count_parents() > 0;
      }
      writer->list(node, key, &tree.side, !nested, active, rows);
    };
    const bool physics_toggles = candidate.id == "PHYSICS_PT_add";
    /* Aligned rows of toggle buttons (e.g. Mirror X Y Z) are shown as one group, captioned by a
     * label just before them. */
    std::map<const Button *, std::pair<int, std::string>> toggle_groups;
    {
      const Button *previous = nullptr;
      short group = 0;
      std::string caption;
      for (const auto &button : block->buttons) {
        const Button &but = *button;
        if (but.type == ButtonType::Toggle && but.alignnr && but.rnaprop &&
            RNA_property_type(but.rnaprop) == PROP_BOOLEAN)
        {
          if (but.alignnr != group) {
            group = but.alignnr;
            caption = previous && previous->type == ButtonType::Label ? previous->str : "";
            if (!caption.empty()) {
              decide(previous, fate_consumed("caption"));
            }
          }
          toggle_groups[&but] = {group, caption};
        }
        previous = &but;
      }
    }
    std::set<const PropertyRNA *> shared_properties;
    {
      std::map<const PropertyRNA *, const void *> owners;
      for (const auto &button : block->buttons) {
        if (!button->rnaprop || !button->rnapoin.data || combined.count(button.get())) {
          continue;
        }
        const auto [found, added] = owners.try_emplace(button->rnaprop, button->rnapoin.data);
        if (!added && found->second != button->rnapoin.data) {
          shared_properties.insert(button->rnaprop);
        }
      }
    }
    /* The other selected items with each property, and the panel's node, left out with its
     * sub-panels when they lack all it shows, such as a modifier only the active item has. The
     * physics' switches head panels of their own, see below. */
    std::map<const Button *, SelectedOthers> others_of;
    bool dropped = false;
    if (writer) {
      writer->panel = candidate.id;
    }
    if (writer && is_outer && !physics_toggles) {
      int missing = 0, common = 0;
      for (const auto &button : block->buttons) {
        Button &but = *button;
        if (!combined.count(&but) && !named_rows.count(&but) && value_button(but)) {
          const SelectedOthers &others = others_of[&but] = selected_others(C, but);
          (others.missing ? missing : common)++;
        }
      }
      dropped = missing && !common;
      if (dropped) {
        /* Shown when it is the only item selected (B2). */
        const Fate fate = fate_dropped("selection", Fate::Counted::Panel);
        census_record(tab_id, "", "Panel", candidate.id, fate);
        tab_said.add(fate.counted);
      }
    }
    if (writer && !physics_toggles && !dropped) {
      const auto physics = physics_panels.find(candidate.id);
      if (is_outer && physics != physics_panels.end()) {
        node = physics->second;
      }
      else if (is_outer || collapsible_subpanel) {
        /* A stack's panel by the icon of what it is, such as a modifier's type. */
        const PointerRNA *instance_data = is_outer && candidate.instance ?
                                              panel_custom_data_get(candidate.instance) :
                                              nullptr;
        const int instance_icon = instance_data && instance_data->type ?
                                      RNA_struct_ui_icon(instance_data->type) :
                                      ICON_NONE;
        node = writer->panel_node(is_outer ? top : panel_nodes.at(candidate.parent),
                                  candidate.id,
                                  is_outer,
                                  panel_title,
                                  open,
                                  header_hidden,
                                  panel_active,
                                  is_outer && candidate.instance && pt.reorder ? stack_index++ :
                                                                                 -1,
                                  true,
                                  instance_icon == ICON_NONE ? "" : icon_name(instance_icon));
      }
      else {
        node = panel_nodes.at(outer);
      }
      panel_nodes[candidate.id] = node;
    }
    std::set<std::string> seen;
    std::map<std::string, int> occurrences;
    int named_row_count = 0;
    /* Menus Blender builds in C, by their order in the panel, which the menu walker finds them
     * by when it draws the panel again (PANEL-4). */
    std::map<const Button *, int> c_menus;
    for (const auto &button : block->buttons) {
      /* An enum's dropdown has a menu function too, which the property's choice stands for. */
      if (button->menu_create_func && !button->rnaprop && !button->optype &&
          !button_menutype_get(button.get()) && !button_paneltype_get(button.get()))
      {
        c_menus.emplace(button.get(), int(c_menus.size()));
      }
    }
    /* A section's rows go into its sub-panel, made as its first button comes (PANEL-3). */
    const NodeId panel_node_id = node;
    const std::function<NodeId(int)> section_target = [&](const int i) -> NodeId {
      Section &section = sections[i];
      if (!section.node) {
        const NodeId parent = section.parent >= 0 ? section_target(section.parent) : panel_node_id;
        section.node = writer->section_node(
            parent, section.id, section.property, section.title, section.open);
      }
      return *section.node;
    };
    for (const auto &button : block->buttons) {
      Button &but = *button;
      if (dropped || section_request) {
        break;
      }
      bool in_section_header = false;
      if (writer && !sections.empty() && panel_nodes.count(candidate.id)) {
        const int section = section_of(but, &in_section_header);
        node = section >= 0 ? section_target(section) : panel_node_id;
      }
      if (writer) {
        for (size_t index = 0; index < empty_lists.size(); index++) {
          if (empty_lists[index].first == &but) {
            writer->list(node,
                         "empty:" + candidate.id + ":" + std::to_string(index),
                         &empty_lists[index].second,
                         false,
                         -1,
                         {});
          }
        }
      }
      if (!execute && combined.count(&but)) {
        continue;
      }
      if (const auto named = named_rows.find(&but); named != named_rows.end()) {
        if (writer && open) {
          const std::string key = writer->key("row:" + candidate.id + ":" +
                                              std::to_string(named_row_count++));
          const NodeId row = writer->builder.add(node, key, [&](Buffer &buffer, NodeFields &fields) {
            fields.label = but.str;
            fields.icon = icon_name(button_icon(&but));
            return protocol::CreateRow(buffer);
          });
          for (const Button *item : named->second) {
            if (!item->optype) {
              writer->property(row, const_cast<Button &>(*item), -1);
            }
          }
          for (const Button *item : named->second) {
            if (item->optype) {
              writer->button(row, *item);
            }
          }
        }
        continue;
      }
      PointerRNA template_ptr;
      PropertyRNA *template_prop;
      int template_event;
      if (template_id_property_get(but, template_ptr, template_prop, template_event)) {
        if (template_event == UI_ID_BROWSE) {
          const std::string key = id_template_key(template_ptr, template_prop);
          if (execute) {
            if (target_panel && *requested_key == key && !applied) {
              applied = apply_id_template(C, *block, template_ptr, template_prop, *request,
                                          operator_type, operator_properties, operator_context,
                                          pending_new_id);
            }
          }
          else if (seen.insert(key).second) {
            writer->picker(node, *block, template_ptr, template_prop);
            decide(&but, fate_projected("Reference"));
          }
          else {
            decide(&but, fate_consumed("duplicate"));
          }
        }
        continue;
      }
      if (but.type == ButtonType::ListBox) {
        /* The list's active index, which its rows show. An empty list has no rows: show it from
         * its box, so that its add button stays within reach. */
        const bool has_rows = std::any_of(
            block->buttons.begin(), block->buttons.end(), [&](const auto &row) {
              return row->type == ButtonType::ListRow && row->rnapoin.data == but.rnapoin.data &&
                     row->rnaprop == but.rnaprop;
            });
        if (writer && !has_rows && but.rnaprop && but.rnapoin.data &&
            seen.insert(property_key(but, -1)).second)
        {
          write_list(but);
          decide(&but, fate_projected("List"));
        }
        /* Otherwise its rows show it. */
        decide(&but, fate_consumed("list"));
        continue;
      }
      if (but.type == ButtonType::ViewItem) {
        /* A tree, from its first item. */
        for (size_t index = 0; index < trees.size(); index++) {
          if (trees[index].items.front() != &but) {
            if (std::find(trees[index].items.begin(), trees[index].items.end(), &but) !=
                trees[index].items.end())
            {
              decide(&but, fate_consumed("tree"));
            }
            continue;
          }
          const std::string key = tree_key(index);
          if (execute) {
            if (target_panel && *requested_key == key && !applied) {
              applied = apply_tree(C, trees[index], *request);
            }
          }
          else if (seen.insert(key).second) {
            write_tree(trees[index], key);
            /* Its items can neither be folded nor unfolded here (B18). */
            const bool folds = std::any_of(
                trees[index].items.begin(), trees[index].items.end(), [](const ButtonViewItem *item) {
                  const AbstractTreeViewItem *tree_view_item = tree_item(*item);
                  return tree_view_item && tree_view_item->is_collapsible();
                });
            decide(&but, folds ? Fate{"reduced", "List", "tree"} : fate_projected("List"));
          }
        }
        continue;
      }
      if (but.type == ButtonType::ListRow && execute && target_panel &&
          *requested_key == property_key(but, -1) && request->action == "move")
      {
        /* Drag to reorder: make the item active, then move it as the list's arrows do. */
        if (!applied) {
          ListSide *side = list_side_for(but);
          const int from = int(request->index);
          const int to = int(request->to);
          Button *step = side ? (to < from ? side->up : side->down) : nullptr;
          if (step && step->optype && from >= 0 && to >= 0 && from != to) {
            PointerRNA active_ptr = but.rnapoin;
            RNA_property_int_set(&active_ptr, but.rnaprop, from);
            RNA_property_update(C, &active_ptr, but.rnaprop);
            const bContextStore *previous = CTX_store_get(C);
            CTX_store_set(C, step->context);
            applied = true;
            for (int i = 0; i < std::abs(to - from) && applied; i++) {
              applied = WM_operator_name_call_ptr(C, step->optype, wm::OpCallContext::ExecDefault,
                                                  step->opptr, nullptr) & OPERATOR_FINISHED;
            }
            CTX_store_set(C, previous);
          }
        }
        continue;
      }
      if (but.type == ButtonType::ListRow && writer) {
        if (seen.insert(property_key(but, -1)).second) {
          write_list(but);
          decide(&but, fate_projected("List"));
        }
        decide(&but, fate_consumed("list"));
        continue;
      }
      if (but.type == ButtonType::Extra && but.poin && StringRef(candidate.id).endswith("_PT_preview"))
      {
        /* The Preview panel's render (#template_preview). */
        ID *id = reinterpret_cast<ID *>(but.poin);
        const std::string key = "preview:" + std::to_string(id->session_uid);
        if (writer && seen.insert(key).second) {
          const std::string image = id_large_preview_path(C, id);
          const NodeId picture = writer->builder.add(
              node, writer->key(key), [&](Buffer &buffer, NodeFields &fields) {
                fields.label = id->name + 2;
                return protocol::CreatePictureDirect(buffer, image.c_str());
              });
          /* The preview's shape choice, shown on the preview itself. */
          for (const auto &shape : block->buttons) {
            if (shape->type == ButtonType::Row && shape->rnaprop &&
                STREQ(RNA_property_identifier(shape->rnaprop), "preview_render_type"))
            {
              writer->property(picture, *shape, -1, {.role = protocol::Role::Shape});
              seen.insert(property_key(*shape, -1));
              decide(shape.get(), fate_projected("Choice"));
              break;
            }
          }
        }
        decide(&but, fate_projected("Picture"));
        continue;
      }
      PropertyRNA *menu_enum_prop = nullptr;
      if (wmOperatorType *menu_ot = button_operatortype_get_from_enum_menu(&but, &menu_enum_prop)) {
        /* An operator's enum as a menu, such as Add Object Constraint. */
        if (!menu_enum_prop || (but.flag & UI_HIDDEN)) {
          continue;
        }
        const std::string key = std::string("menu:") + menu_ot->idname + ":" +
                                RNA_property_identifier(menu_enum_prop);
        PointerRNA op_ptr = WM_operator_properties_create_ptr(menu_ot);
        if (execute) {
          const std::optional<std::string> value = command_text(request->command);
          if (target_panel && *requested_key == key && value && !operator_type &&
              !(but.flag & (BUT_DISABLED | BUT_INACTIVE)))
          {
            operator_type = menu_ot;
            operator_properties = MEM_new<PointerRNA>(__func__, op_ptr);
            WM_operator_properties_alloc(&operator_properties,
                                         reinterpret_cast<IDProperty **>(&operator_properties->data),
                                         menu_ot->idname);
            RNA_enum_set_identifier(C, operator_properties, RNA_property_identifier(menu_enum_prop),
                                    value->c_str());
            if (but.context) {
              operator_context = std::make_unique<bContextStore>(*but.context);
            }
            operator_exec = true;
          }
        }
        else if (seen.insert(key).second) {
          const std::string node_key = writer->key(key);
          const std::string label = but.str.empty() ? WM_operatortype_name(menu_ot, nullptr) :
                                                      but.str;
          data.edits.add_overwrite(node_key, {native::Edit::Kind::OperatorMenu, candidate.id, key});
          writer->builder.add(node, node_key, [&](Buffer &buffer, NodeFields &fields) {
            fields.label = label;
            fields.icon = icon_name(button_icon(&but));
            fields.enabled = !(but.flag & (BUT_DISABLED | BUT_INACTIVE));
            std::vector<flatbuffers::Offset<protocol::Option>> options;
            const EnumPropertyItem *items;
            int count;
            bool free;
            RNA_property_enum_items_gettexted(C, &op_ptr, menu_enum_prop, &items, &count, &free);
            for (int i = 0; i < count; i++) {
              const bool heading = !items[i].identifier || !items[i].identifier[0];
              /* Headings start groups, and have no value; unnamed ones are separators. */
              options.push_back(protocol::CreateOptionDirect(
                  buffer,
                  heading ? nullptr : items[i].identifier,
                  items[i].name ? items[i].name : "",
                  heading ? nullptr : icon_name(items[i].icon)));
            }
            if (free) {
              MEM_delete(items);
            }
            return protocol::CreateChoice(buffer,
                                          buffer.CreateString(""),
                                          buffer.CreateVector(options),
                                          protocol::ChoiceStyle::Actions);
          });
          decide(&but, fate_projected("Choice"));
        }
        decide(&but, fate_consumed("duplicate"));
        continue;
      }
      if (physics_toggles && !but.optype) {
        /* Per-type viewport toggles beside the switches belong to each physics panel. */
        decide(&but, fate_consumed("physics"));
        continue;
      }
      /* Keep only viewport enablement in modifier headers. Other display options belong
       * inside the expanded native panel. */
      const bool header_operator = header_buttons.count(&but) && but.optype && !(but.flag & UI_HIDDEN);
      if (header_operator && StringRef(but.optype->idname).endswith("_set_active")) {
        /* Native headers show which item is active as state, not as a button. */
        decide(&but, fate_consumed("active_state"));
        continue;
      }
      /* A modifier's or constraint's header: its name and the switches for where it applies,
       * which the native header gathers into one control. */
      const bool header_toggle = header_buttons.count(&but) && but.rnaprop &&
                                RNA_property_type(but.rnaprop) == PROP_BOOLEAN &&
                                !RNA_property_array_check(but.rnaprop) &&
                                (!RNA_struct_is_a(but.rnapoin.type, RNA_Modifier) ||
                                 STR_ELEM(RNA_property_identifier(but.rnaprop),
                                          "show_in_editmode",
                                          "show_on_cage",
                                          "show_viewport",
                                          "show_render"));
      const bool header_name = header_buttons.count(&but) && candidate.instance && but.rnaprop &&
                               RNA_property_type(but.rnaprop) == PROP_STRING &&
                               STREQ(RNA_property_identifier(but.rnaprop), "name");
      if (const auto c_menu = c_menus.find(&but); c_menu != c_menus.end()) {
        /* A menu Blender builds in C, such as a modifier's header menu (Apply, Duplicate, Copy to
         * Selected, Move) or a socket's link: opened as Blender's own menus are, by the menu
         * walker, which draws this panel again to find it (B4, PANEL-4). */
        const std::string key = "menu:" + std::to_string(c_menu->second);
        if (execute) {
          if (target_panel && *requested_key == key && request->action == "button" &&
              request->with_button && !applied)
          {
            request->with_button(but);
            applied = true;
          }
        }
        /* Properties and Preferences, where the menu walker can draw the panel again; the top
         * bar's and the viewport's popovers say it is in the Desktop Interface. */
        else if (writer && !(but.flag & UI_HIDDEN) && !viewport) {
          const std::string route = std::string(native::PANEL_MENU_ROOT) +
                                    native::PANEL_MENU_PART + (data.tool_tab ? "1" : "0") +
                                    native::PANEL_MENU_PART + candidate.id +
                                    native::PANEL_MENU_PART + key;
          const std::string label = !but.str.empty()       ? but.str :
                                    !but.tip.is_empty()    ? std::string(but.tip) :
                                                             std::string();
          const bool in_header = header_buttons.count(&but) != 0;
          writer->builder.add(node,
                              writer->key("cmenu:" + candidate.id + ":" + key),
                              [&](Buffer &buffer, NodeFields &fields) {
                                fields.label = label;
                                fields.icon = icon_name(button_icon(&but));
                                fields.enabled = !(but.flag & (BUT_DISABLED | BUT_INACTIVE));
                                fields.role = in_header ? protocol::Role::Header :
                                                          protocol::Role::None;
                                const auto param = protocol::CreateParamDirect(
                                    buffer,
                                    "menu",
                                    protocol::Value::TextValue,
                                    protocol::CreateTextValueDirect(buffer, route.c_str()).Union());
                                return protocol::CreateMenuButton(
                                    buffer, buffer.CreateString("menu"), buffer.CreateVector(&param, 1));
                              });
          decide(&but, fate_projected("MenuButton"));
          continue;
        }
        if (execute || !writer) {
          continue;
        }
      }
      if (!execute && !open && !header_toggle && !header_operator && !header_name) {
        continue;
      }
      if (but.type == ButtonType::Label) {
        /* What the panel says, such as a modifier's error, a note beside a button or a section's
         * heading: a line of its own, unless it names another control (a caption) or is a part
         * of one (B6). */
        if (writer && !(but.flag & UI_HIDDEN) && !fates.count(&but)) {
          std::string text = but.str;
          const size_t first = text.find_first_not_of(' ');
          text = first == std::string::npos ? "" : text.substr(first);
          while (!text.empty() && text.back() == ' ') {
            text.pop_back();
          }
          if (!text.empty()) {
            const int icon = button_icon(&but);
            const protocol::LabelStyle style =
                (but.flag & BUT_REDALERT) || icon == ICON_CANCEL ? protocol::LabelStyle::Error :
                icon == ICON_ERROR                                ? protocol::LabelStyle::Warning :
                icon == ICON_INFO                                 ? protocol::LabelStyle::Info :
                                                                    protocol::LabelStyle::Plain;
            writer->builder.add(
                node, writer->key("label:" + candidate.id), [&](Buffer &buffer, NodeFields &fields) {
                  fields.icon = icon_name(icon);
                  return protocol::CreateLabelDirect(buffer, text.c_str(), style);
                });
            decide(&but, fate_projected("Label"));
          }
        }
        continue;
      }
      MenuType *menu = button_menutype_get(&but);
      if (!menu && but.optype && but.opptr && STREQ(but.optype->idname, "WM_OT_call_menu")) {
        /* Some panel menus are expressed as operators, including Add Modifier. */
        const std::string name = RNA_string_get(but.opptr, "name");
        menu = WM_menutype_find(name.c_str(), true);
      }
      if (menu) {
        /* Opened by the interface, as a view of its own. */
        if (writer && !(but.flag & UI_HIDDEN)) {
          const std::string label = but.str.empty() ? menu->label : but.str;
          writer->builder.add(
              node, writer->key(menu->idname), [&](Buffer &buffer, NodeFields &fields) {
                fields.label = label;
                fields.icon = icon_name(button_icon(&but));
                fields.enabled = !(but.flag & (BUT_DISABLED | BUT_INACTIVE));
                const auto param = protocol::CreateParamDirect(
                    buffer,
                    "menu",
                    protocol::Value::TextValue,
                    protocol::CreateTextValueDirect(buffer, menu->idname).Union());
                return protocol::CreateMenuButton(
                    buffer, buffer.CreateString("menu"), buffer.CreateVector(&param, 1));
              });
          decide(&but, fate_projected("MenuButton"));
        }
        continue;
      }
      if (but.optype && !(but.flag & UI_HIDDEN)) {
        if (shading && STREQ(but.optype->idname, "SCREEN_OT_userpref_show")) {
          /* This opens an unrelated Blender window, not a viewport shading setting. */
          decide(&but, {"hidden", "", "preferences_window"});
          continue;
        }
        if (STREQ(but.optype->idname, "FILE_OT_unpack_item") && but.opptr &&
            RNA_int_get(but.opptr, "id_type") == ID_VF)
        {
          /* Fonts from the font picker are packed on purpose: their files are only a cache. */
          decide(&but, {"hidden", "", "font_cache"});
          continue;
        }
        const std::string key = operator_key(C, but, object);
        if (execute && !operator_type && target_panel && *requested_key == key &&
            !(but.flag & (BUT_DISABLED | BUT_INACTIVE)) && but.optype->exec) {
          operator_type = but.optype;
          operator_properties = but.opptr;
          but.opptr = nullptr;
          if (but.context) {
            operator_context = std::make_unique<bContextStore>(*but.context);
          }
        }
        else if (writer && physics_toggles && seen.insert(key).second) {
          /* Physics are added and removed with a button each, which shows an X while the
           * physics is on: natively, each is a panel of its settings, headed by a switch. */
          const bool on = button_icon(&but) == ICON_X;
          const char *settings = physics_panel(C, but);
          const std::string id = settings ? settings : key;
          const std::string label = but.str.empty() ?
                                        WM_operatortype_name(but.optype, but.opptr) :
                                        but.str;
          const NodeId physics = writer->panel_node(
              top,
              id,
              true,
              label,
              on && is_open(id),
              false,
              false,
              -1,
              on,
              icon_name(on ? physics_icon(C, but) : button_icon(&but)));
          physics_panels[id] = physics;
          const std::string switch_key = writer->key(key);
          data.edits.add_overwrite(switch_key,
                                   {native::Edit::Kind::Operator, candidate.id, key, 0, false, false,
                                    settings ? settings : ""});
          writer->builder.add(physics, switch_key, [&](Buffer &buffer, NodeFields &fields) {
            fields.label = label;
            fields.enabled = !(but.flag & (BUT_DISABLED | BUT_INACTIVE)) && but.optype->exec;
            fields.role = protocol::Role::Header;
            return protocol::CreateToggle(buffer, on);
          });
          decide(&but, fate_projected("Toggle"));
        }
        else if (writer && seen.insert(key).second) {
          writer->button(node, but, header_operator ? protocol::Role::Header : protocol::Role::None);
          /* Drawn greyed when it has no `exec` to run (B5, B13). */
          decide(&but, but.optype->exec ? fate_projected("Button") :
                                          Fate{"reduced", "Button", "operator_no_exec"});
        }
        decide(&but, fate_consumed("duplicate"));
        continue;
      }
      if (but.type == ButtonType::ColorBand && but.poin && but.rnaprop) {
        const std::string key = ramp_key(but);
        if (execute) {
          if (target_panel && *requested_key == key && !applied) {
            applied = apply_ramp(C, but, *request);
          }
        }
        else if (writer && seen.insert(key).second) {
          writer->ramp(node, but);
          decide(&but, fate_projected("Ramp"));
        }
        continue;
      }
      if (!but.rnaprop || !but.rnapoin.data || (but.flag & UI_HIDDEN)) {
        continue;
      }
      if (!ELEM(RNA_property_type(but.rnaprop), PROP_BOOLEAN, PROP_INT, PROP_FLOAT, PROP_STRING, PROP_ENUM, PROP_POINTER) ||
          (RNA_property_type(but.rnaprop) == PROP_POINTER &&
           !RNA_struct_is_ID(RNA_property_pointer_type(&but.rnapoin, but.rnaprop)))) {
        continue;
      }
      const int length = RNA_property_array_length(&but.rnapoin, but.rnaprop);
      const bool color = is_color(&but.rnapoin, but.rnaprop);
      /* Only what every selected item has. */
      const auto found_others = others_of.find(&but);
      const SelectedOthers others = execute                       ? SelectedOthers() :
                                    found_others != others_of.end() ? found_others->second :
                                                                      selected_others(C, but);
      if (others.missing) {
        /* Shown when it is the only item selected with it (B2). */
        decide(&but, fate_dropped("selection"));
        continue;
      }
      const int begin = !color && length ? std::max(0, but.rnaindex) : -1;
      const int end = !color && length && but.rnaindex < 0 ? std::min(length, 16) : begin + 1;
      for (int index = begin; index < end; index++) {
        const std::string key = property_key(but, index);
        if (execute) {
          /* Of the buttons with its key, the one it is, as each row of a list has its own. */
          if (target_panel && *requested_key == key && !applied &&
              occurrences[key]++ == request->edit->occurrence)
          {
            applied = ELEM(request->action, "", "activate") ?
                          set_property(C, but, index, *request) :
                          animate_property(C, but, index, request->action);
          }
          continue;
        }
        if (!seen.insert(key).second) {
          decide(&but, fate_consumed("duplicate"));
          continue;
        }
        if (attached_locks.count(key) || attached_modes.count(key)) {
          decide(&but, fate_consumed("attached"));
          continue;
        }
        decide(&but, property_fate(but));
        Look look;
        look.others = &others;
        if (const auto pair = pairs.find(&but); pair != pairs.end()) {
          look.pair = &pair->second;
        }
        /* One property on several items, such as each bone collection's visibility, is named by
         * the text Blender draws; a property of its own, such as a Geometry Nodes input, by its
         * layout's. */
        const auto own_name = tool_labels.find(&but);
        const auto layout_name = layout_names.find(but.rnaprop);
        if (shared_properties.count(but.rnaprop) && own_name != tool_labels.end()) {
          look.name = own_name->second;
        }
        else if (layout_name != layout_names.end() && RNA_property_is_idprop(but.rnaprop)) {
          look.name = layout_name->second;
        }
        /* Authored as an expanded row, such as the selection mode, not a menu. */
        look.expand = but.type == ButtonType::Row && RNA_property_type(but.rnaprop) == PROP_ENUM;
        if (const auto group = toggle_groups.find(&but); group != toggle_groups.end()) {
          look.toggles = candidate.id + ":" + std::to_string(group->second.first);
          look.toggles_caption = group->second.second;
        }
        /* The short text Blender draws, for the tool settings and for a row of toggles, such as
         * the Axes' X, Y and Z, rather than each property's full name. */
        if (own_name != tool_labels.end() && (tool_settings || toggle_groups.count(&but))) {
          look.short_label = own_name->second;
        }
        if (const auto found = field_modes.find(key); found != field_modes.end()) {
          look.mode = found->second;
        }
        if (const auto found = field_locks.find(key); found != field_locks.end()) {
          look.lock = found->second.first;
          look.lock_index = found->second.second;
        }
        look.role = header_name                          ? protocol::Role::Name :
                    header_toggle && candidate.instance ? protocol::Role::Visibility :
                    header_toggle || in_section_header  ? protocol::Role::Header :
                                                          protocol::Role::None;
        writer->property(node, but, index, look);
      }
    }
    node = panel_node_id;
    if (writer && !dropped) {
      /* The census of this panel: what became of each button, and what it could not show,
       * which the row at the foot of its node says (R6-9). */
      Said *panel_said = panel_nodes.count(candidate.id) ? &said[node] : nullptr;
      const auto note = [&](const std::string &button, const std::string &detail, const Fate &fate) {
        census_record(tab_id, candidate.id, button, detail, fate);
        if (panel_said) {
          panel_said->add(fate.counted);
        }
      };
      if (pt.draw_header_preset) {
        /* The presets Blender draws in the panel's header (B8). */
        note("HeaderPreset", pt.idname, fate_dropped("header_preset"));
      }
      for (const Section &section : sections) {
        /* A sub-panel, opened and closed as Blender's (PANEL-3). */
        note("Section", section.title, fate_projected("Panel"));
      }
      for (const auto &button : block->buttons) {
        const Button &but = *button;
        if (but.flag & UI_HIDDEN) {
          continue;
        }
        if (const auto fate = fates.find(&but); fate != fates.end()) {
          note(button_type_name(but.type), button_detail(but), fate->second);
        }
        /* A closed panel shows its header alone, as Blender's does. */
        else if (open) {
          if (std::optional<Fate> fate = unhandled_fate(but)) {
            if (preferences && candidate.id == "USERPREF_PT_keymap") {
              /* The key maps, which the interface lists itself, view only (`native_settings`). */
              fate = Fate{"hidden", "", "keymap"};
            }
            note(button_type_name(but.type), button_detail(but), *fate);
          }
        }
      }
    }
    panel->layout = nullptr;
    block->panel = nullptr;
    block_free(nullptr, block);
    if (!candidate.instance) {
      BKE_panel_free(panel);
    }
    auto add_instance = [&](auto &&self, Panel *instance, const std::string &parent) -> void {
      if (!instance->type || !instances.insert(instance).second) {
        return;
      }
      PointerRNA *data = panel_custom_data_get(instance);
      const auto path = data ? RNA_path_from_ID_to_struct(data) : std::nullopt;
      const std::string id = std::string(instance->type->idname) + ":" + path.value_or("");
      candidates.push_back({instance->type, instance, id, parent});
      for (Panel &child : instance->children) {
        self(self, &child, id);
      }
    };
    if (!candidate.instance && !viewport) {
      for (Panel &instance : panel_region->panels) {
        add_instance(add_instance, &instance, "");
      }
    }
    if (execute && target_panel) {
      break;
    }
  }
  if (writer) {
    /* What a panel, or the tab, could not show: one row at its foot, with a button to the
     * Desktop Interface, where Blender draws all of it (R6-9). */
    std::map<NodeId, std::string> node_panels;
    for (const auto &[id, panel_node] : panel_nodes) {
      node_panels.emplace(panel_node, id);
    }
    const auto say = [&](const NodeId parent, const std::string &key, const Said &what, const char *where) {
      if (what.total() == 0) {
        return;
      }
      const std::string text = what.text(where);
      const std::string node_key = writer->key(key);
      data.edits.add_overwrite(node_key,
                               {native::Edit::Kind::Call, "", "WM_OT_native_interface_toggle"});
      writer->builder.add(parent, node_key, [&](Buffer &buffer, NodeFields &fields) {
        fields.label = text;
        fields.icon = icon_name(ICON_WINDOW);
        fields.role = protocol::Role::Elsewhere;
        return protocol::CreateButton(buffer);
      });
      census_record(tab_id, key, "Row", text, {"said", "Button", ""});
    };
    for (const auto &[panel_node, what] : said) {
      const auto id = node_panels.find(panel_node);
      say(panel_node, "elsewhere:" + (id == node_panels.end() ? std::to_string(panel_node) : id->second),
          what, "panel");
    }
    say(top, "elsewhere", tab_said, "tab");
  }
  if (operator_type) {
    const bContextStore *previous = CTX_store_get(C);
    CTX_store_set(C, operator_context.get());
    /* Panel buttons such as a modifier's delete button name their target only through the
     * context store, which the operator reads in invoke (as a click in Blender would). */
    const wm::OpCallContext call = operator_context && operator_type->invoke && !operator_exec ?
                                       wm::OpCallContext::InvokeDefault :
                                       wm::OpCallContext::ExecDefault;
    if (WM_operator_poll_context(C, operator_type, call)) {
      applied = WM_operator_name_call_ptr(C, operator_type, call, operator_properties, nullptr) &
                OPERATOR_FINISHED;
    }
    CTX_store_set(C, previous);
    if (operator_properties) {
      WM_operator_properties_free(operator_properties);
      MEM_delete(operator_properties);
    }
    if (applied) {
      finish_pending_new_id(C, pending_new_id);
    }
  }
  if (execute) {
    return applied ? "" : "This property is no longer available or editable.";
  }
  /* A text object's styles, which Blender keeps per character: on all of it out of Edit Mode,
   * for the Text section's bold, italic and underline. */
  if (tab_id == "DATA" && object && object->type == OB_FONT) {
    const Curve *curve = id_cast<const Curve *>(object->data);
    short flags = curve->curinfo.flag;
    if (const EditFont *edit = curve->editfont) {
      int start, end;
      if (BKE_vfont_select_get(const_cast<Curve *>(curve), &start, &end)) {
        flags = edit->textbufinfo[start].flag;
      }
    }
    else if (curve->len_char32 > 0) {
      flags = ~0;
      for (int i = 0; i < curve->len_char32; i++) {
        flags &= curve->strinfo[i].flag;
      }
    }
    PointerRNA curve_ptr = RNA_id_pointer_create(const_cast<ID *>(&curve->id));
    const NodeId style = writer->builder.add(top, "text_style", [](Buffer &buffer, NodeFields &) {
      return protocol::CreateGroup(buffer);
    });
    const auto add = [&](const char *name, auto write) {
      writer->builder.add(style,
                          std::string("text_style:") + name,
                          [&](Buffer &buffer, NodeFields &fields) {
                            fields.label = name;
                            return write(buffer);
                          });
    };
    for (const auto [name, flag] : {std::pair{"bold", CU_CHINFO_BOLD},
                                    std::pair{"italic", CU_CHINFO_ITALIC},
                                    std::pair{"underline", CU_CHINFO_UNDERLINE},
                                    std::pair{"small_caps", CU_CHINFO_SMALLCAPS}})
    {
      add(name, [&](Buffer &buffer) { return protocol::CreateToggle(buffer, flags & flag); });
    }
    add("font_file", [&](Buffer &buffer) {
      return protocol::CreateTextFieldDirect(buffer, curve->vfont ? curve->vfont->filepath : "");
    });
    for (const char *identifier : {"align_x", "align_y"}) {
      PropertyRNA *prop = RNA_struct_find_property(&curve_ptr, identifier);
      const char *value = "";
      RNA_property_enum_identifier(
          C, &curve_ptr, prop, RNA_property_enum_get(&curve_ptr, prop), &value);
      add(identifier,
          [&](Buffer &buffer) { return protocol::CreateTextFieldDirect(buffer, value); });
    }
    for (const char *identifier : {"size", "space_line", "space_character", "space_word"}) {
      add(identifier, [&](Buffer &buffer) {
        return protocol::CreateNumber(buffer, RNA_float_get(&curve_ptr, identifier));
      });
    }
  }
  return "";
}


namespace native {

void panels_write(bContext *C, PanelsData &data, ViewBuilder &builder)
{
  Writer writer(C, builder, data);
  panels_walk(C, data, &writer, nullptr);
}

std::string panels_edit(bContext *C, PanelsData &data, const EditRequest &request)
{
  return panels_walk(C, data, nullptr, &request);
}

}  // namespace native

namespace native {

bool panel_button(bContext *C,
                  const StringRef tab,
                  const bool tool_tab,
                  const StringRef panel,
                  const StringRef key,
                  const FunctionRef<void(Button &)> fn)
{
  PanelsData data;
  data.tab = tab;
  data.tool_tab = tool_tab;
  const Edit edit{Edit::Kind::Property, panel, key};
  EditRequest request;
  request.edit = &edit;
  request.action = "button";
  request.with_button = fn;
  return panels_walk(C, data, nullptr, &request).empty();
}

void in_properties_tab(bContext *C, const StringRef tab, const FunctionRef<void()> fn)
{
  if (tab.is_empty() || tab == "TOOL") {
    fn();
    return;
  }
  PropertiesContext context(C);
  PointerRNA ptr = RNA_pointer_create_discrete(nullptr, RNA_SpaceProperties, context.space);
  PropertyRNA *prop = RNA_struct_find_property(&ptr, "context");
  const EnumPropertyItem *items;
  int count, selected;
  bool free;
  RNA_property_enum_items(C, &ptr, prop, &items, &count, &free);
  if (RNA_enum_value_from_identifier(items, std::string(tab).c_str(), &selected)) {
    context.space->mainbuser = selected;
    ED_buttons_native_context_prepare(C, context.space);
  }
  if (free) {
    MEM_delete(items);
  }
  fn();
}

}  // namespace native

/* -------------------------------------------------------------------- */
/** \name Node Graphs
 *
 * A node tree for a native canvas: its nodes with their sockets and controls, and its links. The
 * canvas sends its edits back as actions on the tree, applied as Blender's node editor applies
 * them, each one undoable.
 * \{ */

namespace {

struct NativeNodeTree {
  /** The tree shown: the root tree, or a group entered from it. */
  bNodeTree *tree = nullptr;
  bNodeTree *root = nullptr;
  /** What the root tree belongs to, such as the material. */
  std::string owner;
  /** Why there is no tree, and what creating one is called. */
  std::string empty;
  std::string create;
  /** The group nodes entered, outermost first. */
  Vector<bNode *> path;
  /** What Blender's node editor names as the tree's owner, and where it comes from. */
  ID *id = nullptr;
  ID *from = nullptr;
  /** The kind of tree, which the editor's header follows even while there is none. */
  const char *idname = "ShaderNodeTree";
};

NativeNodeTree native_node_tree(bContext *C, const DictionaryValue &query)
{
  NativeNodeTree result;
  const std::string kind = query.lookup_str("tree").value_or("SHADER");
  Object *object = CTX_data_active_object(C);
  if (kind == "SHADER") {
    result.from = object ? &object->id : nullptr;
    Material *material = object ? BKE_object_material_get(object, object->actcol) : nullptr;
    if (material && material->nodetree) {
      result.root = material->nodetree;
      result.owner = material->id.name + 2;
      result.id = &material->id;
      result.from = &object->id;
    }
    else if (object && OB_TYPE_SUPPORT_MATERIAL(object->type)) {
      result.empty = "No Material";
      result.create = "New Material";
    }
    else {
      result.empty = object ? "This Object Has No Materials" : "No Active Object";
    }
  }
  else if (kind == "GEOMETRY") {
    result.idname = "GeometryNodeTree";
    result.from = object ? &object->id : nullptr;
    NodesModifierData *nodes_modifier = nullptr;
    if (object) {
      ModifierData *active = BKE_object_active_modifier(object);
      if (active && active->type == eModifierType_Nodes) {
        nodes_modifier = reinterpret_cast<NodesModifierData *>(active);
      }
      else {
        for (ModifierData &modifier : object->modifiers) {
          if (modifier.type == eModifierType_Nodes) {
            nodes_modifier = reinterpret_cast<NodesModifierData *>(&modifier);
            break;
          }
        }
      }
    }
    if (nodes_modifier && nodes_modifier->node_group) {
      result.root = nodes_modifier->node_group;
      result.owner = nodes_modifier->modifier.name;
      result.id = &object->id;
      result.from = &object->id;
      /* The modifier whose evaluation the editor shows: its timings, warnings and viewers. */
      BKE_object_modifier_set_active(object, &nodes_modifier->modifier);
    }
    else if (object && ELEM(object->type, OB_MESH, OB_CURVES, OB_POINTCLOUD, OB_VOLUME, OB_GREASE_PENCIL))
    {
      result.empty = "No Geometry Nodes";
      result.create = "New Geometry Nodes";
    }
    else {
      result.empty = object ? "This Object Has No Geometry Nodes" : "No Active Object";
    }
  }
  else if (kind == "COMPOSITOR") {
    result.idname = "CompositorNodeTree";
    Scene *scene = CTX_data_scene(C);
    if (scene && scene->compositing_node_group) {
      result.root = scene->compositing_node_group;
      result.owner = scene->id.name + 2;
      result.id = &scene->id;
    }
    else {
      result.empty = "No Compositor Nodes";
      result.create = "New Compositor Nodes";
    }
  }
  result.tree = result.root;
  if (const ArrayValue *path = query.lookup_array("path")) {
    for (const auto &item : path->elements()) {
      const StringValue *name = item->as_string_value();
      bNode *group = result.tree && name ? bke::node_find_node_by_name(*result.tree, name->value()) :
                                           nullptr;
      if (!group || !group->is_group() || !group->id) {
        break;
      }
      result.path.append(group);
      result.tree = reinterpret_cast<bNodeTree *>(group->id);
    }
  }
  return result;
}

/**
 * A node editor showing the tree, for what asks for one: which nodes the Add menu offers (shader
 * nodes for objects or worlds), nodes' own drawing, and operators.
 */
/**
 * The node editor the native one stands in for, as Blender's own would be set up for the tree:
 * kept for the session, as its previews and the jobs rendering them belong to it.
 */
ScrArea *native_node_area(bContext *C)
{
  static ScrArea *area = nullptr;
  if (area == nullptr) {
    area = MEM_new<ScrArea>("native node editor");
    area->spacetype = SPACE_NODE;
    area->type = BKE_spacetype_from_id(SPACE_NODE);
    SpaceLink *link = area->type->create(area, CTX_data_scene(C));
    BLI_addtail(&area->spacedata, link);
    std::swap(area->regionbase, link->regionbase);
    if (ARegion *region = BKE_area_find_region_type(area, RGN_TYPE_WINDOW)) {
      region->runtime->type = BKE_regiontype_from_id(area->type, RGN_TYPE_WINDOW);
    }
  }
  return area;
}

SpaceNode *native_node_space(bContext *C, const NativeNodeTree &shown)
{
  SpaceNode *space = static_cast<SpaceNode *>(native_node_area(C)->spacedata.first);
  /* As #ED_node_tree_start and #ED_node_tree_push set it up, without their notifiers. */
  for (bNodeTreePath &path : space->treepath.items_mutable()) {
    MEM_delete(&path);
  }
  BLI_listbase_clear(&space->treepath);
  space->nodetree = shown.root;
  space->edittree = shown.tree;
  space->id = shown.id;
  space->from = shown.from;
  space->node_tree_sub_type = 0; /* SNODE_GEOMETRY_MODIFIER, SNODE_COMPOSITOR_SCENE. */
  space->shaderfrom = SNODE_SHADER_OBJECT;
  space->overlay.flag |= SN_OVERLAY_SHOW_OVERLAYS | SN_OVERLAY_SHOW_PREVIEWS |
                         SN_OVERLAY_SHOW_TIMINGS;
  /* With no tree yet, its header still offers one to pick or make. */
  STRNCPY(space->tree_idname, shown.root ? shown.root->idname : shown.idname);
  if (shown.root) {
    bNodeTreePath *previous = MEM_new<bNodeTreePath>("node tree path");
    previous->nodetree = shown.root;
    previous->parent_key = bke::NODE_INSTANCE_KEY_BASE;
    BLI_addtail(&space->treepath, previous);
    for (bNode *group : shown.path) {
      bNodeTreePath *path = MEM_new<bNodeTreePath>("node tree path");
      path->nodetree = reinterpret_cast<bNodeTree *>(group->id);
      path->parent_key = bke::node_instance_key(previous->parent_key, previous->nodetree, group);
      STRNCPY(path->node_name, group->name);
      BLI_addtail(&space->treepath, path);
      previous = path;
    }
    /* The compositor computes previews and viewers of the group being looked at, as
     * #ED_node_set_active_viewer_key records it. */
    if (shown.root->type == NTREE_COMPOSIT &&
        shown.root->active_viewer_key.value != previous->parent_key.value)
    {
      shown.root->active_viewer_key = previous->parent_key;
      DEG_id_tag_update(&shown.root->id, ID_RECALC_NTREE_OUTPUT);
    }
  }
  return space;
}

/** The native node editor's space as the context's area, while the tree is read or edited. */
struct NodeSpaceContext {
  bContext *C;
  ScrArea *previous_area;
  ARegion *previous_region;
  SpaceNode *space = nullptr;

  NodeSpaceContext(bContext *context, const NativeNodeTree &shown) : C(context)
  {
    previous_area = CTX_wm_area(C);
    previous_region = CTX_wm_region(C);
    space = native_node_space(C, shown);
    ScrArea *area = native_node_area(C);
    CTX_wm_area_set(C, area);
    CTX_wm_region_set(C, BKE_area_find_region_type(area, RGN_TYPE_WINDOW));
  }

  ~NodeSpaceContext()
  {
    CTX_wm_area_set(C, previous_area);
    CTX_wm_region_set(C, previous_region);
  }
};

const char *node_class_name(const int nclass)
{
  switch (nclass) {
    case NODE_CLASS_INPUT: return "INPUT";
    case NODE_CLASS_OUTPUT: return "OUTPUT";
    case NODE_CLASS_OP_COLOR: return "COLOR";
    case NODE_CLASS_OP_VECTOR: return "VECTOR";
    case NODE_CLASS_OP_FILTER: return "FILTER";
    case NODE_CLASS_GROUP: return "GROUP";
    case NODE_CLASS_CONVERTER: return "CONVERTER";
    case NODE_CLASS_MATTE: return "MATTE";
    case NODE_CLASS_DISTORT: return "DISTORT";
    case NODE_CLASS_PATTERN: return "PATTERN";
    case NODE_CLASS_TEXTURE: return "TEXTURE";
    case NODE_CLASS_SCRIPT: return "SCRIPT";
    case NODE_CLASS_INTERFACE: return "INTERFACE";
    case NODE_CLASS_SHADER: return "SHADER";
    case NODE_CLASS_GEOMETRY: return "GEOMETRY";
    case NODE_CLASS_ATTRIBUTE: return "ATTRIBUTE";
    case NODE_CLASS_LAYOUT: return "LAYOUT";
    default: return "OTHER";
  }
}

const char *node_class_title(const int nclass)
{
  switch (nclass) {
    case NODE_CLASS_INPUT: return "Input";
    case NODE_CLASS_OUTPUT: return "Output";
    case NODE_CLASS_OP_COLOR: return "Color";
    case NODE_CLASS_OP_VECTOR: return "Vector";
    case NODE_CLASS_OP_FILTER: return "Filter";
    case NODE_CLASS_GROUP: return "Group";
    case NODE_CLASS_CONVERTER: return "Converter";
    case NODE_CLASS_MATTE: return "Matte";
    case NODE_CLASS_DISTORT: return "Distort";
    case NODE_CLASS_PATTERN: return "Pattern";
    case NODE_CLASS_TEXTURE: return "Texture";
    case NODE_CLASS_SCRIPT: return "Script";
    case NODE_CLASS_INTERFACE: return "Interface";
    case NODE_CLASS_SHADER: return "Shader";
    case NODE_CLASS_GEOMETRY: return "Geometry";
    case NODE_CLASS_ATTRIBUTE: return "Attribute";
    case NODE_CLASS_LAYOUT: return "Layout";
    default: return "Other";
  }
}

std::set<const bNodeSocket *> linked_sockets(const bNodeTree &tree)
{
  std::set<const bNodeSocket *> linked;
  for (const bNodeLink &link : tree.links) {
    linked.insert(link.fromsock);
    linked.insert(link.tosock);
  }
  return linked;
}

/** The node's own controls, then the values of its inputs that nothing links, as one block. */
Block *native_node_block(bContext *C,
                         bNodeTree &tree,
                         bNode &node,
                         const std::set<const bNodeSocket *> &linked)
{
  Block *block = block_begin(C, nullptr, "native_node", EmbossType::Emboss);
  Layout &layout = block_layout(
      block, LayoutDirection::Vertical, LayoutType::Panel, 0, 0, 320, 20, 0, style_get_dpi());
  PointerRNA node_ptr = RNA_pointer_create_discrete(&tree.id, RNA_Node, &node);
  layout.context_ptr_set("node", &node_ptr);
  if (node.typeinfo->draw_buttons) {
    node.typeinfo->draw_buttons(layout, C, &node_ptr);
  }
  /* A socket that draws itself, such as the String node's text, as Blender's editor does. */
  const auto custom_draw = [&](bNodeSocket &socket) {
    const nodes::SocketDeclaration *declaration = socket.runtime->declaration;
    if (!declaration || !declaration->custom_draw_fn) {
      return false;
    }
    PointerRNA socket_ptr = RNA_pointer_create_discrete(&tree.id, RNA_NodeSocket, &socket);
    nodes::CustomSocketDrawParams params{
        *C, layout, tree, node, socket, node_ptr, socket_ptr, socket.name};
    (*declaration->custom_draw_fn)(params);
    return true;
  };
  for (bNodeSocket &socket : node.outputs) {
    if (socket.is_visible()) {
      custom_draw(socket);
    }
  }
  for (bNodeSocket &socket : node.inputs) {
    if (!socket.is_visible() || linked.count(&socket) || (socket.flag & SOCK_HIDE_VALUE)) {
      continue;
    }
    if (custom_draw(socket)) {
      continue;
    }
    PointerRNA socket_ptr = RNA_pointer_create_discrete(&tree.id, RNA_NodeSocket, &socket);
    if (RNA_struct_find_property(&socket_ptr, "default_value")) {
      layout.prop(&socket_ptr, "default_value", UI_ITEM_NONE, "", ICON_NONE);
    }
  }
  block_end(C, block);
  return block;
}

/** What Blender's node editor header draws for the tree shown, whose data-block picker the
 * native header shows: the modifier's node group, the material, the world, the scene's
 * compositor. */
Block *native_node_header_block(bContext *C)
{
  Block *block = block_begin(C, nullptr, "native_node_header", EmbossType::Emboss);
  Layout &layout = block_layout(
      block, LayoutDirection::Horizontal, LayoutType::Header, 0, 0, 20, 1, 0, style_get_dpi());
  SpaceType *space_type = BKE_spacetype_from_id(SPACE_NODE);
  if (ARegionType *region_type = BKE_regiontype_from_id(space_type, RGN_TYPE_HEADER)) {
    for (HeaderType &header_type : region_type->headertypes) {
      if (!header_type.draw || (header_type.poll && !header_type.poll(C, &header_type))) {
        continue;
      }
      Header header = {nullptr};
      header.type = &header_type;
      header.layout = &layout;
      header_type.draw(C, &header);
    }
  }
  block_end(C, block);
  return block;
}

/** Calls `fn` for each value a node's block shows, as the Properties fields go, a color ramp
 * among them, and `id_fn`
 * for each data-block picker (an image, a node group), whose parts are left out. */
template<typename Fn, typename IDFn> void for_each_node_field(Block &block, Fn fn, IDFn id_fn)
{
  std::set<std::string> seen;
  for (const auto &button : block.buttons) {
    Button &but = *button;
    PointerRNA template_ptr;
    PropertyRNA *template_prop;
    int template_event;
    if (template_id_property_get(but, template_ptr, template_prop, template_event)) {
      if (template_event == UI_ID_BROWSE &&
          seen.insert(id_template_key(template_ptr, template_prop)).second)
      {
        id_fn(template_ptr, template_prop);
      }
      continue;
    }
    if (but.type == ButtonType::ColorBand && but.poin && but.rnaprop) {
      if (seen.insert(ramp_key(but)).second) {
        fn(but, -1, ramp_key(but));
      }
      continue;
    }
    if (!but.rnaprop || !but.rnapoin.data || (but.flag & UI_HIDDEN) ||
        /* A picker's own, in its menu. */
        STREQ(RNA_property_identifier(but.rnaprop), "use_fake_user"))
    {
      continue;
    }
    const PropertyType type = RNA_property_type(but.rnaprop);
    if (!ELEM(type, PROP_BOOLEAN, PROP_INT, PROP_FLOAT, PROP_STRING, PROP_ENUM, PROP_POINTER) ||
        (type == PROP_POINTER && !RNA_struct_is_ID(RNA_property_pointer_type(&but.rnapoin, but.rnaprop))))
    {
      continue;
    }
    const int length = RNA_property_array_length(&but.rnapoin, but.rnaprop);
    const bool color = is_color(&but.rnapoin, but.rnaprop);
    const int begin = !color && length ? std::max(0, but.rnaindex) : -1;
    const int end = !color && length && but.rnaindex < 0 ? std::min(length, 16) : begin + 1;
    for (int index = begin; index < end; index++) {
      const std::string key = property_key(but, index);
      if (seen.insert(key).second) {
        fn(but, index, key);
      }
    }
  }
}

/** Which panel of its node each socket is in, by the panels' identifiers. */
std::map<std::string, int> socket_panels(const bNode &node)
{
  std::map<std::string, int> panels;
  const nodes::NodeDeclaration *declaration = node.declaration();
  if (!declaration) {
    return panels;
  }
  for (const nodes::PanelDeclaration *panel : declaration->panels) {
    for (const nodes::ItemDeclaration *item : panel->items) {
      if (const auto *socket = dynamic_cast<const nodes::SocketDeclaration *>(item)) {
        panels[(socket->in_out == SOCK_IN ? "i:" : "o:") + socket->identifier] = panel->identifier;
      }
    }
  }
  return panels;
}

void project_node_socket(const bNodeSocket &socket,
                         const std::set<const bNodeSocket *> &linked,
                         DictionaryValue &item)
{
  item.append_str("id", socket.identifier);
  item.append_str("name", ed::space_node::node_socket_get_label(&socket));
  float color[4] = {0.6f, 0.6f, 0.6f, 1.0f};
  if (socket.typeinfo && socket.typeinfo->draw_color_simple) {
    socket.typeinfo->draw_color_simple(socket.typeinfo, color);
  }
  auto color_value = item.append_array("color");
  for (int i = 0; i < 4; i++) {
    color_value->append_double(color[i]);
  }
  item.append_str("shape", ELEM(socket.display_shape, SOCK_DISPLAY_SHAPE_DIAMOND, SOCK_DISPLAY_SHAPE_DIAMOND_DOT) ?
                               "DIAMOND" :
                               "CIRCLE");
  item.append_int("linked", linked.count(&socket) != 0);
  item.append_int("multi", (socket.flag & SOCK_MULTI_INPUT) != 0);
  item.append_str("type", socket.typeinfo ? socket.typeinfo->idname : "");
}

/** What reading a tree gathers once for all its nodes: timings, warnings and previews. */
struct NodeReadContext {
  SpaceNode *space = nullptr;
  Scene *scene = nullptr;
  nodes::geo_eval_log::ContextualGeoTreeLogs geo_logs;
  ed::space_node::NestedTreePreviews *shader_previews = nullptr;
  Map<bNodeInstanceKey, bke::bNodePreview> *compositor_previews = nullptr;
  bNodeInstanceKey parent_key = bke::NODE_INSTANCE_KEY_BASE;
};

/** A preview image as a PNG file for the native interface, written again only when it changes. */
std::string native_preview_path(const Scene *scene, const ImBuf *ibuf, const std::string &name)
{
  if (ibuf == nullptr || ibuf->x <= 0 || ibuf->y <= 0) {
    return "";
  }
  uint64_t hash = uint64_t(ibuf->x) * 31 + ibuf->y;
  if (ibuf->float_buffer.data) {
    hash = hash * 1000003 + BLI_hash_mm2(reinterpret_cast<const unsigned char *>(ibuf->float_buffer.data),
                                         size_t(ibuf->x) * ibuf->y * ibuf->channels * sizeof(float), 0);
  }
  else if (ibuf->byte_buffer.data) {
    hash = hash * 1000003 + BLI_hash_mm2(ibuf->byte_buffer.data, size_t(ibuf->x) * ibuf->y * 4, 0);
  }
  static std::map<std::string, std::pair<uint64_t, std::string>> written;
  auto &entry = written[name];
  if (entry.first == hash && !entry.second.empty()) {
    return entry.second;
  }
  /* In the scene's view transform, as Blender's own editors show it. */
  ImBuf *display = IMB_dupImBuf(ibuf);
  if (display->float_buffer.data) {
    IMB_colormanagement_imbuf_make_display_space(
        display, &scene->view_settings, &scene->display_settings);
    IMB_byte_from_float(display);
  }
  display->planes = 32;
  display->ftype = IMB_FTYPE_PNG;
  const std::string path = std::string(BKE_tempdir_session()) + "native_node_" + name + "_" +
                           std::to_string(hash) + ".png";
  if (IMB_save_image(display, path.c_str(), IB_byte_data)) {
    if (!entry.second.empty()) {
      BLI_delete(entry.second.c_str(), false, false);
    }
    entry = {hash, path};
  }
  IMB_freeImBuf(display);
  return entry.second;
}

void project_node(bNodeTree &tree,
                  bNode &node,
                  const std::set<const bNodeSocket *> &linked,
                  DictionaryValue &item,
                  NodeReadContext &read)
{
  item.append_str("name", node.name);
  item.append_str("title", bke::node_label(tree, node));
  item.append_str("idname", node.idname);
  item.append_str("class", node_class_name(node.typeinfo->nclass));
  item.append_str("kind", node.is_frame()   ? "FRAME" :
                          node.is_reroute() ? "REROUTE" :
                          node.is_group()   ? "GROUP" :
                                              "NODE");
  item.append_double("x", node.location[0]);
  item.append_double("y", node.location[1]);
  item.append_double("width", node.width);
  item.append_double("height", node.height);
  item.append_int("selected", (node.flag & NODE_SELECT) != 0);
  item.append_int("active", (node.flag & NODE_ACTIVE) != 0);
  item.append_int("muted", (node.flag & NODE_MUTED) != 0);
  item.append_int("collapsed", (node.flag & NODE_COLLAPSED) != 0);
  if (node.flag & NODE_CUSTOM_COLOR) {
    auto color = item.append_array("color");
    for (int i = 0; i < 3; i++) {
      color->append_double(node.color[i]);
    }
  }
  if (node.parent) {
    item.append_str("parent", node.parent->name);
  }
  /* How long it took and what went wrong, as Blender's editor shows above nodes. */
  std::optional<std::chrono::nanoseconds> time;
  if (tree.type == NTREE_GEOMETRY) {
    const bke::bNodeTreeZones *zones = tree.zones();
    const bke::bNodeTreeZone *zone = zones ? zones->get_zone_by_node(node.identifier) : nullptr;
    if (zone && ELEM(node.identifier, zone->input_node_id, zone->output_node_id)) {
      zone = zone->parent_zone;
    }
    if (nodes::geo_eval_log::GeoTreeLog *log = read.geo_logs.get_main_tree_log(zone)) {
      if (node.is_group_output()) {
        time = log->execution_time;
      }
      else if (const nodes::geo_eval_log::GeoNodeLog *node_log = log->nodes.lookup_ptr(node.identifier)) {
        time = node_log->execution_time;
        if (!node_log->warnings.is_empty()) {
          auto warnings = item.append_array("warnings");
          for (const nodes::geo_eval_log::NodeWarning &warning : node_log->warnings) {
            auto entry = warnings->append_dict();
            entry->append_str("message", warning.message);
            entry->append_str("type", warning.type == nodes::NodeWarningType::Error   ? "ERROR" :
                                      warning.type == nodes::NodeWarningType::Warning ? "WARNING" :
                                                                                       "INFO");
          }
        }
      }
    }
  }
  else if (tree.type == NTREE_COMPOSIT && read.scene) {
    const bNodeInstanceKey key = bke::node_instance_key(read.parent_key, &tree, &node);
    if (const timeit::Nanoseconds *found =
            read.scene->runtime->compositor.per_node_execution_time.lookup_ptr(key))
    {
      if (found->count() > 0) {
        time = *found;
      }
    }
  }
  if (time && !node.is_frame()) {
    item.append_double("time_ms", double(time->count()) / 1e6);
  }
  /* A preview of the node's result, for nodes that have one, while it is turned on. */
  /* As #node_is_previewable: shader previews are an experimental option in Blender. */
  const bool previewable = tree.type == NTREE_SHADER ?
                               USER_EXPERIMENTAL_TEST(&U, use_shader_node_previews) &&
                                   !node.is_frame() :
                               bke::node_preview_used(node);
  if (previewable) {
    item.append_int("can_preview", 1);
    item.append_int("preview_on", (node.flag & NODE_PREVIEW) != 0);
    if (node.flag & NODE_PREVIEW) {
      const std::string name = std::to_string(tree.id.session_uid) + "_" + std::to_string(node.identifier);
      std::string path;
      if (read.shader_previews) {
        ImBuf *ibuf = ed::space_node::node_preview_acquire_ibuf(tree, *read.shader_previews, node);
        path = native_preview_path(read.scene, ibuf, name);
        ed::space_node::node_release_preview_ibuf(*read.shader_previews);
      }
      else if (read.compositor_previews) {
        const bNodeInstanceKey key = bke::node_instance_key(read.parent_key, &tree, &node);
        if (const bke::bNodePreview *preview = read.compositor_previews->lookup_ptr(key)) {
          path = native_preview_path(read.scene, preview->ibuf, name);
        }
      }
      if (!path.empty()) {
        item.append_str("preview", path);
      }
    }
  }
  if (node.is_group() && node.id) {
    item.append_str("group", node.id->name + 2);
  }
  /* Panels, such as a shader's Subsurface and Specular: open or closed, inside another. */
  const std::map<std::string, int> panel_of = socket_panels(node);
  if (const nodes::NodeDeclaration *declaration = node.declaration()) {
    const Span<bNodePanelState> states = node.panel_states();
    auto panels = item.append_array("panels");
    for (const nodes::PanelDeclaration *panel : declaration->panels) {
      auto panel_item = panels->append_dict();
      panel_item->append_int("id", panel->identifier);
      panel_item->append_str("name", panel->name);
      if (panel->parent_panel) {
        panel_item->append_int("parent", panel->parent_panel->identifier);
      }
      bool collapsed = panel->default_collapsed;
      for (const bNodePanelState &state : states) {
        if (state.identifier == panel->identifier) {
          collapsed = state.is_collapsed();
        }
      }
      panel_item->append_int("collapsed", collapsed);
    }
  }
  auto inputs = item.append_array("inputs");
  for (const bNodeSocket &socket : node.inputs) {
    if (socket.is_visible()) {
      auto socket_item = inputs->append_dict();
      project_node_socket(socket, linked, *socket_item);
      if (const auto found = panel_of.find(std::string("i:") + socket.identifier); found != panel_of.end()) {
        socket_item->append_int("panel", found->second);
      }
    }
  }
  auto outputs = item.append_array("outputs");
  for (const bNodeSocket &socket : node.outputs) {
    if (socket.is_visible()) {
      auto socket_item = outputs->append_dict();
      project_node_socket(socket, linked, *socket_item);
      if (const auto found = panel_of.find(std::string("o:") + socket.identifier); found != panel_of.end()) {
        socket_item->append_int("panel", found->second);
      }
    }
  }
}

/** A node's values as controls under its record \a record: its own under `<node>/fields`, a
 * socket's under `<node>/socket:<id>`. */
void write_node_fields(Writer &writer,
                       const NodeId record,
                       const std::string &record_key,
                       bNodeTree &tree,
                       bNode &node,
                       const std::set<const bNodeSocket *> &linked)
{
  writer.panel = node.name;
  Block *block = native_node_block(writer.C, tree, node, linked);
  std::map<std::string, NodeId> groups;
  const auto group = [&](const std::string &name) {
    const auto [found, added] = groups.try_emplace(name, 0);
    if (added) {
      found->second = writer.group(record, record_key + "/" + name, name);
    }
    return found->second;
  };
  /* A node's own values: other selected nodes are left alone. */
  const SelectedOthers none;
  for_each_node_field(
      *block,
      [&](Button &but, const int index, const std::string & /*key*/) {
        if (but.type == ButtonType::ColorBand) {
          writer.ramp(group("fields"), but);
          return;
        }
        const bool socket = RNA_struct_is_a(but.rnapoin.type, RNA_NodeSocket);
        writer.property(
            group(socket ? "socket:" + std::string(
                                           static_cast<bNodeSocket *>(but.rnapoin.data)->identifier) :
                           "fields"),
            but,
            index,
            {.others = &none});
      },
      [&](PointerRNA &ptr, PropertyRNA *prop) {
        writer.picker(group("fields"), *block, ptr, prop);
      });
  block_free(writer.C, block);
}

/** The colors of a node type's socket types, once each and in order, for the add list. */
void node_type_socket_colors(const bke::bNodeType &type, const bool output, ArrayValue &colors)
{
  const nodes::NodeDeclaration *declaration = type.static_declaration;
  if (!declaration) {
    return;
  }
  Vector<int> seen;
  for (const nodes::SocketDeclaration *socket : output ? declaration->outputs : declaration->inputs) {
    if (socket->socket_type < 0 || seen.contains(int(socket->socket_type)) || seen.size() >= 5) {
      continue;
    }
    seen.append(int(socket->socket_type));
    float color[4] = {0.6f, 0.6f, 0.6f, 1.0f};
    if (const bke::bNodeSocketType *socket_type = bke::node_socket_type_find_static(socket->socket_type)) {
      if (socket_type->draw_color_simple) {
        socket_type->draw_color_simple(socket_type, color);
      }
    }
    auto value = colors.append_array();
    for (int c = 0; c < 3; c++) {
      value->append_double(color[c]);
    }
  }
}

/** The nodes Blender's own Add menu offers here, walking its submenus: each tree, context and
 * render engine lists only the nodes that apply, as Blender decides it. */
void collect_add_menu(bContext *C,
                      MenuType *menu,
                      const std::string &category,
                      const int depth,
                      std::set<std::string> &seen,
                      std::set<const MenuType *> &visited,
                      ArrayValue &items)
{
  /* Each menu once: submenus are shared between categories. Asset catalog menus list the
   * libraries' node groups, which would load them all, and are left out. */
  if (!menu || depth > 6 || !visited.insert(menu).second ||
      StringRef(menu->idname).find("catalog") != StringRef::not_found ||
      StringRef(menu->idname).find("asset") != StringRef::not_found || !WM_menutype_poll(C, menu))
  {
    return;
  }
  Block *block = block_begin(C, nullptr, __func__, EmbossType::Emboss);
  Layout &layout = block_layout(
      block, LayoutDirection::Vertical, LayoutType::Menu, 0, 0, 200, 0, 0, style_get_dpi());
  menutype_draw(C, menu, &layout);
  block_end(C, block);
  for (const auto &button : block->buttons) {
    Button &but = *button;
    if (but.flag & (UI_HIDDEN | BUT_DISABLED)) {
      continue;
    }
    if (MenuType *sub = button_menutype_get(&but)) {
      const std::string name = but.drawstr.substr(0, but.drawstr.find(UI_SEP_CHAR));
      collect_add_menu(C, sub, depth == 0 ? name : category, depth + 1, seen, visited, items);
      continue;
    }
    if (!but.optype || !but.opptr) {
      continue;
    }
    std::string idname;
    if (STREQ(but.optype->idname, "NODE_OT_add_node")) {
      idname = RNA_string_get(but.opptr, "type");
    }
    else if (STREQ(but.optype->idname, "NODE_OT_add_zone") ||
             STREQ(but.optype->idname, "NODE_OT_add_simulation_zone") ||
             STREQ(but.optype->idname, "NODE_OT_add_repeat_zone") ||
             STREQ(but.optype->idname, "NODE_OT_add_foreach_geometry_element_zone") ||
             STREQ(but.optype->idname, "NODE_OT_add_closure_zone"))
    {
      if (PropertyRNA *prop = RNA_struct_find_property(but.opptr, "input_node_type")) {
        idname = RNA_property_string_get(but.opptr, prop);
      }
    }
    const bke::bNodeType *type = idname.empty() ? nullptr : bke::node_type_find(idname);
    if (!type || !seen.insert(idname).second) {
      continue;
    }
    const std::string label = but.drawstr.substr(0, but.drawstr.find(UI_SEP_CHAR));
    auto item = items.append_dict();
    item->append_str("idname", idname);
    item->append_str("name", label.empty() ? type->ui_name : label);
    item->append_str("description", type->ui_description);
    item->append_str("category", category.empty() ? node_class_title(type->nclass) : category);
    node_type_socket_colors(*type, false, *item->append_array("inputs"));
    node_type_socket_colors(*type, true, *item->append_array("outputs"));
  }
  block_free(C, block);
}

void project_node_add_items(bContext *C, bNodeTree &tree, ArrayValue &items)
{
  std::set<std::string> seen;
  std::set<const MenuType *> visited;
  collect_add_menu(C, WM_menutype_find("NODE_MT_add", false), "", 0, seen, visited, items);
  /* The tree's own node groups, as the Group category lists them. */
  Main *bmain = CTX_data_main(C);
  for (bNodeTree &group : bmain->nodetrees) {
    if (group.type != tree.type || &group == &tree || group.id.name[2] == '.') {
      continue;
    }
    auto item = items.append_dict();
    item->append_str("idname", tree.typeinfo->group_idname);
    item->append_str("name", group.id.name + 2);
    item->append_str("group", group.id.name + 2);
    item->append_str("category", "Group");
  }
}

bNodeSocket *find_socket(bNode &node, const std::string &identifier, const bool output)
{
  for (bNodeSocket &socket : output ? node.outputs : node.inputs) {
    if (socket.identifier == identifier) {
      return &socket;
    }
  }
  return nullptr;
}

/**
 * Links an output to an input, replacing what the input had unless it takes several. The nodes
 * may take the link their own way, as Blender's editor lets them: an empty socket on a group's
 * input or output, or a zone's, becomes a new socket of the group or zone.
 */
/** The socket a node put in a link joins it by: the first shown one of the link's type, else the
 * first shown one, as Blender picks a node's main socket. */
bNodeSocket *insert_socket(bNode &node, const bool output, const short type)
{
  ListBaseT<bNodeSocket> &sockets = output ? node.outputs : node.inputs;
  bNodeSocket *first = nullptr;
  for (bNodeSocket &socket : sockets) {
    if (!socket.is_visible()) {
      continue;
    }
    if (socket.type == type) {
      return &socket;
    }
    if (!first) {
      first = &socket;
    }
  }
  return first;
}

bool link_sockets(bNodeTree &tree,
                  bNode &from,
                  bNodeSocket &from_socket,
                  bNode &to,
                  bNodeSocket &to_socket,
                  bContext *C = nullptr)
{
  if (!(to_socket.flag & SOCK_MULTI_INPUT)) {
    bke::node_remove_socket_links(tree, to_socket);
  }
  bNodeLink &link = bke::node_add_link(tree, from, from_socket, to, to_socket);
  for (bNode *node : {link.fromnode, link.tonode}) {
    if (node->typeinfo->insert_link) {
      bke::NodeInsertLinkParams params{tree, *node, link, C};
      if (!node->typeinfo->insert_link(params)) {
        bke::node_remove_link(&tree, link);
        return false;
      }
    }
  }
  return true;
}

/** Adds a node at a place, a zone's input with its output, or a group's node with its group. */
bNode *add_native_node(bContext *C, bNodeTree &tree, const DictionaryValue &query)
{
  const std::string idname = query.lookup_str("idname").value_or("");
  if (!bke::node_type_find(idname)) {
    return nullptr;
  }
  const float2 location(float(query.lookup_double("x").value_or(0)),
                        float(query.lookup_double("y").value_or(0)));
  for (bNode &node : tree.nodes) {
    node.flag &= ~(NODE_SELECT | NODE_ACTIVE);
  }
  bNode *node = bke::node_add_node(C, tree, idname);
  if (node == nullptr) {
    return nullptr;
  }
  copy_v2_v2(node->location, location);
  if (const auto group_name = query.lookup_str("group")) {
    Main *bmain = CTX_data_main(C);
    for (bNodeTree &group : bmain->nodetrees) {
      if (group.id.name + 2 == *group_name && group.type == tree.type) {
        node->id = &group.id;
        id_us_plus(&group.id);
        BKE_ntree_update_tag_node_property(&tree, node);
        break;
      }
    }
  }
  if (const bke::bNodeZoneType *zone = bke::zone_type_by_node_type(node->type_legacy)) {
    if (zone->input_type == node->type_legacy) {
      bNode *output = bke::node_add_node(C, tree, zone->output_idname);
      if (output) {
        copy_v2_v2(output->location, location + float2(300.0f, 0.0f));
        zone->get_corresponding_output_id(*node) = output->identifier;
        BKE_ntree_update_tag_node_property(&tree, node);
        if (tree.type == NTREE_GEOMETRY) {
          BKE_main_ensure_invariants(*CTX_data_main(C), tree.id);
          bNodeSocket *from = nullptr, *to = nullptr;
          for (bNodeSocket &socket : node->outputs) {
            if (!from && socket.type == SOCK_GEOMETRY) {
              from = &socket;
            }
          }
          for (bNodeSocket &socket : output->inputs) {
            if (!to && socket.type == SOCK_GEOMETRY) {
              to = &socket;
            }
          }
          if (from && to) {
            link_sockets(tree, *node, *from, *output, *to);
          }
        }
      }
    }
  }
  node->flag |= NODE_SELECT;
  bke::node_set_active(tree, *node);
  /* Dropped from a link pulled out of a socket: connect it to the first matching socket. */
  if (const DictionaryValue *from = query.lookup_dict("connect")) {
    bNode *other = bke::node_find_node_by_name(tree, from->lookup_str("node").value_or(""));
    const bool other_output = from->lookup_int("output").value_or(1) != 0;
    bNodeSocket *other_socket = other ? find_socket(*other, std::string(from->lookup_str("socket").value_or("")), other_output) : nullptr;
    if (other_socket) {
      BKE_main_ensure_invariants(*CTX_data_main(C), tree.id);
      bNodeSocket *best = nullptr;
      for (bNodeSocket &socket : other_output ? node->inputs : node->outputs) {
        if (!socket.is_visible()) {
          continue;
        }
        if (socket.type == other_socket->type) {
          best = &socket;
          break;
        }
        if (!best) {
          best = &socket;
        }
      }
      if (best) {
        if (other_output) {
          link_sockets(tree, *other, *other_socket, *node, *best);
        }
        else {
          link_sockets(tree, *node, *best, *other, *other_socket);
        }
      }
    }
  }
  return node;
}

Vector<bNode *> named_nodes(bNodeTree &tree, const DictionaryValue &query)
{
  Vector<bNode *> nodes;
  if (const ArrayValue *names = query.lookup_array("nodes")) {
    for (const auto &item : names->elements()) {
      if (const StringValue *name = item->as_string_value()) {
        if (bNode *node = bke::node_find_node_by_name(tree, name->value())) {
          nodes.append(node);
        }
      }
    }
  }
  return nodes;
}

/** What a key asked of the native editor itself: the Add menu, or entering or leaving a group. */
struct NativeNodeKeyRequest {
  int sequence = 0;
  std::string action;
  std::string node;
};
NativeNodeKeyRequest native_node_key_request;

bool keymap_modifier_matches(const int8_t item, const bool held)
{
  return item == KM_ANY || (item == KM_MOD_HELD) == held;
}

/**
 * A hardware key pressed in the native node editor, run as the node editor's keymap has it, the
 * user's or the selected preset's: Blender's own operators on the tree. The editor's own views
 * (its Add menu, groups entered) are asked of the native editor.
 */
std::optional<std::string> native_node_key(bContext *C, bNodeTree &tree, const DictionaryValue &query)
{
  wmWindowManager *wm = CTX_wm_manager(C);
  const bool shift = query.lookup_int("shift").value_or(0), ctrl = query.lookup_int("ctrl").value_or(0),
             alt = query.lookup_int("alt").value_or(0), oskey = query.lookup_int("oskey").value_or(0);
  /* Keys as Blender names them; the Mac's Delete is Backspace, which Blender also takes. */
  Vector<std::string> names = {std::string(query.lookup_str("key").value_or(""))};
  if (names[0] == "BACK_SPACE") {
    names.append("DEL");
  }
  auto find = [&](const int type, const bool use_ctrl, const bool use_oskey) -> wmKeyMapItem * {
    for (const char *keymap_name : {"Node Editor", "Node Generic"}) {
      wmKeyMap *keymap = WM_keymap_find_all(wm, keymap_name, SPACE_NODE, RGN_TYPE_WINDOW);
      keymap = keymap ? WM_keymap_active(wm, keymap) : nullptr;
      if (!keymap) {
        continue;
      }
      for (wmKeyMapItem &item : keymap->items) {
        if ((item.flag & KMI_INACTIVE) || item.type != type || !ELEM(item.val, KM_PRESS, KM_ANY, KM_CLICK) ||
            !keymap_modifier_matches(item.shift, shift) || !keymap_modifier_matches(item.ctrl, use_ctrl) ||
            !keymap_modifier_matches(item.alt, alt) || !keymap_modifier_matches(item.oskey, use_oskey))
        {
          continue;
        }
        return &item;
      }
    }
    return nullptr;
  };
  wmKeyMapItem *item = nullptr;
  for (const std::string &name : names) {
    int type;
    if (!RNA_enum_value_from_identifier(rna_enum_event_type_items, name.c_str(), &type)) {
      continue;
    }
    /* Command for Control, as the iPad's keyboards have it, when the keymap has none. */
    item = find(type, ctrl, oskey);
    if (!item && oskey && !ctrl) {
      item = find(type, true, false);
    }
    if (item) {
      break;
    }
  }
  if (!item) {
    return std::nullopt;
  }
  const StringRef idname = item->idname;
  auto request = [&](const std::string &action, const std::string &node) {
    native_node_key_request.sequence++;
    native_node_key_request.action = action;
    native_node_key_request.node = node;
    return std::string("");
  };
  if (idname == "WM_OT_call_menu" || idname == "WM_OT_call_menu_pie" || idname == "WM_OT_call_panel") {
    const std::string menu = item->ptr ? RNA_string_get(item->ptr, "name") : "";
    if (menu == "NODE_MT_add") {
      return request("add", "");
    }
    return std::nullopt;
  }
  if (idname == "NODE_OT_group_edit") {
    const bool exit = item->ptr && RNA_boolean_get(item->ptr, "exit");
    const bNode *active = bke::node_get_active(tree);
    if (!exit && active && active->is_group() && active->id) {
      return request("enter", active->name);
    }
    return request("exit", "");
  }
  /* Duplicating moves the copies with the pointer in Blender; here they are placed as the
   * Duplicate command places them. */
  wmOperatorType *ot = WM_operatortype_find(
      idname == "NODE_OT_duplicate_move" ? "NODE_OT_duplicate" : item->idname, false);
  /* Operators that run on the tree as it is. Those following the pointer (select, link, cut,
   * grab, rotate, scale and moves chained after another step) belong to the canvas's own
   * gestures: run without one they would act on wherever the pointer last was. */
  if (!ot || !ot->exec || ot->modal || (ot->flag & OPTYPE_MACRO) || StringRef(ot->idname).startswith("TRANSFORM_OT") ||
      !WM_operator_poll(C, ot))
  {
    return std::nullopt;
  }
  if (!(WM_operator_name_call_ptr(C,
                                  ot,
                                  wm::OpCallContext::ExecDefault,
                                  idname == "NODE_OT_duplicate_move" ? nullptr : item->ptr,
                                  nullptr) &
        OPERATOR_FINISHED))
  {
    return std::nullopt;
  }
  BKE_main_ensure_invariants(*CTX_data_main(C), tree.id);
  return std::string("");
}

/** A node's value, or the header's data-block, which is there even while there is no tree. */
bool apply_node_property(bContext *C,
                         bNodeTree *tree,
                         bNode *node,
                         const native::EditRequest &request)
{
  Main *bmain = CTX_data_main(C);
  const bool header = request.edit->panel.empty();
  if ((!node || !tree) && !header) {
    return false;
  }
  Block *block = header ? native_node_header_block(C) :
                          native_node_block(C, *tree, *node, linked_sockets(*tree));
  const std::string &key = request.edit->key;
  const bool picker = request.edit->kind == native::Edit::Kind::Picker;
  bool applied = false;
  wmOperatorType *operator_type = nullptr;
  PointerRNA *operator_properties = nullptr;
  std::unique_ptr<bContextStore> operator_context;
  PendingNewID pending;
  for_each_node_field(
      *block,
      [&](Button &but, const int index, const std::string &field_key) {
        if (!applied && !picker && field_key == key) {
          applied = but.type == ButtonType::ColorBand ?
                        apply_ramp(C, but, request) :
                    request.action.empty() ? set_property(C, but, index, request, true, false) :
                                             animate_property(C, but, index, request.action);
        }
      },
      [&](PointerRNA &ptr, PropertyRNA *prop) {
        if (!applied && picker && id_template_key(ptr, prop) == key) {
          applied = apply_id_template(C, *block, ptr, prop, request, operator_type,
                                      operator_properties, operator_context, pending);
        }
      });
  /* New (or a copy), which the picker's own operator makes. */
  if (operator_type) {
    const bContextStore *previous = CTX_store_get(C);
    CTX_store_set(C, operator_context.get());
    if (WM_operator_poll_context(C, operator_type, wm::OpCallContext::ExecDefault)) {
      applied = WM_operator_name_call_ptr(C, operator_type, wm::OpCallContext::ExecDefault,
                                          operator_properties, nullptr) &
                OPERATOR_FINISHED;
    }
    CTX_store_set(C, previous);
    if (operator_properties) {
      WM_operator_properties_free(operator_properties);
      MEM_delete(operator_properties);
    }
    if (applied) {
      finish_pending_new_id(C, pending);
    }
  }
  block_free(C, block);
  /* Undo, keys and updates are the property's own, as from a button. */
  if (node && tree) {
    BKE_ntree_update_tag_node_property(tree, node);
  }
  if (tree) {
    BKE_main_ensure_invariants(*bmain, tree->id);
  }
  else {
    BKE_main_ensure_invariants(*bmain);
  }
  return applied;
}

/** Applies one of the canvas's actions to the tree it shows; the undo step's name, or none. */
std::optional<std::string> apply_node_action(bContext *C, bNodeTree &tree, const DictionaryValue &query)
{
  Main *bmain = CTX_data_main(C);
  const std::string action = query.lookup_str("action").value_or("");
  bNode *node = bke::node_find_node_by_name(tree, query.lookup_str("node").value_or(""));
  if (action == "select") {
    if (!query.lookup_int("extend").value_or(0)) {
      for (bNode &other : tree.nodes) {
        other.flag &= ~(NODE_SELECT | NODE_ACTIVE);
      }
    }
    if (node) {
      node->flag |= NODE_SELECT;
      bke::node_set_active(tree, *node);
    }
    WM_event_add_notifier(C, NC_NODE | NA_SELECTED, &tree);
    return std::string("");
  }
  if (action == "operator") {
    /* Blender's own operators on the selection, as their keys run them: duplicate, group,
     * ungroup, frame. */
    static const std::set<std::string> allowed = {"NODE_OT_duplicate",
                                                  "NODE_OT_group_make",
                                                  "NODE_OT_group_ungroup",
                                                  "NODE_OT_join",
                                                  "NODE_OT_parent_clear",
                                                  "NODE_OT_detach"};
    const std::string idname = std::string(query.lookup_str("operator").value_or(""));
    wmOperatorType *ot = allowed.count(idname) ? WM_operatortype_find(idname.c_str(), false) :
                                                 nullptr;
    if (!ot || !WM_operator_poll(C, ot)) {
      return std::nullopt;
    }
    const wmOperatorStatus status = WM_operator_name_call_ptr(
        C, ot, wm::OpCallContext::ExecDefault, nullptr, nullptr);
    if (!(status & OPERATOR_FINISHED)) {
      return std::nullopt;
    }
    if (idname == "NODE_OT_duplicate") {
      /* Beside the originals, as moving them away right after would. */
      for (bNode &other : tree.nodes) {
        if (other.flag & NODE_SELECT) {
          other.location[0] += 40.0f;
          other.location[1] -= 40.0f;
        }
      }
    }
    BKE_main_ensure_invariants(*bmain, tree.id);
    /* The operators push their own undo steps. */
    return std::string("");
  }
  if (action == "select_nodes") {
    for (bNode *named : named_nodes(tree, query)) {
      named->flag |= NODE_SELECT;
    }
    WM_event_add_notifier(C, NC_NODE | NA_SELECTED, &tree);
    return std::string("");
  }
  if (action == "select_all") {
    const bool select = query.lookup_int("value").value_or(1) != 0;
    for (bNode &other : tree.nodes) {
      SET_FLAG_FROM_TEST(other.flag, select, NODE_SELECT);
      if (!select) {
        other.flag &= ~NODE_ACTIVE;
      }
    }
    WM_event_add_notifier(C, NC_NODE | NA_SELECTED, &tree);
    return std::string("");
  }
  if (action == "move") {
    const float2 delta(float(query.lookup_double("dx").value_or(0)),
                       float(query.lookup_double("dy").value_or(0)));
    std::set<bNode *> moved;
    for (bNode *named : named_nodes(tree, query)) {
      moved.insert(named);
    }
    /* A frame takes what it holds along. */
    for (bNode &other : tree.nodes) {
      for (bNode *parent = other.parent; parent; parent = parent->parent) {
        if (moved.count(parent)) {
          moved.insert(&other);
          break;
        }
      }
    }
    for (bNode *moving : moved) {
      add_v2_v2(moving->location, delta);
    }
    /* Dropped onto a link, the node is put in it, as Blender's editor does. */
    if (const std::optional<StringRefNull> to_name = query.lookup_str("insert_to_node")) {
      bNode *node_in = moved.size() == 1 ? *moved.begin() : nullptr;
      bNode *from = bke::node_find_node_by_name(tree, query.lookup_str("insert_from_node").value_or(""));
      bNode *to = bke::node_find_node_by_name(tree, *to_name);
      bNodeSocket *from_socket = from ? find_socket(*from, std::string(query.lookup_str("insert_from_socket").value_or("")), true) : nullptr;
      bNodeSocket *to_socket = to ? find_socket(*to, std::string(query.lookup_str("insert_to_socket").value_or("")), false) : nullptr;
      if (node_in && from_socket && to_socket && node_in != from && node_in != to) {
        bNodeSocket *input = insert_socket(*node_in, false, from_socket->type);
        bNodeSocket *output = insert_socket(*node_in, true, to_socket->type);
        if (input && output) {
          for (bNodeLink &link : tree.links.items_mutable()) {
            if (link.fromsock == from_socket && link.tosock == to_socket) {
              bke::node_remove_link(&tree, link);
              break;
            }
          }
          link_sockets(tree, *from, *from_socket, *node_in, *input, C);
          link_sockets(tree, *node_in, *output, *to, *to_socket, C);
          BKE_main_ensure_invariants(*bmain, tree.id);
          WM_event_add_notifier(C, NC_NODE | NA_EDITED, &tree);
          return std::string("Insert Node");
        }
      }
    }
    WM_event_add_notifier(C, NC_NODE | NA_EDITED, &tree);
    return std::string("Move Nodes");
  }
  if (action == "link" || action == "unlink") {
    bNode *to = bke::node_find_node_by_name(tree, query.lookup_str("to_node").value_or(""));
    bNodeSocket *to_socket = to ? find_socket(*to, std::string(query.lookup_str("to_socket").value_or("")), false) : nullptr;
    if (!to_socket) {
      return std::nullopt;
    }
    if (action == "unlink") {
      bNode *from = bke::node_find_node_by_name(tree, query.lookup_str("from_node").value_or(""));
      const std::string from_id = std::string(query.lookup_str("from_socket").value_or(""));
      for (bNodeLink &link : tree.links.items_mutable()) {
        if (link.tosock == to_socket && (!from || (link.fromnode == from && from_id == link.fromsock->identifier))) {
          bke::node_remove_link(&tree, link);
        }
      }
      BKE_main_ensure_invariants(*bmain, tree.id);
      return std::string("Disconnect");
    }
    bNode *from = bke::node_find_node_by_name(tree, query.lookup_str("from_node").value_or(""));
    bNodeSocket *from_socket = from ? find_socket(*from, std::string(query.lookup_str("from_socket").value_or("")), true) : nullptr;
    if (!from_socket || from == to) {
      return std::nullopt;
    }
    if (!link_sockets(tree, *from, *from_socket, *to, *to_socket, C)) {
      return std::nullopt;
    }
    BKE_main_ensure_invariants(*bmain, tree.id);
    return std::string("Link Nodes");
  }
  if (action == "add") {
    if (!add_native_node(C, tree, query)) {
      return std::nullopt;
    }
    BKE_main_ensure_invariants(*bmain, tree.id);
    return std::string("Add Node");
  }
  if (action == "delete") {
    for (bNode *named : named_nodes(tree, query)) {
      bke::node_remove_node(bmain, tree, *named, true);
    }
    BKE_main_ensure_invariants(*bmain, tree.id);
    return std::string("Delete Nodes");
  }
  if (action == "mute" || action == "collapse") {
    const int flag = action == "mute" ? NODE_MUTED : NODE_COLLAPSED;
    Vector<bNode *> nodes = named_nodes(tree, query);
    const bool set = std::any_of(nodes.begin(), nodes.end(), [&](bNode *item) { return !(item->flag & flag); });
    for (bNode *item : nodes) {
      SET_FLAG_FROM_TEST(item->flag, set, flag);
      BKE_ntree_update_tag_node_property(&tree, item);
    }
    BKE_main_ensure_invariants(*bmain, tree.id);
    return std::string(action == "mute" ? "Toggle Node Mute" : "Collapse Nodes");
  }
  if (action == "preview" && node) {
    node->flag ^= NODE_PREVIEW;
    if (tree.type == NTREE_COMPOSIT) {
      ED_node_compositor_job(C);
    }
    WM_event_add_notifier(C, NC_NODE | NA_EDITED, &tree);
    return std::string("Toggle Node Preview");
  }
  if (action == "color" && node) {
    /* A color of the node's own, or none for its kind's. */
    if (const ArrayValue *color = query.lookup_array("value"); color && color->elements().size() >= 3) {
      for (int i = 0; i < 3; i++) {
        const auto &component = color->elements()[i];
        node->color[i] = float(component->as_double_value() ? component->as_double_value()->value() :
                               component->as_int_value()   ? double(component->as_int_value()->value()) :
                                                             0.0);
      }
      node->flag |= NODE_CUSTOM_COLOR;
    }
    else {
      node->flag &= ~NODE_CUSTOM_COLOR;
    }
    WM_event_add_notifier(C, NC_NODE | NA_EDITED, &tree);
    return std::string("Node Color");
  }
  if (action == "socket_hide" && node) {
    /* An unlinked socket hidden, as its own toggle in Blender's sidebar does. */
    const bool output = query.lookup_int("output").value_or(0) != 0;
    bNodeSocket *socket = find_socket(*node, std::string(query.lookup_str("socket").value_or("")), output);
    if (!socket || socket->is_directly_linked()) {
      return std::nullopt;
    }
    socket->flag |= SOCK_HIDDEN;
    BKE_ntree_update_tag_node_property(&tree, node);
    BKE_main_ensure_invariants(*bmain, tree.id);
    return std::string("Hide Socket");
  }
  if (action == "sockets_show" && node) {
    for (bNodeSocket &socket : node->inputs) {
      socket.flag &= ~SOCK_HIDDEN;
    }
    for (bNodeSocket &socket : node->outputs) {
      socket.flag &= ~SOCK_HIDDEN;
    }
    BKE_ntree_update_tag_node_property(&tree, node);
    BKE_main_ensure_invariants(*bmain, tree.id);
    return std::string("Show Sockets");
  }
  if (action == "viewer" && node) {
    /* The node's result viewed, as Ctrl Shift clicking it does: in the viewport for geometry, in
     * the backdrop for the compositor. */
    for (bNode &other : tree.nodes) {
      other.flag &= ~(NODE_SELECT | NODE_ACTIVE);
    }
    node->flag |= NODE_SELECT;
    bke::node_set_active(tree, *node);
    wmOperatorType *ot = WM_operatortype_find("NODE_OT_link_viewer", false);
    if (!ot || !WM_operator_poll(C, ot)) {
      return std::nullopt;
    }
    Map<const bNode *, float2> locations;
    for (const bNode &other : tree.nodes) {
      locations.add(&other, float2(other.location));
    }
    /* It reports itself cancelled when it adds a new viewer, so what it did is read from the
     * tree. */
    const wmOperatorStatus status = WM_operator_name_call_ptr(
        C, ot, wm::OpCallContext::ExecDefault, nullptr, nullptr);
    /* The operator places the viewer from the bounds Blender's editor draws, which this one
     * doesn't: keep a viewer that is already right of the node, otherwise place it there. */
    const auto rough_height = [](const bNode &other) {
      int sockets = 0;
      for (const bNodeSocket *socket : other.input_sockets()) {
        sockets += socket->is_visible();
      }
      for (const bNodeSocket *socket : other.output_sockets()) {
        sockets += socket->is_visible();
      }
      return 40.0f + 24.0f * sockets;
    };
    tree.ensure_topology_cache();
    bool viewed = false;
    for (bNode &viewer : tree.nodes) {
      if (!viewer.is_type("GeometryNodeViewer") && !viewer.is_type("CompositorNodeViewer")) {
        continue;
      }
      const bool linked = std::any_of(
          tree.links.begin(), tree.links.end(), [&](const bNodeLink &link) {
            return link.fromnode == node && link.tonode == &viewer;
          });
      if (!linked) {
        continue;
      }
      if (const float2 *previous = locations.lookup_ptr(&viewer)) {
        copy_v2_v2(viewer.location, *previous);
        if (viewer.location[0] > node->location[0] + node->width) {
          viewed = true;
          break;
        }
      }
      float2 spot(node->location[0] + node->width + 60.0f, node->location[1]);
      const float height = rough_height(viewer);
      for (int step = 0; step < 12; step++) {
        const bool overlaps = std::any_of(
            tree.nodes.begin(), tree.nodes.end(), [&](const bNode &other) {
              if (&other == &viewer || other.is_frame()) {
                return false;
              }
              return spot.x < other.location[0] + other.width + 20.0f &&
                     other.location[0] < spot.x + viewer.width + 20.0f &&
                     spot.y > other.location[1] - rough_height(other) - 20.0f &&
                     other.location[1] > spot.y - height - 20.0f;
            });
        if (!overlaps) {
          break;
        }
        spot.y -= 80.0f;
      }
      copy_v2_v2(viewer.location, spot);
      viewed = true;
      break;
    }
    if (!viewed) {
      return std::nullopt;
    }
    BKE_main_ensure_invariants(*CTX_data_main(C), tree.id);
    if (tree.type == NTREE_COMPOSIT) {
      ED_node_compositor_job(C);
    }
    /* Only a finished operator has pushed its own undo step. */
    return std::string((status & OPERATOR_FINISHED) ? "" : ot->name);
  }
  if (action == "interface_add" || action == "interface_remove" || action == "interface_rename" ||
      action == "interface_move")
  {
    /* The group's inputs and outputs, as Blender's Group panel edits them. */
    bNodeTreeInterface &interface = tree.tree_interface;
    bNodeTreeInterfaceSocket *item = nullptr;
    const std::string identifier = std::string(query.lookup_str("identifier").value_or(""));
    interface.foreach_item([&](bNodeTreeInterfaceItem &candidate) {
      if (candidate.item_type == NODE_INTERFACE_SOCKET) {
        auto &socket = reinterpret_cast<bNodeTreeInterfaceSocket &>(candidate);
        if (socket.identifier && socket.identifier == identifier) {
          item = &socket;
          return false;
        }
      }
      return true;
    });
    if (action == "interface_add") {
      const bool output = query.lookup_int("output").value_or(0) != 0;
      const std::string type = std::string(query.lookup_str("type").value_or("NodeSocketFloat"));
      bke::bNodeSocketType *socket_type = bke::node_socket_type_find(type);
      if (!socket_type || (tree.typeinfo->valid_socket_type &&
                           !tree.typeinfo->valid_socket_type(tree.typeinfo, socket_type)))
      {
        return std::nullopt;
      }
      const std::string name = std::string(query.lookup_str("name").value_or(output ? "Output" : "Input"));
      if (!interface.add_socket(name, "", type,
                                output ? NODE_INTERFACE_SOCKET_OUTPUT : NODE_INTERFACE_SOCKET_INPUT,
                                nullptr))
      {
        return std::nullopt;
      }
    }
    else if (!item) {
      return std::nullopt;
    }
    else if (action == "interface_remove") {
      interface.remove_item(item->item, true);
    }
    else if (action == "interface_rename") {
      const std::string name = std::string(query.lookup_str("name").value_or(""));
      if (name.empty()) {
        return std::nullopt;
      }
      MEM_SAFE_DELETE(item->name);
      item->name = BLI_strdup(name.c_str());
      interface.tag_item_property_changed();
    }
    else {
      interface.move_item(item->item, int(query.lookup_int("position").value_or(0)));
    }
    BKE_main_ensure_invariants(*bmain, tree.id);
    WM_event_add_notifier(C, NC_NODE | NA_EDITED, &tree);
    return std::string(action == "interface_add"    ? "Add Group Socket" :
                       action == "interface_remove" ? "Remove Group Socket" :
                       action == "interface_rename" ? "Rename Group Socket" :
                                                      "Move Group Socket");
  }
  if (action == "key") {
    /* A key the keymap has nothing for does nothing, as in Blender. */
    return native_node_key(C, tree, query).value_or("");
  }
  if (action == "panel" && node) {
    /* A panel opened or closed, as its header's arrow does. */
    const int identifier = int(query.lookup_int("panel").value_or(-1));
    for (bNodePanelState &state : node->panel_states()) {
      if (state.identifier == identifier) {
        state.flag ^= NODE_PANEL_COLLAPSED;
      }
    }
    BKE_ntree_update_tag_node_property(&tree, node);
    BKE_main_ensure_invariants(*bmain, tree.id);
    return std::string("");
  }
  if (action == "rename" && node) {
    STRNCPY(node->label, std::string(query.lookup_str("value").value_or("")).c_str());
    WM_event_add_notifier(C, NC_NODE | NA_EDITED, &tree);
    return std::string("Rename Node");
  }
  return std::nullopt;
}

}  // namespace

/** Composites the scene for the native editor's backdrop and previews, after a read set them. */
void native_nodes_compositor_job(bContext *C)
{
  if (CTX_data_scene(C) && CTX_data_scene(C)->compositing_node_group) {
    ED_node_compositor_job(C);
  }
}

namespace native {

std::string nodes_edit(bContext *C, NodesData & /*data*/, const DictionaryValue &query)
{
  if (!CTX_data_scene(C)) {
    return "This node tree is no longer available.";
  }
  NativeNodeTree shown = native_node_tree(C, query);
  if (!shown.tree) {
    return "This node tree is no longer available.";
  }
  shown.tree->ensure_topology_cache();
  /* Resolved from the viewport's context; edited in a node editor's. */
  NodeSpaceContext node_space(C, shown);
  const std::optional<std::string> undo = apply_node_action(C, *shown.tree, query);
  if (!undo) {
    return "This node change could not be made.";
  }
  if (!undo->empty()) {
    ED_undo_push(C, undo->c_str());
  }
  WM_event_add_notifier(C, NC_NODE | NA_EDITED, shown.tree);
  if (shown.root->type == NTREE_COMPOSIT && query.lookup_str("phase").value_or("") != "update") {
    /* The backdrop and previews follow, as in Blender's editor. */
    ED_node_compositor_job(C);
  }
  return "";
}

std::string nodes_edit_control(bContext *C, NodesData &data, const EditRequest &request)
{
  if (!CTX_data_scene(C)) {
    return "This node tree is no longer available.";
  }
  NativeNodeTree shown = native_node_tree(C, *data.state);
  if (shown.tree) {
    shown.tree->ensure_topology_cache();
  }
  /* A node editor's header offers a tree to pick or make even while there is none. */
  NodeSpaceContext node_space(C, shown);
  bNode *node = shown.tree ? bke::node_find_node_by_name(*shown.tree, request.edit->panel) :
                             nullptr;
  if (!apply_node_property(C, shown.tree, node, request)) {
    return "This value is no longer available.";
  }
  WM_event_add_notifier(C, NC_NODE | NA_EDITED, shown.tree);
  if (shown.root && shown.root->type == NTREE_COMPOSIT && request.phase != "update") {
    ED_node_compositor_job(C);
  }
  return "";
}

/**
 * The tree as records, see #wm::native_ui::records_add: the tree's own values, its nodes'
 * under `nodes/nodes`, each keyed `node:<name>` with its values as controls, see
 * #write_node_fields, and the header's data-block pickers under `header`.
 */
void nodes_write(bContext *C, NodesData &data, ViewBuilder &builder)
{
  Writer writer(C, builder, data);
  const DictionaryValue &query = *data.state;
  DictionaryValue result;
  const auto finish = [&]() {
    result.append_int("ack", data.ack);
    result.append_str("error", data.error);
    return records_add(builder, std::nullopt, "nodes", result);
  };
  if (!CTX_data_scene(C)) {
    finish();
    return;
  }
  NativeNodeTree shown = native_node_tree(C, query);
  if (shown.tree) {
    shown.tree->ensure_topology_cache();
  }
  /* Resolved from the viewport's context; drawn in a node editor's, whose header offers a tree
   * to pick or make even while there is none. */
  std::optional<NodeSpaceContext> node_space;
  node_space.emplace(C, shown);
  if (data.composite) {
    data.composite = false;
    native_nodes_compositor_job(C);
  }
  result.append_str("tree", query.lookup_str("tree").value_or("SHADER"));
  /* The header's data-block picker, as the Properties editor shows one. */
  const auto write_header = [&](const NodeId top) {
    Block *header = native_node_header_block(C);
    writer.panel.clear();
    const NodeId group = writer.group(top, "header", "header");
    for_each_node_field(
        *header,
        [](Button & /*but*/, const int /*index*/, const std::string & /*key*/) {},
        [&](PointerRNA &ptr, PropertyRNA *prop) { writer.picker(group, *header, ptr, prop); });
    block_free(C, header);
  };
  if (!shown.tree) {
    result.append_str("empty", shown.empty);
    result.append_str("create", shown.create);
    write_header(finish());
    return;
  }
  result.append_str("name", shown.tree->id.name + 2);
  result.append_str("owner", shown.owner);
  auto path = result.append_array("path");
  for (bNode *group : shown.path) {
    auto item = path->append_dict();
    item->append_str("name", group->name);
    item->append_str("title", group->id ? group->id->name + 2 : group->name);
  }
  bNodeTree &tree = *shown.tree;
  const std::set<const bNodeSocket *> linked = linked_sockets(tree);
  NodeReadContext read;
  read.space = node_space->space;
  read.scene = CTX_data_scene(C);
  read.parent_key = static_cast<bNodeTreePath *>(read.space->treepath.last)->parent_key;
  if (tree.type == NTREE_GEOMETRY) {
    read.geo_logs = nodes::geo_eval_log::GeoNodesLog::get_contextual_tree_logs(*read.space);
    read.geo_logs.foreach_tree_log([&](nodes::geo_eval_log::GeoTreeLog &log) {
      log.ensure_node_warnings(*CTX_data_main(C));
      log.ensure_execution_times();
    });
  }
  else if (tree.type == NTREE_SHADER && query.lookup_int("previews").value_or(0) &&
           std::any_of(tree.nodes.begin(), tree.nodes.end(),
                       [](const bNode &node) { return node.flag & NODE_PREVIEW; }))
  {
    read.shader_previews = ed::space_node::get_nested_previews(*C, *read.space);
  }
  else if (tree.type == NTREE_COMPOSIT) {
    read.compositor_previews = &shown.root->runtime->previews;
  }
  /* The compositor's Viewer, behind the nodes as Blender's backdrop. */
  /* Only with a node plugged into a Viewer, through any reroutes: otherwise its result is an
   * empty, black frame. */
  const auto fed = [](const bNodeSocket &input) {
    const bNodeLink *link = input.link;
    for (int depth = 0; link && depth < 64; depth++) {
      const bNode *from = link->fromnode;
      if (!from || !from->is_reroute()) {
        return from != nullptr && !link->is_muted();
      }
      const bNodeSocket *through = static_cast<const bNodeSocket *>(from->inputs.first);
      link = through ? through->link : nullptr;
    }
    return false;
  };
  const bool viewed = std::any_of(tree.nodes.begin(), tree.nodes.end(), [&](const bNode &node) {
    return STREQ(node.idname, "CompositorNodeViewer") &&
           std::any_of(node.inputs.begin(), node.inputs.end(), fed);
  });
  if (tree.type == NTREE_COMPOSIT && viewed && query.lookup_int("backdrop").value_or(0)) {
    Main *bmain = CTX_data_main(C);
    Image *viewer = BKE_image_ensure_viewer(bmain, IMA_TYPE_COMPOSITE, "Viewer Node");
    void *lock;
    ImageUser user = {};
    ImBuf *ibuf = BKE_image_acquire_ibuf(viewer, &user, &lock);
    /* Nothing rendered yet, its picture is all black: no backdrop, rather than a black canvas. */
    const auto empty = [](const ImBuf *ibuf) {
      if (!ibuf || ibuf->x <= 0 || ibuf->y <= 0) {
        return true;
      }
      const int64_t count = int64_t(ibuf->x) * ibuf->y;
      const int64_t step = std::max<int64_t>(1, count / 4096);
      for (int64_t i = 0; i < count; i += step) {
        if (const float *pixel = ibuf->float_buffer.data ? ibuf->float_buffer.data + i * 4 : nullptr) {
          if (pixel[0] > 0.004f || pixel[1] > 0.004f || pixel[2] > 0.004f) {
            return false;
          }
        }
        else if (const uint8_t *pixel = ibuf->byte_buffer.data ? ibuf->byte_buffer.data + i * 4 : nullptr)
        {
          if (pixel[0] > 1 || pixel[1] > 1 || pixel[2] > 1) {
            return false;
          }
        }
      }
      return true;
    };
    const std::string path = empty(ibuf) ? std::string() :
                                           native_preview_path(read.scene, ibuf, "backdrop");
    BKE_image_release_ibuf(viewer, ibuf, lock);
    if (!path.empty()) {
      result.append_str("backdrop", path);
    }
  }
  /* A group's inputs and outputs, which its interface list edits. */
  if (!shown.path.is_empty() || !(tree.id.flag & ID_FLAG_EMBEDDED_DATA)) {
    auto interface = result.append_array("interface");
    tree.tree_interface.foreach_item([&](const bNodeTreeInterfaceItem &candidate) {
      if (candidate.item_type == NODE_INTERFACE_SOCKET) {
        const auto &socket = reinterpret_cast<const bNodeTreeInterfaceSocket &>(candidate);
        auto entry = interface->append_dict();
        entry->append_str("identifier", socket.identifier ? socket.identifier : "");
        entry->append_str("name", socket.name ? socket.name : "");
        entry->append_str("type", socket.socket_type ? socket.socket_type : "");
        entry->append_int("output", (socket.flag & NODE_INTERFACE_SOCKET_OUTPUT) != 0);
        if (bke::bNodeSocketType *type = socket.socket_type ? bke::node_socket_type_find(socket.socket_type) : nullptr) {
          float color[4] = {0.6f, 0.6f, 0.6f, 1.0f};
          if (type->draw_color_simple) {
            type->draw_color_simple(type, color);
          }
          auto rgb = entry->append_array("color");
          for (int i = 0; i < 3; i++) {
            rgb->append_double(color[i]);
          }
        }
      }
      return true;
    });
    /* The kinds of socket the tree can have. */
    auto types = result.append_array("socket_types");
    for (const char *idname : {"NodeSocketGeometry", "NodeSocketFloat", "NodeSocketInt", "NodeSocketBool",
                               "NodeSocketVector", "NodeSocketColor", "NodeSocketRotation", "NodeSocketMatrix",
                               "NodeSocketString", "NodeSocketMenu", "NodeSocketShader", "NodeSocketObject",
                               "NodeSocketCollection", "NodeSocketMaterial", "NodeSocketImage", "NodeSocketBundle",
                               "NodeSocketClosure"})
    {
      bke::bNodeSocketType *type = bke::node_socket_type_find(idname);
      if (type && (!tree.typeinfo->valid_socket_type ||
                   tree.typeinfo->valid_socket_type(tree.typeinfo, type)))
      {
        auto entry = types->append_dict();
        entry->append_str("idname", idname);
        entry->append_str("name", type->label.empty() ? idname + 10 : type->label.c_str());
      }
    }
  }
  if (tree.type == NTREE_COMPOSIT) {
    result.append_int("can_backdrop", 1);
  }
  if (native_node_key_request.sequence) {
    auto key = result.append_dict("key_request");
    key->append_int("sequence", native_node_key_request.sequence);
    key->append_str("action", native_node_key_request.action);
    key->append_str("node", native_node_key_request.node);
  }
  /* What the compositor computes for this editor: its backdrop and the previews turned on. */
  ED_node_compositor_native_outputs_set(
      tree.type == NTREE_COMPOSIT && query.lookup_int("backdrop").value_or(0),
      tree.type == NTREE_COMPOSIT &&
          std::any_of(tree.nodes.begin(), tree.nodes.end(), [](const bNode &node) {
            return node.flag & NODE_PREVIEW;
          }));
  auto links = result.append_array("links");
  for (const bNodeLink &link : tree.links) {
    if (!link.fromnode || !link.tonode || !link.fromsock || !link.tosock ||
        !link.fromsock->is_visible() || !link.tosock->is_visible())
    {
      continue;
    }
    auto item = links->append_dict();
    item->append_str("from_node", link.fromnode->name);
    item->append_str("from_socket", link.fromsock->identifier);
    item->append_str("to_node", link.tonode->name);
    item->append_str("to_socket", link.tosock->identifier);
    item->append_int("valid", (link.flag & NODE_LINK_VALID) != 0);
    item->append_int("muted", (link.flag & NODE_LINK_MUTED) != 0);
  }
  /* Zones (repeat, simulation, for each), drawn around their nodes, inner zones on top. */
  if (const bke::bNodeTreeZones *zones = tree.zones()) {
    auto zone_items = result.append_array("zones");
    for (const bke::bNodeTreeZone *zone : zones->zones) {
      const bNode *input = zone->input_node();
      const bNode *output = zone->output_node();
      if (!output) {
        continue;
      }
      auto item = zone_items->append_dict();
      item->append_int("depth", zone->depth);
      auto members = item->append_array("nodes");
      if (input) {
        members->append_str(input->name);
      }
      members->append_str(output->name);
      for (const bNode *child : zone->child_nodes()) {
        members->append_str(child->name);
      }
      /* Child zones are inside too. */
      for (const bke::bNodeTreeZone *other : zones->zones) {
        if (other != zone && zone->contains_zone_recursively(*other)) {
          if (const bNode *other_output = other->output_node()) {
            members->append_str(other_output->name);
          }
          if (const bNode *other_input = other->input_node()) {
            members->append_str(other_input->name);
          }
        }
      }
      item->append_str("kind", output->typeinfo->ui_name);
    }
  }
  /* The nodes it can add, once for each tree. */
  const std::string add_for = std::to_string(tree.id.session_uid);
  if (add_for != data.add_for) {
    data.add_for = add_for;
    project_node_add_items(C, tree, *result.append_array("add"));
  }
  const NodeId top = finish();
  write_header(top);
  const NodeId nodes = writer.group(top, "nodes/nodes", "nodes");
  for (bNode &node : tree.nodes) {
    DictionaryValue item;
    project_node(tree, node, linked, item, read);
    const std::string key = "node:" + std::string(node.name);
    const NodeId record = records_add(builder, nodes, key, item);
    if (!node.is_frame() && !node.is_reroute()) {
      write_node_fields(writer, record, key, tree, node, linked);
    }
  }
}

}  // namespace native


/** \} */

}  // namespace blender::ui

void UI_native_panel_census_record(const bool on)
{
  blender::ui::census_recording = on;
  if (!on) {
    blender::ui::census_log.reset();
  }
}

const char *UI_native_panel_census_take()
{
  static std::string text;
  std::stringstream stream;
  blender::io::serialize::JsonFormatter formatter;
  if (!blender::ui::census_log) {
    blender::ui::census_log = std::make_shared<blender::io::serialize::ArrayValue>();
  }
  formatter.serialize(stream, *blender::ui::census_log);
  blender::ui::census_log.reset();
  text = stream.str();
  return text.c_str();
}
