/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** Native Properties projects the registered Blender panels and their RNA controls. */
#include "BKE_animsys.h"
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
#include "BKE_vfont.hh"
#include "BLI_array.hh"
#include "BLI_listbase.h"
#include "BLI_rect.h"
#include "BLI_serialize.hh"
#include "DEG_depsgraph.hh"
#include "DEG_depsgraph_build.hh"
#include "DNA_ID.h"
#include "DNA_curve_types.h"
#include "DNA_modifier_types.h"
#include "DNA_object_types.h"
#include "DNA_space_types.h"
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
#include "wm_event_system.hh"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <map>
#include <set>
#include <sstream>
#include <vector>

namespace blender::ui {
std::string native_menu_query(bContext *C, const std::string &request, bool execute);
namespace {
using namespace io::serialize;

std::string encode(const Value &value)
{
  std::ostringstream stream;
  JsonFormatter().serialize(stream, value);
  return stream.str();
}

std::unique_ptr<Value> decode(const std::string &json)
{
  std::istringstream stream(json);
  return JsonFormatter().deserialize(stream);
}

/* A detached Properties space provides the same context as the desktop editor,
 * without changing the visible area or retaining scene pointers between requests. */
struct PropertiesContext {
  bContext *C;
  ScrArea *previous_area;
  ARegion *previous_region;
  ScrArea area = {};
  SpaceProperties *space;
  ARegion *region;

  PropertiesContext(bContext *context) : C(context)
  {
    previous_area = CTX_wm_area(C);
    previous_region = CTX_wm_region(C);
    area.spacetype = SPACE_PROPERTIES;
    area.type = BKE_spacetype_from_id(SPACE_PROPERTIES);
    SpaceLink *link = area.type->create(&area, CTX_data_scene(C));
    BLI_addtail(&area.spacedata, link);
    std::swap(area.regionbase, link->regionbase);
    space = reinterpret_cast<SpaceProperties *>(link);
    region = BKE_area_find_region_type(&area, RGN_TYPE_WINDOW);
    region->runtime->type = BKE_regiontype_from_id(area.type, RGN_TYPE_WINDOW);
    region->winx = 320;
    region->winy = 1200;
    area.winx = region->winx;
    area.winy = region->winy;
    CTX_wm_area_set(C, &area);
    CTX_wm_region_set(C, region);
    ED_buttons_native_context_prepare(C, space);
  }

  ~PropertiesContext()
  {
    /* Instanced modifier/constraint panels can start window-level animation handlers.
     * Retire those handlers and timers before freeing their temporary panels. */
    panels_free_instanced(C, region);
    CTX_wm_area_set(C, previous_area);
    CTX_wm_region_set(C, previous_region);
    BKE_screen_area_free(&area);
  }
};

std::string icon_name(const int icon)
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

bool set_property(bContext *C,
                  Button &but,
                  int index,
                  const DictionaryValue &request,
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
  const auto number = request.lookup_double("value");
  const auto integer = request.lookup_int("value");
  const double numeric = number.value_or(integer.value_or(0));
  const auto phase = request.lookup_str("phase").value_or("");
  const std::string token = request.lookup_str("interaction").value_or("");
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
        const auto *components = request.lookup_array("value");
        const int length = RNA_property_array_length(ptr, prop);
        if (!components || components->elements().size() != length) {
          return false;
        }
        float color[4] = {0, 0, 0, 1};
        for (int i = 0; i < length; i++) {
          const auto &component = components->elements()[i];
          const auto *real = component->as_double_value();
          const auto *integer_component = component->as_int_value();
          if (!real && !integer_component) {
            return false;
          }
          const double value = real ? real->value() : double(integer_component->value());
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
      if ((!number && !integer) || !std::isfinite(numeric)) {
        return false;
      }
      float minimum, maximum;
      RNA_property_float_range(ptr, prop, &minimum, &maximum);
      const float value = std::clamp(float(numeric), minimum, maximum);
      if (request.lookup_dict("slider") && others.items.is_empty() && value == (array ? RNA_property_float_get_index(ptr, prop, index) : RNA_property_float_get(ptr, prop))) {
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
      if ((!number && !integer) || !std::isfinite(numeric)) {
        return false;
      }
      int minimum, maximum;
      RNA_property_int_range(ptr, prop, &minimum, &maximum);
      const int value = int(std::clamp(numeric, double(minimum), double(maximum)));
      if (request.lookup_dict("slider") && others.items.is_empty() && value == (array ? RNA_property_int_get_index(ptr, prop, index) : RNA_property_int_get(ptr, prop))) {
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
      const auto *raw = request.lookup("value");
      const BooleanValue *value = raw ? (*raw)->as_boolean_value() : nullptr;
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
      const auto value = request.lookup_str("value");
      if (!value) {
        return false;
      }
      RNA_property_string_set(ptr, prop, value->c_str());
      break;
    }
    case PROP_ENUM: {
      const auto value = request.lookup_str("value");
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
      const auto value = request.lookup_str("value");
      if (!value || !RNA_struct_is_ID(RNA_property_pointer_type(ptr, prop))) {
        return false;
      }
      PointerRNA target = PointerRNA_NULL;
      if (!value->is_empty()) {
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

/* Blender's widget animation colors: keyed on this frame, animated, changed from the
 * animated value, or driven. Empty when the property has no animation data. */
const char *property_animation_state(bContext *C, Button &but, int index)
{
  if (!RNA_property_path_from_ID_check(&but.rnapoin, but.rnaprop)) {
    return "";
  }
  const int old_index = but.rnaindex, old_flag = but.flag, old_drawflag = but.drawflag;
  but.rnaindex = index;
  const AnimationEvalContext eval = BKE_animsys_eval_context_construct(
      CTX_data_depsgraph_pointer(C), BKE_scene_frame_get(CTX_data_scene(C)));
  button_anim_flag(&but, &eval);
  const char *state = (but.flag & BUT_DRIVEN)               ? "DRIVEN" :
                      (but.drawflag & BUT_ANIMATED_CHANGED) ? "CHANGED" :
                      (but.flag & BUT_ANIMATED_KEY)         ? "KEYED" :
                      (but.flag & BUT_ANIMATED)             ? "ANIMATED" :
                                                              "";
  but.rnaindex = old_index;
  but.flag = old_flag;
  but.drawflag = old_drawflag;
  return state;
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

/** Menus several fields share, while a node tree is read: each one once, by its choices. */
struct NativeOptionSets {
  std::set<std::string> keys;
  std::shared_ptr<DictionaryValue> sets = std::make_shared<DictionaryValue>();
};
NativeOptionSets *native_option_sets = nullptr;

void project_property(bContext *C, Button &but, int index, DictionaryValue &field,
                      const PropertyPair *pair = nullptr, const std::string *layout_name = nullptr,
                      const SelectedOthers *others = nullptr)
{
  PointerRNA *ptr = &but.rnapoin;
  PropertyRNA *prop = but.rnaprop;
  /* ID properties (e.g. Geometry Nodes inputs, "Socket_2") are only named by their layout. */
  /* Node socket values (e.g. material inputs) are all "default_value"; name them by socket. */
  const bool socket_value = RNA_struct_is_a(ptr->type, RNA_NodeSocket) &&
                            STREQ(RNA_property_identifier(prop), "default_value");
  const std::string name =
      layout_name && !layout_name->empty() && RNA_property_is_idprop(prop) ? *layout_name :
      socket_value ? std::string(ed::space_node::node_socket_get_label(
                         static_cast<const bNodeSocket *>(ptr->data))) :
                     std::string(RNA_property_ui_name(prop));
  const bool array = RNA_property_array_check(prop);
  const int length = RNA_property_array_length(ptr, prop);
  const PropertyType type = RNA_property_type(prop);
  if (const char *state = property_animation_state(C, but, index); state[0]) {
    field.append_str("anim_state", state);
  }
  const auto actions = property_animation_actions(C, but, index);
  if (!actions.empty()) {
    auto animation = field.append_array("animation");
    for (const PropertyAnimationAction &action : actions) {
      auto item = animation->append_dict();
      item->append_str("id", action.id);
      item->append_str("title", action.title);
      item->append_str("icon", action.icon);
    }
  }
  const SelectedOthers own_others = others ? SelectedOthers() : selected_others(C, but);
  if (others_differ(but, is_color(ptr, prop) ? -1 : index, others ? *others : own_others)) {
    field.append_int("mixed", 1);
  }
  if (is_color(ptr, prop)) {
    float color[4] = {0, 0, 0, 1};
    RNA_property_float_get_array(ptr, prop, color);
    const float exposure = std::max({1.0f, color[0], color[1], color[2]});
    if (RNA_property_subtype(prop) == PROP_COLOR) {
      IMB_colormanagement_scene_linear_to_srgb_v3(color, color);
    }
    field.append_str("type", "COLOR");
    field.append_str("label", name);
    field.append_str("key", property_key(but, -1));
    field.append_str("property", RNA_property_identifier(prop));
    field.append_str("owner", RNA_struct_is_a(ptr->type, RNA_Object) ? "object" : "data");
    field.append_int("alpha", length == 4);
    field.append_double("exposure", std::isfinite(exposure) ? exposure : 1);
    field.append_int("editable", RNA_property_editable(ptr, prop) &&
        !(but.flag & (BUT_DISABLED | BUT_INACTIVE)));
    auto values = field.append_array("value");
    for (int i = 0; i < length; i++) {
      values->append_double(std::isfinite(color[i]) ? color[i] : 0);
    }
    return;
  }
  std::string title = name;
  if (pair) {
    title = pair->component;
    field.append_str("group", pair->title);
    field.append_str("group_key", pair->key);
  }
  else if (array && length <= 4) {
    const bool color = ELEM(RNA_property_subtype(prop), PROP_COLOR, PROP_COLOR_GAMMA);
    const char *axes = color ? "RGBA" : length == 4 ? "WXYZ" : "XYZW";
    title = std::string(1, axes[index]);
    field.append_str("group", ELEM(std::string(RNA_property_identifier(prop)),
                                   "rotation_euler", "rotation_quaternion", "rotation_axis_angle") ?
                                  "Rotation" : name);
    field.append_str("group_key", property_key(but, -1));
  }
  field.append_str("label", title);
  field.append_str("key", property_key(but, index));
  field.append_str("property", RNA_property_identifier(prop));
  field.append_str("owner", RNA_struct_is_a(ptr->type, RNA_Object) ? "object" : "data");
  if (array) {
    field.append_int("index", index);
  }
  field.append_int("editable", RNA_property_editable(ptr, prop) &&
      !(but.flag & (BUT_DISABLED | BUT_INACTIVE)));
  field.append_str("icon", icon_name(button_icon(&but)));
  if (but.type == ButtonType::NumSlider && ELEM(type, PROP_INT, PROP_FLOAT) &&
      std::isfinite(but.softmin) && std::isfinite(but.softmax) && but.softmax > but.softmin) {
    auto slider = field.append_dict("slider");
    slider->append_double("min", but.softmin);
    slider->append_double("max", but.softmax);
    const PropertyScaleType scale = button_scale_type(&but);
    slider->append_str("scale", scale == PROP_SCALE_LOG && but.softmin > 0 ? "LOG" :
                                scale == PROP_SCALE_CUBIC ? "CUBIC" : "LINEAR");
  }
  if (but.type == ButtonType::Num && ELEM(type, PROP_INT, PROP_FLOAT)) {
    const double step = type == PROP_INT ? 0.5 :
        0.01 * static_cast<ButtonNumber &>(but).step_size;
    field.append_double("dragStep", std::isfinite(step) && step > 0 ? step : 0.01);
    /* Dragging speeds up over a wide range, as Blender's own number buttons do. */
    const double soft_range = double(but.softmax) - double(but.softmin);
    if (std::isfinite(soft_range) && soft_range > 0) {
      field.append_double("softRange", soft_range);
    }
  }
  switch (type) {
    case PROP_BOOLEAN:
      field.append_str("type", "BOOLEAN");
      field.append("value", std::make_shared<BooleanValue>(array ? RNA_property_boolean_get_index(ptr, prop, index) : RNA_property_boolean_get(ptr, prop)));
      break;
    case PROP_INT: {
      field.append_str("type", "INT");
      field.append_int("value", array ? RNA_property_int_get_index(ptr, prop, index) : RNA_property_int_get(ptr, prop));
      int minimum, maximum;
      RNA_property_int_range(ptr, prop, &minimum, &maximum);
      field.append_int("min", minimum);
      field.append_int("max", maximum);
      break;
    }
    case PROP_FLOAT: {
      field.append_str("type", "FLOAT");
      const double value = array ? RNA_property_float_get_index(ptr, prop, index) : RNA_property_float_get(ptr, prop);
      field.append_double("value", std::isfinite(value) ? value : 0);
      float minimum, maximum;
      RNA_property_float_range(ptr, prop, &minimum, &maximum);
      field.append_double("min", minimum);
      field.append_double("max", maximum);
      field.append_int("angle", ELEM(RNA_property_subtype(prop), PROP_ANGLE, PROP_EULER));
      break;
    }
    case PROP_STRING:
      field.append_str("type", "STRING");
      field.append_str("value", RNA_property_string_get(ptr, prop));
      break;
    case PROP_ENUM: {
      field.append_str("type", "ENUM");
      const int selected = RNA_property_enum_get(ptr, prop);
      /* Many nodes share a menu (each Math node's operations): sent once, see #NativeOptionSets. */
      const bool shared = native_option_sets && !(RNA_property_flag(prop) & PROP_ENUM_FLAG);
      std::shared_ptr<ArrayValue> shared_options = shared ? std::make_shared<ArrayValue>() : nullptr;
      auto options = shared ? shared_options : field.append_array("options");
      std::string shared_key;
      const EnumPropertyItem *items;
      int count;
      bool free;
      RNA_property_enum_items(C, ptr, prop, &items, &count, &free);
      std::string current;
      for (int i = 0; i < count; i++) {
        const auto &item = items[i];
        if (!item.identifier || !item.identifier[0]) {
          continue;
        }
        auto option = options->append_dict();
        option->append_str("value", item.identifier);
        option->append_str("label", item.name);
        option->append_str("icon", icon_name(item.icon));
        if (const std::string preview = preview_icon_path(C, item.icon); !preview.empty()) {
          option->append_str("preview", preview);
        }
        const bool checked = (RNA_property_flag(prop) & PROP_ENUM_FLAG) ?
                                 (selected & item.value) != 0 : selected == item.value;
        if (shared) {
          shared_key += item.identifier;
          shared_key += ',';
        }
        else {
          option->append_int("checked", checked);
        }
        if (checked) {
          current = item.identifier;
        }
      }
      field.append_str("value", current);
      if (shared) {
        const std::string key = std::to_string(std::hash<std::string>{}(shared_key));
        if (native_option_sets->keys.insert(key).second) {
          native_option_sets->sets->append(key, shared_options);
        }
        field.append_str("options_ref", key);
      }
      if (free) {
        MEM_delete(items);
      }
      break;
    }
    case PROP_POINTER: {
      field.append_str("type", "ENUM");
      PointerRNA current = RNA_property_pointer_get(ptr, prop);
      field.append_str("value", current.owner_id ? std::to_string(current.owner_id->session_uid) : "");
      auto options = field.append_array("options");
      auto empty = options->append_dict();
      empty->append_str("value", "");
      empty->append_str("label", "None");
      ID *id;
      FOREACH_MAIN_ID_BEGIN (CTX_data_main(C), id) {
        PointerRNA candidate = RNA_id_pointer_create(id);
        if (RNA_struct_is_a(candidate.type, RNA_property_pointer_type(ptr, prop)) &&
            RNA_property_pointer_poll(ptr, prop, &candidate)) {
          auto option = options->append_dict();
          option->append_str("value", std::to_string(id->session_uid));
          option->append_str("label", id->name + 2);
          option->append_str("icon", icon_name(RNA_struct_ui_icon(candidate.type)));
        }
      }
      FOREACH_MAIN_ID_END;
      break;
    }
    default:
      field.append_str("type", "LABEL");
      field.append_str("value", "");
      break;
  }
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

void project_id_template(bContext *C,
                         const Block &block,
                         const PointerRNA &ptr_const,
                         PropertyRNA *prop,
                         DictionaryValue &field)
{
  PointerRNA ptr = ptr_const;
  StructRNA *type = RNA_property_pointer_type(&ptr, prop);
  const short idcode = RNA_type_to_ID_code(type);
  ID *id = RNA_property_pointer_get(&ptr, prop).owner_id;
  field.append_str("type", "ID");
  field.append_str("key", id_template_key(ptr, prop));
  field.append_str("label", RNA_property_ui_name(prop));
  field.append_str("id_type", RNA_struct_ui_name(type));
  field.append_str("icon", icon_name(RNA_struct_ui_icon(type)));
  field.append_int("editable",
                   RNA_property_editable(&ptr, prop) &&
                       (!ptr.owner_id || ID_IS_EDITABLE(ptr.owner_id)));
  field.append_str("value", id ? std::to_string(id->session_uid) : "");
  const Button *new_button = id_template_part(block, ptr, prop, UI_ID_ADD_NEW);
  field.append_int("can_new", new_button && new_button->optype && new_button->optype->exec &&
                                  !(new_button->flag & BUT_DISABLED));
  if (idcode == ID_VF) {
    /* Fonts are chosen with the system's font picker, see `load_font`. */
    field.append_int("font_picker", 1);
    field.append_str("font_role", RNA_property_identifier(prop));
    if (id) {
      field.append_str("font_file", reinterpret_cast<VFont *>(id)->filepath);
    }
    /* The regular font, whose family the bold and italic fonts are shown against. */
    if (PropertyRNA *regular = RNA_struct_find_property(&ptr, "font")) {
      if (ID *regular_id = RNA_property_pointer_get(&ptr, regular).owner_id) {
        field.append_str("family_file", reinterpret_cast<VFont *>(regular_id)->filepath);
      }
    }
  }
  if (id) {
    field.append_str("name", id->name + 2);
    field.append_int("users", id->us);
    field.append_int("linked", ID_IS_LINKED(id));
    if (!ID_IS_LINKED(id) && !ELEM(GS(id->name), ID_GR, ID_SCE, ID_SCR, ID_OB, ID_WS)) {
      field.append_int("fake_user", (id->flag & ID_FLAG_FAKEUSER) != 0);
    }
    const Button *unlink = id_template_part(block, ptr, prop, UI_ID_DELETE);
    if (!unlink) {
      unlink = id_template_part(block, ptr, prop, UI_ID_NOP);
    }
    field.append_int("can_unlink", unlink && !(RNA_property_flag(prop) & PROP_NEVER_NULL));
    field.append_int("can_single_user",
                     id->us > 1 && id_template_part(block, ptr, prop, UI_ID_ALONE) != nullptr);
    field.append_str("preview", id_preview_path(C, id));
  }
  auto options = field.append_array("options");
  Main *bmain = CTX_data_main(C);
  if (ListBaseT<ID> *ids = idcode ? which_libbase(bmain, idcode) : nullptr) {
    for (ID &candidate : *ids) {
      /* Blender's search hides names starting with a dot unless typed. */
      if (candidate.name[2] == '.' && &candidate != id) {
        continue;
      }
      PointerRNA candidate_ptr = RNA_id_pointer_create(&candidate);
      if (!RNA_property_pointer_poll(&ptr, prop, &candidate_ptr)) {
        continue;
      }
      auto option = options->append_dict();
      option->append_str("value", std::to_string(candidate.session_uid));
      option->append_str("label", candidate.name + 2);
      option->append_int("users", candidate.us);
      if (ID_IS_LINKED(&candidate)) {
        option->append_int("linked", 1);
      }
      if (const std::string preview = id_preview_path(C, &candidate); !preview.empty()) {
        option->append_str("preview", preview);
      }
    }
  }
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
                       const DictionaryValue &request,
                       wmOperatorType *&r_operator_type,
                       PointerRNA *&r_operator_properties,
                       std::unique_ptr<bContextStore> &r_operator_context,
                       PendingNewID &r_pending)
{
  PointerRNA ptr = ptr_const;
  if (!RNA_property_editable(&ptr, prop)) {
    return false;
  }
  const std::string action = request.lookup_str("id_action").value_or("");
  const std::string value = request.lookup_str("value").value_or("");
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
    if (const DictionaryValue *family = request.lookup_dict("family")) {
      for (const auto &[key, path] : family->elements()) {
        PropertyRNA *style = RNA_struct_find_property(&ptr, key.c_str());
        const StringValue *style_path = path->as_string_value();
        if (style && style_path && RNA_property_type(style) == PROP_POINTER &&
            RNA_property_pointer_type(&ptr, style) == RNA_VectorFont)
        {
          if (VFont *style_font = load(style_path->value())) {
            assign(style, style_font);
          }
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

/** The buttons beside a list or tree: add, remove, its menu and other operators. */
void project_list_side(bContext *C,
                       const ListSide *side,
                       const Object *object,
                       DictionaryValue &field,
                       const bool reorder = true)
{
  if (side) {
    auto add_operator = [&](const char *name, Button *but) {
      if (!but || !but->optype) {
        return;
      }
      auto entry = field.append_dict(name);
      entry->append_str("key", operator_key(C, *but, object));
      entry->append_str("label", but->str.empty() ? WM_operatortype_name(but->optype, but->opptr) :
                                                    but->str);
      entry->append_str("icon", icon_name(button_icon(but)));
      entry->append_int("editable", !(but->flag & (BUT_DISABLED | BUT_INACTIVE)));
    };
    add_operator("add", side->add);
    add_operator("remove", side->remove);
    /* Duplicating the active item, for the iPad's swipe action. Lists offer it differently (in
     * their menu, or as Add), so it is known by the list's Add operator. */
    if (side->add && side->add->optype) {
      static const std::pair<const char *, const char *> duplicates[] = {
          {"OBJECT_OT_shape_key_add", "OBJECT_OT_shape_key_copy"},
          {"OBJECT_OT_vertex_group_add", "OBJECT_OT_vertex_group_copy"},
          {"GEOMETRY_OT_color_attribute_add", "GEOMETRY_OT_color_attribute_duplicate"},
          {"GREASE_PENCIL_OT_layer_add", "GREASE_PENCIL_OT_layer_duplicate"},
          {"MESH_OT_uv_texture_add", "MESH_OT_uv_texture_add"},
      };
      for (const auto &[add, duplicate] : duplicates) {
        if (STREQ(side->add->optype->idname, add)) {
          field.append_str("duplicate", duplicate);
          break;
        }
      }
    }
    field.append_int("reorder", reorder && side->up && side->down &&
                                    !(side->up->flag & (BUT_DISABLED | BUT_INACTIVE)));
    if (side->menu) {
      field.append_str("menu", side->menu->idname);
    }
    if (!side->extras.empty()) {
      auto extras = field.append_array("extras");
      for (Button *but : side->extras) {
        auto entry = extras->append_dict();
        entry->append_str("key", operator_key(C, *but, object));
        entry->append_str("label", but->str.empty() ? WM_operatortype_name(but->optype, but->opptr) :
                                                      but->str);
        entry->append_str("icon", icon_name(button_icon(but)));
      }
    }
  }
}

/** One item's name, icon and the controls drawn over its row, from the buttons on the row. */
void project_list_row(bContext *C,
                      const std::vector<const Button *> &items,
                      DictionaryValue &row,
                      const StringRef fallback_label = "")
{
  std::string label;
  int icon = ICON_NONE;
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
        row.append_str("rename_key", property_key(*item, -1));
      }
    }
    else if (ELEM(item->type, ButtonType::Label, ButtonType::Text) && !item->str.empty()) {
      label = item->str;
    }
  }
  row.append_str("label", label.empty() ? std::string(fallback_label) : label);
  /* What the row draws beside its name, such as a shape key's value and mute toggle or a
   * vertex group's lock: edited through the same keys as any other property. */
  std::shared_ptr<ArrayValue> controls;
  for (const Button *item : items) {
    if ((item->flag & UI_HIDDEN) || !item->rnaprop || !item->rnapoin.data ||
        RNA_property_array_check(item->rnaprop) ||
        !ELEM(RNA_property_type(item->rnaprop), PROP_BOOLEAN, PROP_INT, PROP_FLOAT, PROP_ENUM))
    {
      continue;
    }
    if (!controls) {
      controls = row.append_array("controls");
    }
    auto control = controls->append_dict();
    project_property(C, const_cast<Button &>(*item), -1, *control);
    control->append_int("native", 1);
  }
  if (icon >= BIFICONID_LAST_STATIC) {
    row.append_str("preview", preview_icon_path(C, icon));
    icon = ICON_NONE;
  }
  row.append_str("icon", icon_name(icon));
}

/** A list's rows, from its row buttons and the item buttons each one draws over. */
void project_list(bContext *C,
                  const Block &block,
                  const Button &first_row,
                  const std::map<const Button *, std::vector<const Button *>> &row_items,
                  const ListSide *side,
                  const Object *object,
                  DictionaryValue &field)
{
  project_list_side(C, side, object, field);
  PointerRNA active_ptr = first_row.rnapoin;
  field.append_str("type", "LIST");
  field.append_str("key", property_key(first_row, -1));
  field.append_str("label", "");
  field.append_int("value", RNA_property_int_get(&active_ptr, first_row.rnaprop));
  field.append_int("editable", RNA_property_editable(&active_ptr, first_row.rnaprop));
  auto rows = field.append_array("rows");
  for (const auto &button : block.buttons) {
    if (button->type != ButtonType::ListRow || button->rnapoin.data != first_row.rnapoin.data ||
        button->rnaprop != first_row.rnaprop)
    {
      continue;
    }
    auto row = rows->append_dict();
    row->append_int("index", int(button->hardmax));
    const auto items = row_items.find(button.get());
    if (items == row_items.end()) {
      row->append_str("label", "");
      row->append_str("icon", "");
      continue;
    }
    project_list_row(C, items->second, *row);
  }
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

/** A tree, shown as a list: its items in order, indented by depth. */
void project_tree(bContext *C,
                  const TreeRows &tree,
                  const std::map<const Button *, std::vector<const Button *>> &row_items,
                  const Object *object,
                  const std::string &key,
                  DictionaryValue &field)
{
  bool nested = false;
  for (const ButtonViewItem *button : tree.items) {
    nested |= tree_item(*button)->count_parents() > 0;
  }
  project_list_side(C, &tree.side, object, field, !nested);
  field.append_str("type", "LIST");
  field.append_str("key", key);
  field.append_str("label", "");
  field.append_int("editable", 1);
  int active = -1;
  auto rows = field.append_array("rows");
  for (int index = 0; index < int(tree.items.size()); index++) {
    const ButtonViewItem *button = tree.items[index];
    const AbstractTreeViewItem *item = tree_item(*button);
    /* What the item says should be active (a shape key: the object's active key), rather than
     * the view's own flag, which only follows it as Blender's editor redraws. Reading the flag
     * here showed the previous item after a tap for a moment. */
    const std::optional<bool> wanted =
        static_cast<const AbstractViewItem *>(item)->should_be_active();
    if (wanted.value_or(item->is_active())) {
      active = index;
    }
    auto row = rows->append_dict();
    row->append_int("index", index);
    if (const int depth = item->count_parents()) {
      row->append_int("depth", depth);
    }
    if (item->supports_renaming()) {
      row->append_int("rename", 1);
    }
    const auto items = row_items.find(button);
    project_list_row(C,
                     items == row_items.end() ? std::vector<const Button *>() : items->second,
                     *row,
                     /* Public on the base, where tree items override it. */
                     static_cast<const AbstractViewItem *>(item)->get_rename_string());
  }
  field.append_int("value", active);
}

/** Select, rename or reorder a tree's item, as #project_tree shows them. */
bool apply_tree(bContext *C, const TreeRows &tree, const DictionaryValue &query)
{
  const std::string action = query.lookup_str("list_action").value_or("");
  auto item_at = [&](const int64_t index) -> AbstractViewItem * {
    return index >= 0 && index < int64_t(tree.items.size()) ? tree.items[index]->view_item :
                                                                nullptr;
  };
  if (action == "rename") {
    AbstractViewItem *item = item_at(query.lookup_int("index").value_or(-1));
    const auto name = query.lookup_str("name");
    return item && name && item->supports_renaming() && item->rename(*C, *name);
  }
  if (action == "move") {
    /* Make the item active, then move it as the arrows beside the tree do. */
    const int64_t from = query.lookup_int("from").value_or(-1);
    const int64_t to = query.lookup_int("to").value_or(-1);
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
  AbstractViewItem *item = item_at(query.lookup_int("value").value_or(-1));
  if (!item) {
    return false;
  }
  item->activate(*C);
  return true;
}

/** \} */
}  // namespace

namespace {
/* Engine-owned identity, invalidated before the operator's memory can be reused. */
wmOperator *native_redo_operator = nullptr;
uint64_t native_redo_generation = 0;
bool native_redo_dismissed = false;
/* Counts requests to open Adjust Last Operation, for the interface to notice a new one. */
int native_redo_show_requests = 0;
int64_t native_redo_ack = 0;
std::string native_redo_error;
std::string native_redo_snapshot = "null";
std::chrono::steady_clock::time_point native_redo_next_snapshot;
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
  native_redo_next_snapshot = {};
}

void native_redo_operator_free(wmOperator *op)
{
  if (native_redo_operator == op) {
    native_redo_operator = nullptr;
    native_redo_next_snapshot = {};
  }
}

void native_redo_show(bContext * /*C*/)
{
  native_redo_dismissed = false;
  ++native_redo_show_requests;
  native_redo_next_snapshot = {};
  WM_main_add_notifier(NC_WINDOW, nullptr);
}

void native_redo_operator_clear()
{
  native_redo_operator = nullptr;
  native_redo_next_snapshot = {};
}

std::string native_operator_redo_query(bContext *C, const std::string &json, bool execute)
{
  wmOperator *op = WM_operator_last_redo(C);
  if (!op || op != native_redo_operator || native_redo_dismissed || !CTX_wm_view3d(C) ||
      !CTX_wm_region(C))
  {
    return "null";
  }
  auto query_value = execute ? decode(json) : nullptr;
  const auto *query = query_value ? query_value->as_dictionary_value() : nullptr;
  const std::string identity = std::to_string(native_redo_generation);
  if (execute) {
    if (!query || query->lookup_str("id").value_or("") != identity) {
      return "null";
    }
    native_redo_ack = query->lookup_int("sequence").value_or(native_redo_ack);
    native_redo_next_snapshot = {};
    native_redo_error.clear();
    if (query->lookup_str("action").value_or("") == "dismiss") {
      native_redo_dismissed = true;
      return "null";
    }
  }
  bool enabled = !G.moving && WM_operator_repeat_check(C, op) && WM_operator_poll(C, op->type) &&
                 WM_operator_check_ui_enabled(C, op->type->name);
  if (wmWindow *window = CTX_wm_window(C)) {
    for (wmEventHandler &handler : window->runtime->modalhandlers) {
      if (handler.type == WM_HANDLER_TYPE_OP || handler.type == WM_HANDLER_TYPE_UI) {
        enabled = false;
        break;
      }
    }
  }
  if (!enabled) {
    return "null";
  }
  const auto now = std::chrono::steady_clock::now();
  if (!execute && now < native_redo_next_snapshot) {
    return native_redo_snapshot;
  }
  DictionaryValue result;
  result.append_str("id", identity);
  result.append_str("title", WM_operatortype_name(op->type, op->ptr));
  result.append_str("operator", op->type->idname);
  result.append_int("ack", native_redo_ack);
  result.append_int("show", native_redo_show_requests);
  auto fields = result.append_array("properties");
  Block *block = block_begin(C, nullptr, "native_operator_redo", EmbossType::Emboss);
  Layout &layout = block_layout(
      block, LayoutDirection::Vertical, LayoutType::Panel, 0, 0, 320, 20, 0, style_get_dpi());
  /* Uses the actual operator UI, including macros and poll_property visibility. */
  template_operator_redo_properties(&layout, C);
  const auto pairs = property_pairs(*block);
  block_end(C, block);
  std::set<std::string> seen;
  bool applied = false;
  for (const auto &button : block->buttons) {
    Button &but = *button;
    if (!but.rnaprop || !but.rnapoin.data || (but.flag & UI_HIDDEN) ||
        !RNA_struct_is_a(but.rnapoin.type, RNA_OperatorProperties) ||
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
      const std::string key = property_key(but, index);
      if (!seen.insert(key).second) {
        continue;
      }
      if (execute && query->lookup_str("key").value_or("") == key) {
        applied = set_property(C, but, index, *query, false);
      }
      else if (!execute) {
        auto field = fields->append_dict();
        const auto pair = pairs.find(&but);
        project_property(C, but, index, *field, pair == pairs.end() ? nullptr : &pair->second);
      }
    }
  }
  block_free(C, block);
  if (execute) {
    if (!applied || !ED_undo_operator_repeat(C, op)) {
      native_redo_error = "This operation could not be adjusted.";
    }
    /* Rebuild from the executed operator, whose check callback may change its UI. */
    return native_operator_redo_query(C, "", false);
  }
  result.append_str("error", native_redo_error);
  native_redo_snapshot = fields->elements().is_empty() ? "null" : encode(result);
  native_redo_next_snapshot = now + std::chrono::milliseconds(200);
  return native_redo_snapshot;
}

std::string native_properties_query(bContext *C, const std::string &json, bool execute)
{
  DictionaryValue result;
  auto query_value = decode(json);
  const auto *query = query_value ? query_value->as_dictionary_value() : nullptr;
  if (!query || !CTX_data_scene(C)) {
    return "{}";
  }
  /* The panels draw their items' previews, such as materials', which need the scene evaluated:
   * evaluated first, as before Blender's own redraw, since an edit may have just changed it. */
  CTX_data_ensure_evaluated_depsgraph(C);
  if (execute) {
    const std::string token = query->lookup_str("interaction").value_or("");
    if (!token.empty() && token == native_property_interaction.closed_token) {
      return "";
    }
    if (token != native_property_interaction.token) {
      finish_property_interaction(C);
    }
    if (query->lookup_str("phase").value_or("") == "cancel" &&
        native_property_interaction.token.empty()) {
      return "";
    }
  }
  const bool shading = query->lookup_str("tab").value_or("") == "SHADING";
  const bool tool_settings = query->lookup_str("tab").value_or("") == "TOOL";
  const bool viewport = shading || tool_settings;
  std::unique_ptr<PropertiesContext> properties_context;
  if (!viewport) {
    properties_context = std::make_unique<PropertiesContext>(C);
  }
  else if (!CTX_wm_view3d(C)) {
    return "{}";
  }
  ARegion *panel_region = viewport ? CTX_wm_region(C) : properties_context->region;
  ARegionType *panel_region_type = viewport ?
      BKE_regiontype_from_id(CTX_wm_area(C)->type, tool_settings ? RGN_TYPE_UI : RGN_TYPE_HEADER) :
      panel_region->runtime->type;
  std::string tab_id = tool_settings ? "TOOL" : shading ? "SHADING" : "OBJECT";
  auto tab_items = result.append_array("tabs");
  if (!viewport) {
    PropertiesContext &context = *properties_context;
    PointerRNA space_ptr = RNA_pointer_create_discrete(nullptr, RNA_SpaceProperties, context.space);
    PropertyRNA *tab_prop = RNA_struct_find_property(&space_ptr, "context");
    const EnumPropertyItem *tabs;
    int tab_count;
    bool free_tabs;
    RNA_property_enum_items(C, &space_ptr, tab_prop, &tabs, &tab_count, &free_tabs);
    const std::string requested_tab = query->lookup_str("tab").value_or("OBJECT");
    int selected = BCONTEXT_OBJECT;
    if (!RNA_enum_value_from_identifier(tabs, requested_tab.c_str(), &selected)) {
      selected = context.space->mainb;
    }
    context.space->mainbuser = context.space->mainb = selected;
    ED_buttons_native_context_prepare(C, context.space);
    for (int i = 0; i < tab_count; i++) {
      const auto &tab = tabs[i];
      if (!tab.identifier || !tab.identifier[0]) {
        continue;
      }
      auto item = tab_items->append_dict();
      item->append_str("id", tab.identifier);
      item->append_str("title", tab.name);
      item->append_str("icon", icon_name(tab.icon));
      if (tab.value == context.space->mainb) {
        tab_id = tab.identifier;
      }
    }
    if (free_tabs) {
      MEM_delete(tabs);
    }
  }
  /* Native lists scroll themselves, so draw all their items. */
  struct ShowAllListRows {
    ShowAllListRows() { ui_list_show_all_rows = true; }
    ~ShowAllListRows() { ui_list_show_all_rows = false; }
  } show_all_list_rows;
  std::string panel_context = tab_id;
  std::transform(panel_context.begin(), panel_context.end(), panel_context.begin(), ::tolower);
  if (panel_context == "particles") {
    panel_context = "particle";
  }
  result.append_str("tab", tab_id);
  result.append_str("name", tool_settings ? "Tool Settings" : shading ? "Viewport Shading" : "Properties");
  Object *object = CTX_data_active_object(C);
  std::string identity = tab_id + ":" + std::to_string(object ? object->id.session_uid : 0);
  if (tool_settings) {
    const bToolRef *tool = WM_toolsystem_ref_from_context(C);
    if (!tool) { return execute ? "The active tool is no longer available." : "{}"; }
    identity += ":" + std::string(tool->idname) + ":" + CTX_data_mode_string(C);
    result.append_str("tool", tool->idname);
    if (execute && query->lookup_str("id").value_or("") != identity) {
      return "The active tool has changed.";
    }
  }
  result.append_str("id", identity);
  auto sections = std::make_shared<ArrayValue>();
  const ArrayValue *expanded = query->lookup_array("expanded");
  /* Sub-panel disclosure overrides keyed by panel id; absent ids use the panel type default. */
  const DictionaryValue *subpanel_states = query->lookup_dict("subpanels");
  const auto requested_panel = query->lookup_str("panel");
  const auto requested_key = query->lookup_str("key");
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
  std::map<std::string, int> panel_depths;
  std::map<std::string, std::string> outer_panels;
  std::map<std::string, std::shared_ptr<ArrayValue>> outer_fields;
  /* Properties of each section the other selected items have, and don't. */
  std::map<std::string, int> common_sections, missing_sections;
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
  for (PanelType &pt : panel_region_type->paneltypes) {
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
    if (!(pt.flag & PANEL_TYPE_INSTANCED)) {
      candidates.push_back({&pt, nullptr, pt.idname, shading ? "" : pt.parent_id});
    }
  }
  for (size_t candidate_index = 0; candidate_index < candidates.size(); candidate_index++) {
    const Candidate candidate = candidates[candidate_index];
    PanelType &pt = *candidate.type;
    if (!pt.draw || (!viewport && !candidate.instance && panel_context != pt.context) ||
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
      if (const std::shared_ptr<Value> *state = subpanel_states->lookup(candidate.id)) {
        if (const BooleanValue *flag = (*state)->as_boolean_value()) {
          subpanel_open = flag->value();
        }
      }
    }
    /* Header-less panels (e.g. Add Modifier above the stack) cannot be collapsed. */
    const bool header_hidden = is_outer && (pt.flag & PANEL_TYPE_NO_HEADER);
    const bool open = header_hidden ? true : is_outer ? (expanded ? std::any_of(expanded->elements().begin(), expanded->elements().end(),
        [&](const auto &item) { return item->as_string_value() && item->as_string_value()->value() == candidate.id; }) : viewport || sections->elements().is_empty()) :
        open_panels.count(outer) != 0 && (!collapsible_subpanel || subpanel_open);
    if (open && is_outer) {
      open_panels.insert(outer);
    }
    visible_panels[candidate.id] = open;
    panel_depths[candidate.id] = is_outer ? 0 : panel_depths[candidate.parent] + 1;
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
      auto section = sections->append_dict();
      section->append_str("id", candidate.id);
      section->append_str("title", panel_title);
      section->append_int("open", open);
      if (header_hidden) {
        section->append_int("header_hidden", 1);
      }
      if (panel_active) {
        section->append_int("active", 1);
      }
      if (candidate.instance && pt.reorder) {
        section->append_int("stack_index", stack_index++);
      }
      outer_fields[outer] = section->append_array("properties");
    }
    auto fields = outer_fields[outer];
    if (!fields) {
      continue;
    }
    auto append_field = [&]() {
      auto field = fields->append_dict();
      if (!is_outer) {
        field->append_str("section", panel_title);
        field->append_str("subpanel", candidate.id);
      }
      return field;
    };
    if (collapsible_subpanel && !execute) {
      /* Disclosure row for the sub-panel, emitted even when collapsed so it can be reopened. */
      auto field = append_field();
      field->append_str("type", "SUBPANEL");
      field->append_int("open", open);
      field->append_int("depth", panel_depths[candidate.id]);
    }
    const bool target_panel = requested_panel && *requested_panel == candidate.id;
    if (execute && target_panel && candidate.instance && !pt.parent && pt.reorder &&
        query->lookup_str("panel_action").value_or("") == "reorder")
    {
      /* Dragged to another place in the stack, as dragging its header in Blender does. */
      const int64_t to = query->lookup_int("to").value_or(-1);
      if (to >= 0) {
        pt.reorder(C, candidate.instance, int(to));
        applied = true;
      }
      break;
    }
    const bool instance_container = !candidate.instance &&
        ELEM(tab_id, "MODIFIER", "CONSTRAINT", "BONE_CONSTRAINT", "SHADERFX");
    if ((!execute && !open && !is_outer && !instance_container && !collapsible_subpanel) ||
        (execute && !target_panel && !instance_container && !shading)) {
      continue;
    }
    Block *block = block_begin(C, nullptr, "native_properties", EmbossType::Emboss);
    Panel *panel = candidate.instance ? candidate.instance : BKE_panel_new(&pt);
    block->panel = panel;
    Layout &layout = block_layout(block, LayoutDirection::Vertical, LayoutType::Panel,
                                   0, 0, 320, 20, 0, style_get_dpi());
    panel->layout = &layout;
    layout.operator_context_set(wm::OpCallContext::ExecDefault);
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
              tool_labels[button.get()] = caption;
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
    }
    block_end(C, block);
    for (const auto &button : block->buttons) {
      /* Icon templates keep their RNA target in callback data, not in the button itself. */
      if (template_icon_view_property_get(*button, button->rnapoin, button->rnaprop)) {
        button->rnaindex = -1;
      }
    }
    if (shading) {
      for (const auto &button : block->buttons) {
        if (!candidate.enabled) { button->flag |= BUT_DISABLED; }
        PanelType *nested = button_paneltype_get(button.get());
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
    {
      std::set<ID *> template_ids;
      for (const auto &button : block->buttons) {
        PointerRNA template_ptr;
        PropertyRNA *template_prop;
        int event;
        if (template_id_property_get(*button, template_ptr, template_prop, event)) {
          if (event != UI_ID_BROWSE) {
            combined.insert(button.get());
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
        combined.insert(&but);
      }
      empty_lists.emplace_back(&add, side);
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
          }
          toggle_groups[&but] = {group, caption};
        }
        previous = &but;
      }
    }
    std::set<std::string> seen;
    for (const auto &button : block->buttons) {
      Button &but = *button;
      if (!execute) {
        for (size_t index = 0; index < empty_lists.size(); index++) {
          if (empty_lists[index].first != &but) {
            continue;
          }
          auto field = append_field();
          project_list_side(C, &empty_lists[index].second, object, *field, false);
          field->append_str("type", "LIST");
          field->append_str("key", "empty:" + candidate.id + ":" + std::to_string(index));
          field->append_str("label", "");
          field->append_int("value", -1);
          field->append_int("editable", 1);
          field->append_array("rows");
          field->append_str("panel", candidate.id);
          field->append_str("tab", tab_id);
          field->append_int("native", 1);
        }
      }
      if (!execute && combined.count(&but)) {
        continue;
      }
      PointerRNA template_ptr;
      PropertyRNA *template_prop;
      int template_event;
      if (template_id_property_get(but, template_ptr, template_prop, template_event)) {
        if (template_event == UI_ID_BROWSE) {
          const std::string key = id_template_key(template_ptr, template_prop);
          if (execute) {
            if (target_panel && requested_key && *requested_key == key && !applied) {
              applied = apply_id_template(C, *block, template_ptr, template_prop, *query,
                                          operator_type, operator_properties, operator_context,
                                          pending_new_id);
            }
          }
          else if (seen.insert(key).second) {
            auto field = append_field();
            project_id_template(C, *block, template_ptr, template_prop, *field);
            field->append_str("panel", candidate.id);
            field->append_str("tab", tab_id);
            field->append_int("native", 1);
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
        if (!execute && !has_rows && but.rnaprop && but.rnapoin.data &&
            seen.insert(property_key(but, -1)).second)
        {
          auto field = append_field();
          project_list(C, *block, but, row_items, list_side_for(but), object, *field);
          field->append_str("panel", candidate.id);
          field->append_str("tab", tab_id);
          field->append_int("native", 1);
        }
        continue;
      }
      if (but.type == ButtonType::ViewItem) {
        /* A tree, from its first item. */
        for (size_t index = 0; index < trees.size(); index++) {
          if (trees[index].items.front() != &but) {
            continue;
          }
          const std::string key = tree_key(index);
          if (execute) {
            if (target_panel && requested_key && *requested_key == key && !applied) {
              applied = apply_tree(C, trees[index], *query);
            }
          }
          else if (seen.insert(key).second) {
            auto field = append_field();
            project_tree(C, trees[index], row_items, object, key, *field);
            field->append_str("panel", candidate.id);
            field->append_str("tab", tab_id);
            field->append_int("native", 1);
          }
        }
        continue;
      }
      if (but.type == ButtonType::ListRow && execute && target_panel && requested_key &&
          *requested_key == property_key(but, -1) &&
          query->lookup_str("list_action").value_or("") == "move")
      {
        /* Drag to reorder: make the item active, then move it as the list's arrows do. */
        if (!applied) {
          ListSide *side = list_side_for(but);
          const int from = int(query->lookup_int("from").value_or(-1));
          const int to = int(query->lookup_int("to").value_or(-1));
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
      if (but.type == ButtonType::ListRow && !execute) {
        if (seen.insert(property_key(but, -1)).second) {
          auto field = append_field();
          project_list(C, *block, but, row_items, list_side_for(but), object, *field);
          field->append_str("panel", candidate.id);
          field->append_str("tab", tab_id);
          field->append_int("native", 1);
        }
        continue;
      }
      if (but.type == ButtonType::Extra && but.poin && StringRef(candidate.id).endswith("_PT_preview"))
      {
        /* The Preview panel's render (#template_preview). */
        ID *id = reinterpret_cast<ID *>(but.poin);
        if (!execute && seen.insert("preview:" + std::to_string(id->session_uid)).second) {
          auto field = append_field();
          field->append_str("type", "PREVIEW");
          field->append_str("key", "preview:" + std::to_string(id->session_uid));
          field->append_str("label", id->name + 2);
          field->append_str("preview", id_large_preview_path(C, id));
          /* The preview's shape choice, shown on the preview itself. */
          for (const auto &shape : block->buttons) {
            if (shape->type == ButtonType::Row && shape->rnaprop &&
                STREQ(RNA_property_identifier(shape->rnaprop), "preview_render_type"))
            {
              auto shape_field = field->append_dict("shape");
              project_property(C, *shape, -1, *shape_field);
              shape_field->append_str("panel", candidate.id);
              shape_field->append_str("tab", tab_id);
              shape_field->append_int("native", 1);
              seen.insert(property_key(*shape, -1));
              break;
            }
          }
          field->append_str("panel", candidate.id);
          field->append_str("tab", tab_id);
          field->append_int("native", 1);
        }
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
          const auto value = query->lookup_str("value");
          if (target_panel && requested_key && *requested_key == key && value && !operator_type &&
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
          auto field = append_field();
          field->append_str("type", "OPERATOR_MENU");
          field->append_str("label", but.str.empty() ? WM_operatortype_name(menu_ot, nullptr) : but.str);
          field->append_str("key", key);
          field->append_str("icon", icon_name(button_icon(&but)));
          field->append_int("editable", !(but.flag & (BUT_DISABLED | BUT_INACTIVE)));
          auto options = field->append_array("options");
          const EnumPropertyItem *items;
          int count;
          bool free;
          RNA_property_enum_items_gettexted(C, &op_ptr, menu_enum_prop, &items, &count, &free);
          for (int i = 0; i < count; i++) {
            auto option = options->append_dict();
            if (!items[i].identifier || !items[i].identifier[0]) {
              /* Headings start groups; unnamed items are separators. */
              option->append_str("heading", items[i].name ? items[i].name : "");
              continue;
            }
            option->append_str("value", items[i].identifier);
            option->append_str("label", items[i].name);
            option->append_str("icon", icon_name(items[i].icon));
          }
          if (free) {
            MEM_delete(items);
          }
          field->append_str("panel", candidate.id);
          field->append_str("tab", tab_id);
          field->append_int("native", 1);
        }
        continue;
      }
      if (physics_toggles && !but.optype) {
        /* Per-type viewport toggles beside the switches belong to each physics panel. */
        continue;
      }
      /* Keep only viewport enablement in modifier headers. Other display options belong
       * inside the expanded native panel. */
      const bool header_operator = header_buttons.count(&but) && but.optype && !(but.flag & UI_HIDDEN);
      if (header_operator && StringRef(but.optype->idname).endswith("_set_active")) {
        /* Native headers show which item is active as state, not as a button. */
        continue;
      }
      const bool header_toggle = header_buttons.count(&but) && but.rnaprop &&
                                RNA_property_type(but.rnaprop) == PROP_BOOLEAN &&
                                !RNA_property_array_check(but.rnaprop) &&
                                (!RNA_struct_is_a(but.rnapoin.type, RNA_Modifier) ||
                                 STREQ(RNA_property_identifier(but.rnaprop), "show_viewport"));
      if (!execute && !open && !header_toggle && !header_operator) {
        continue;
      }
      MenuType *menu = button_menutype_get(&but);
      if (!menu && but.optype && but.opptr && STREQ(but.optype->idname, "WM_OT_call_menu")) {
        /* Some panel menus are expressed as operators, including Add Modifier. */
        const std::string name = RNA_string_get(but.opptr, "name");
        menu = WM_menutype_find(name.c_str(), true);
      }
      if (menu) {
        if (!execute && !(but.flag & UI_HIDDEN)) {
          auto field = append_field();
          field->append_str("type", "MENU");
          field->append_str("label", but.str.empty() ? menu->label : but.str);
          field->append_str("key", menu->idname);
          field->append_str("menu", menu->idname);
          field->append_str("tab", tab_id);
          field->append_str("icon", icon_name(button_icon(&but)));
          field->append_int("editable", !(but.flag & (BUT_DISABLED | BUT_INACTIVE)));
        }
        /* Menu activation belongs to UIKit, never to a Blender popup operator. */
        continue;
      }
      if (but.optype && !(but.flag & UI_HIDDEN)) {
        if (shading && STREQ(but.optype->idname, "SCREEN_OT_userpref_show")) {
          /* This opens an unrelated Blender window, not a viewport shading setting. */
          continue;
        }
        if (STREQ(but.optype->idname, "FILE_OT_unpack_item") && but.opptr &&
            RNA_int_get(but.opptr, "id_type") == ID_VF)
        {
          /* Fonts from the font picker are packed on purpose: their files are only a cache. */
          continue;
        }
        const std::string key = operator_key(C, but, object);
        if (execute && !operator_type && target_panel && requested_key && *requested_key == key &&
            !(but.flag & (BUT_DISABLED | BUT_INACTIVE)) && but.optype->exec) {
          operator_type = but.optype;
          operator_properties = but.opptr;
          but.opptr = nullptr;
          if (but.context) {
            operator_context = std::make_unique<bContextStore>(*but.context);
          }
        }
        else if (!execute && seen.insert(key).second) {
          auto field = append_field();
          field->append_str("type", "OPERATOR");
          field->append_str("label", but.str.empty() ? WM_operatortype_name(but.optype, but.opptr) : but.str);
          field->append_str("key", key);
          field->append_str("icon", icon_name(button_icon(&but)));
          if (ELEM(button_icon(&but), ICON_CHECKBOX_HLT, ICON_CHECKBOX_DEHLT)) {
            /* A toggle operator drawn as a checkbox (e.g. Dyntopo): native UI shows a switch. */
            field->append_int("checkbox", 1);
            field->append_int("value", button_icon(&but) == ICON_CHECKBOX_HLT);
          }
          else if (physics_toggles) {
            /* Physics are added and removed with one button each, which shows an X while the
             * physics is on: a switch per type. */
            const bool enabled = button_icon(&but) == ICON_X;
            field->append_int("checkbox", 1);
            field->append_int("value", enabled);
            field->append_str("leading_icon", icon_name(enabled ? physics_icon(C, but) :
                                                                  button_icon(&but)));
            /* Natively each physics is one section: this switch heads its settings. */
            if (const char *panel_id = physics_panel(C, but)) {
              field->append_str("physics_panel", panel_id);
            }
          }
          field->append_int("editable", !(but.flag & (BUT_DISABLED | BUT_INACTIVE)) && but.optype->exec);
          if (header_operator) {
            field->append_int("header", 1);
          }
          field->append_str("panel", candidate.id);
          field->append_str("tab", tab_id);
          field->append_int("native", 1);
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
      const SelectedOthers others = execute ? SelectedOthers() : selected_others(C, but);
      if (others.missing) {
        if (is_outer) {
          missing_sections[candidate.id] += 1;
        }
        continue;
      }
      if (is_outer) {
        common_sections[candidate.id] += 1;
      }
      const int begin = !color && length ? std::max(0, but.rnaindex) : -1;
      const int end = !color && length && but.rnaindex < 0 ? std::min(length, 16) : begin + 1;
      for (int index = begin; index < end; index++) {
        const std::string key = property_key(but, index);
        if (!seen.insert(key).second) {
          continue;
        }
        if (execute) {
          if (target_panel && requested_key && *requested_key == key) {
            const auto animation_action = query->lookup_str("animation_action");
            applied = animation_action ? animate_property(C, but, index, *animation_action) :
                                         set_property(C, but, index, *query);
          }
        }
        else {
          if (attached_locks.count(key) || attached_modes.count(key)) {
            continue;
          }
          auto field = append_field();
          const auto pair = pairs.find(&but);
          const auto layout_name = layout_names.find(but.rnaprop);
          project_property(C, but, index, *field, pair == pairs.end() ? nullptr : &pair->second,
                           layout_name == layout_names.end() ? nullptr : &layout_name->second,
                           &others);
          if (but.type == ButtonType::Row && RNA_property_type(but.rnaprop) == PROP_ENUM) {
            /* Authored as an expanded row (e.g. selection mode), not a dropdown. */
            field->append_int("expand", 1);
          }
          if (const auto group = toggle_groups.find(&but); group != toggle_groups.end()) {
            field->append_str("toggle_group", candidate.id + ":" + std::to_string(group->second.first));
            field->append_str("toggle_caption", group->second.second);
          }
          if (const auto found = tool_labels.find(&but);
              tool_settings && found != tool_labels.end()) {
            field->append_str("toolbar_label", found->second);
          }
          if (const auto found = field_modes.find(key); found != field_modes.end()) {
            auto mode = field->append_dict("group_menu");
            project_property(C, *found->second, -1, *mode);
            mode->append_str("panel", candidate.id);
            mode->append_str("tab", tab_id);
            mode->append_int("native", 1);
          }
          if (const auto found = field_locks.find(key); found != field_locks.end()) {
            auto lock = field->append_dict("lock");
            project_property(C, *found->second.first, found->second.second, *lock);
            lock->append_str("panel", candidate.id);
            lock->append_str("tab", tab_id);
            lock->append_int("native", 1);
          }
          if (header_toggle) {
            field->append_int("header", 1);
          }
          field->append_str("panel", candidate.id);
          field->append_str("tab", tab_id);
          field->append_int("native", 1);
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
    auto style = result.append_dict("text_style");
    style->append_int("bold", (flags & CU_CHINFO_BOLD) != 0);
    style->append_int("italic", (flags & CU_CHINFO_ITALIC) != 0);
    style->append_int("underline", (flags & CU_CHINFO_UNDERLINE) != 0);
    style->append_int("small_caps", (flags & CU_CHINFO_SMALLCAPS) != 0);
    style->append_str("font_file", curve->vfont ? curve->vfont->filepath : "");
    PointerRNA curve_ptr = RNA_id_pointer_create(const_cast<ID *>(&curve->id));
    for (const char *identifier : {"align_x", "align_y"}) {
      PropertyRNA *prop = RNA_struct_find_property(&curve_ptr, identifier);
      const char *value = "";
      RNA_property_enum_identifier(C, &curve_ptr, prop, RNA_property_enum_get(&curve_ptr, prop), &value);
      style->append_str(identifier, value);
    }
    for (const char *identifier : {"size", "space_line", "space_character", "space_word"}) {
      style->append_double(identifier, RNA_float_get(&curve_ptr, identifier));
    }
  }
  /* Sections of only the active item's own (e.g. a modifier the others lack) leave with their
   * properties. */
  auto common = result.append_array("sections");
  for (const std::shared_ptr<Value> &section : sections->elements()) {
    const std::string id = section->as_dictionary_value()->lookup_str("id").value_or("");
    if (missing_sections.count(id) && !common_sections.count(id)) {
      continue;
    }
    common->append(section);
  }
  return encode(result);
}

std::string native_properties_menu_query(bContext *C, const std::string &json, bool execute)
{
  auto value = decode(json);
  const auto *request = value ? value->as_dictionary_value() : nullptr;
  if (!request) {
    return "[]";
  }
  const auto tab = request->lookup_str("propertiesTab");
  if (!tab || *tab == "TOOL") {
    return native_menu_query(C, json, execute);
  }
  PropertiesContext context(C);
  PointerRNA ptr = RNA_pointer_create_discrete(nullptr, RNA_SpaceProperties, context.space);
  PropertyRNA *prop = RNA_struct_find_property(&ptr, "context");
  const EnumPropertyItem *items;
  int count, selected;
  bool free;
  RNA_property_enum_items(C, &ptr, prop, &items, &count, &free);
  if (tab && RNA_enum_value_from_identifier(items, tab->c_str(), &selected)) {
    context.space->mainbuser = selected;
    ED_buttons_native_context_prepare(C, context.space);
  }
  if (free) {
    MEM_delete(items);
  }
  const std::string menu_json = native_menu_query(C, json, execute);
  auto menu_value = decode(menu_json);
  if (tab && menu_value && menu_value->as_array_value()) {
    for (auto &item : menu_value->as_array_value()->elements()) {
      if (auto *entry = item->as_dictionary_value()) {
        if (auto *route = entry->lookup("route")) {
          if ((*route)->as_dictionary_value()) {
            static_cast<DictionaryValue *>(route->get())->append_str("propertiesTab", *tab);
          }
        }
      }
    }
    return encode(*menu_value);
  }
  return menu_json;
}

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
};

NativeNodeTree native_node_tree(bContext *C, const DictionaryValue &query)
{
  NativeNodeTree result;
  const std::string kind = query.lookup_str("tree").value_or("SHADER");
  Object *object = CTX_data_active_object(C);
  if (kind == "SHADER") {
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
  if (shown.root) {
    STRNCPY(space->tree_idname, shown.root->idname);
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
  for (bNodeSocket &socket : node.inputs) {
    if (!socket.is_visible() || linked.count(&socket) || (socket.flag & SOCK_HIDE_VALUE)) {
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

/** Calls `fn` for each value a node's block shows, as the Properties fields go, and `id_fn`
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

void project_node(bContext *C,
                  bNodeTree &tree,
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
  if (node.is_frame() || node.is_reroute()) {
    return;
  }
  auto fields = item.append_array("fields");
  Block *block = native_node_block(C, tree, node, linked);
  for_each_node_field(
      *block,
      [&](Button &but, const int index, const std::string & /*key*/) {
        auto field = fields->append_dict();
        /* A node's own value: other selected nodes are left alone. */
        const SelectedOthers none;
        project_property(C, but, index, *field, nullptr, nullptr, &none);
        field->append_str("node", node.name);
        if (RNA_struct_is_a(but.rnapoin.type, RNA_NodeSocket)) {
          field->append_str("socket", static_cast<bNodeSocket *>(but.rnapoin.data)->identifier);
        }
      },
      [&](PointerRNA &ptr, PropertyRNA *prop) {
        auto field = fields->append_dict();
        project_id_template(C, *block, ptr, prop, *field);
        field->append_str("node", node.name);
      });
  block_free(C, block);
}

void project_node_add_items(bContext *C, bNodeTree &tree, ArrayValue &items)
{
  const Span<int> zone_outputs = bke::all_zone_output_node_types();
  for (const bke::bNodeType *type : bke::node_types_get()) {
    const char *disabled_hint = nullptr;
    if (type->poll && !type->poll(type, &tree, &disabled_hint)) {
      continue;
    }
    if (type->add_ui_poll && !type->add_ui_poll(C)) {
      continue;
    }
    if (type->deprecation_notice || StringRef(type->ui_name).endswith("(Legacy)") ||
        StringRef(type->idname).endswith("Undefined") || type->nclass == NODE_CLASS_GROUP ||
        type->idname == "NodeCustomGroup" || zone_outputs.contains(type->type_legacy))
    {
      continue;
    }
    auto item = items.append_dict();
    item->append_str("idname", type->idname);
    item->append_str("name", type->ui_name);
    item->append_str("description", type->ui_description);
    item->append_str("category", node_class_title(type->nclass));
  }
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
  wmOperatorType *ot = WM_operatortype_find(item->idname, false);
  /* Operators that run on the tree as it is; those following the pointer (select, link, cut)
   * belong to the canvas's own gestures. */
  if (!ot || (!ot->exec && !(ot->flag & OPTYPE_MACRO)) || !WM_operator_poll(C, ot)) {
    return std::nullopt;
  }
  if (!(WM_operator_name_call_ptr(C, ot, wm::OpCallContext::ExecDefault, item->ptr, nullptr) &
        OPERATOR_FINISHED))
  {
    return std::nullopt;
  }
  BKE_main_ensure_invariants(*CTX_data_main(C), tree.id);
  return std::string("");
}

/** Applies one of the canvas's actions to the tree it shows; the undo step's name, or none. */
std::optional<std::string> apply_node_action(bContext *C, bNodeTree &tree, const DictionaryValue &query)
{
  Main *bmain = CTX_data_main(C);
  const std::string action = query.lookup_str("action").value_or("");
  bNode *node = bke::node_find_node_by_name(tree, query.lookup_str("node").value_or(""));
  if (action == "property") {
    /* A node's value, or the header's data-block. */
    const bool header = query.lookup_int("header").value_or(0);
    if (!node && !header) {
      return std::nullopt;
    }
    const std::set<const bNodeSocket *> linked = linked_sockets(tree);
    Block *block = header ? native_node_header_block(C) : native_node_block(C, tree, *node, linked);
    const std::string key = query.lookup_str("key").value_or("");
    bool applied = false;
    wmOperatorType *operator_type = nullptr;
    PointerRNA *operator_properties = nullptr;
    std::unique_ptr<bContextStore> operator_context;
    PendingNewID pending;
    for_each_node_field(
        *block,
        [&](Button &but, const int index, const std::string &field_key) {
          if (!applied && field_key == key && !query.lookup_str("id_action")) {
            applied = set_property(C, but, index, query, true, false);
          }
        },
        [&](PointerRNA &ptr, PropertyRNA *prop) {
          if (!applied && query.lookup_str("id_action") && id_template_key(ptr, prop) == key) {
            applied = apply_id_template(C, *block, ptr, prop, query, operator_type,
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
    if (node) {
      BKE_ntree_update_tag_node_property(&tree, node);
    }
    BKE_main_ensure_invariants(*bmain, tree.id);
    return applied ? std::optional<std::string>("") : std::nullopt;
  }
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

std::string native_nodes_query(bContext *C, const std::string &json, const bool execute)
{
  auto query_value = decode(json);
  const auto *query = query_value ? query_value->as_dictionary_value() : nullptr;
  if (!query || !CTX_data_scene(C)) {
    return execute ? "This node tree is no longer available." : "null";
  }
  NativeNodeTree shown = native_node_tree(C, *query);
  if (shown.tree) {
    shown.tree->ensure_topology_cache();
  }
  /* Resolved from the viewport's context; edited and drawn in a node editor's. */
  std::optional<NodeSpaceContext> node_space;
  if (shown.tree) {
    node_space.emplace(C, shown);
  }
  if (execute) {
    if (!shown.tree) {
      return "This node tree is no longer available.";
    }
    const std::optional<std::string> undo = apply_node_action(C, *shown.tree, *query);
    if (!undo) {
      return "This node change could not be made.";
    }
    if (!undo->empty()) {
      ED_undo_push(C, undo->c_str());
    }
    WM_event_add_notifier(C, NC_NODE | NA_EDITED, shown.tree);
    if (shown.root->type == NTREE_COMPOSIT && query->lookup_str("phase").value_or("") != "update") {
      /* The backdrop and previews follow, as in Blender's editor. */
      ED_node_compositor_job(C);
    }
    return "";
  }
  DictionaryValue result;
  result.append_str("tree", query->lookup_str("tree").value_or("SHADER"));
  if (!shown.tree) {
    result.append_str("empty", shown.empty);
    result.append_str("create", shown.create);
    return encode(result);
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
  auto nodes = result.append_array("nodes");
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
  else if (tree.type == NTREE_SHADER && query->lookup_int("previews").value_or(0) &&
           std::any_of(tree.nodes.begin(), tree.nodes.end(),
                       [](const bNode &node) { return node.flag & NODE_PREVIEW; }))
  {
    read.shader_previews = ed::space_node::get_nested_previews(*C, *read.space);
  }
  else if (tree.type == NTREE_COMPOSIT) {
    read.compositor_previews = &shown.root->runtime->previews;
  }
  NativeOptionSets option_sets;
  native_option_sets = &option_sets;
  for (bNode &node : tree.nodes) {
    project_node(C, tree, node, linked, *nodes->append_dict(), read);
  }
  /* The compositor's Viewer, behind the nodes as Blender's backdrop. */
  if (tree.type == NTREE_COMPOSIT && query->lookup_int("backdrop").value_or(0)) {
    Main *bmain = CTX_data_main(C);
    Image *viewer = BKE_image_ensure_viewer(bmain, IMA_TYPE_COMPOSITE, "Viewer Node");
    void *lock;
    ImageUser user = {};
    ImBuf *ibuf = BKE_image_acquire_ibuf(viewer, &user, &lock);
    const std::string path = native_preview_path(read.scene, ibuf, "backdrop");
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
  /* The header's data-block picker, as the Properties editor shows one. */
  {
    Block *header = native_node_header_block(C);
    auto ids = result.append_array("header_ids");
    for_each_node_field(
        *header,
        [](Button & /*but*/, const int /*index*/, const std::string & /*key*/) {},
        [&](PointerRNA &ptr, PropertyRNA *prop) {
          auto field = ids->append_dict();
          project_id_template(C, *header, ptr, prop, *field);
          field->append_int("header", 1);
        });
    block_free(C, header);
  }
  if (native_node_key_request.sequence) {
    auto key = result.append_dict("key_request");
    key->append_int("sequence", native_node_key_request.sequence);
    key->append_str("action", native_node_key_request.action);
    key->append_str("node", native_node_key_request.node);
  }
  /* What the compositor computes for this editor: its backdrop and the previews turned on. */
  ED_node_compositor_native_outputs_set(
      tree.type == NTREE_COMPOSIT && query->lookup_int("backdrop").value_or(0),
      tree.type == NTREE_COMPOSIT &&
          std::any_of(tree.nodes.begin(), tree.nodes.end(), [](const bNode &node) {
            return node.flag & NODE_PREVIEW;
          }));
  native_option_sets = nullptr;
  result.append("option_sets", option_sets.sets);
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
  if (query->lookup_int("with_add").value_or(0)) {
    project_node_add_items(C, tree, *result.append_array("add"));
  }
  return encode(result);
}

/** \} */

}  // namespace blender::ui
