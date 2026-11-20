/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup spgraph
 *
 * The Graph Editor's curves for a native interface, and its edits on them. A hidden Graph Editor
 * stands in for the one the native interface draws, so the channels it lists and the operators
 * it runs are exactly the Graph Editor's.
 */

#include <cmath>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "MEM_guardedalloc.h"

#include "BLI_listbase.h"
#include "BLI_serialize.hh"
#include "BLI_string.h"
#include "BLI_string_ref.hh"
#include "BLI_string_utf8.h"

#include "DNA_anim_types.h"
#include "DNA_curve_types.h"
#include "DNA_scene_types.h"
#include "DNA_screen_types.h"
#include "DNA_space_types.h"

#include "BKE_context.hh"
#include "BKE_fcurve.hh"
#include "BKE_nla.hh"
#include "BKE_screen.hh"

#include "ED_anim_api.hh"
#include "ED_undo.hh"

#include "RNA_access.hh"
#include "RNA_enum_types.hh"

#include "WM_api.hh"
#include "WM_types.hh"

#include "graph_intern.hh"

namespace blender::ed::graph {

using namespace io::serialize;

namespace {

/** Kept for the session, as Blender's own would be. */
ScrArea *native_graph_area(bContext *C)
{
  static ScrArea *area = nullptr;
  if (area == nullptr) {
    area = MEM_new<ScrArea>("native graph editor");
    area->spacetype = SPACE_GRAPH;
    /* On no screen, as Blender's own off-screen areas: an operator run in it shows no redo panel
     * there (ROUND6 EDIT-1: a registered operator crashed placing one). */
    area->flag |= AREA_FLAG_OFFSCREEN;
    area->type = BKE_spacetype_from_id(SPACE_GRAPH);
    SpaceLink *link = area->type->create(area, CTX_data_scene(C));
    BLI_addtail(&area->spacedata, link);
    std::swap(area->regionbase, link->regionbase);
    for (ARegion &region : area->regionbase) {
      region.runtime->type = BKE_regiontype_from_id(area->type, region.regiontype);
    }
  }
  return area;
}

/** The hidden Graph Editor as the context's area while curves are read or edited. */
struct GraphSpaceContext {
  bContext *C;
  ScrArea *previous_area;
  ARegion *previous_region;
  SpaceGraph *space;

  GraphSpaceContext(bContext *context, const DictionaryValue *state) : C(context)
  {
    previous_area = CTX_wm_area(C);
    previous_region = CTX_wm_region(C);
    ScrArea *area = native_graph_area(C);
    space = static_cast<SpaceGraph *>(area->spacedata.first);
    space->mode = SIPO_MODE_ANIMATION;
    if (state) {
      const bool only_selected = state->lookup_int("only_selected").value_or(1);
      SET_FLAG_FROM_TEST(space->ads->filterflag, only_selected, ADS_FILTER_ONLYSEL);
      SET_FLAG_FROM_TEST(space->flag, state->lookup_int("normalize").value_or(0), SIPO_NORMALIZE);
    }
    CTX_wm_area_set(C, area);
    CTX_wm_region_set(C, BKE_area_find_region_type(area, RGN_TYPE_WINDOW));
    /* The curves' colors, as the Graph Editor sets them before drawing. */
    if (area->type && area->type->refresh) {
      area->type->refresh(C, area);
    }
  }

  ~GraphSpaceContext()
  {
    CTX_wm_area_set(C, previous_area);
    CTX_wm_region_set(C, previous_region);
  }
};

/** Every curve the Graph Editor lists, hidden ones too, in its order. */
constexpr eAnimFilter_Flags curves_filter = eAnimFilter_Flags(
    ANIMFILTER_DATA_VISIBLE | ANIMFILTER_FCURVESONLY | ANIMFILTER_NODUPLIS);

struct Curves {
  bAnimContext ac = {};
  ListBaseT<bAnimListElem> list = {};
  std::vector<bAnimListElem *> items;
  bool valid = false;

  explicit Curves(bContext *C)
  {
    if (!ANIM_animdata_get_context(C, &ac)) {
      return;
    }
    valid = true;
    ANIM_animdata_filter(&ac, &list, curves_filter, ac.data, eAnimCont_Types(ac.datatype));
    for (bAnimListElem &ale : list) {
      if (ale.type == ANIMTYPE_FCURVE && ale.key_data) {
        items.push_back(&ale);
      }
    }
  }

  ~Curves()
  {
    ANIM_animdata_freelist(&list);
  }

  FCurve *fcurve(const int index) const
  {
    return index >= 0 && index < int(items.size()) ? static_cast<FCurve *>(items[index]->key_data) :
                                                     nullptr;
  }

  /** Tags every curve for the given updates and runs them. */
  void update(const int flag)
  {
    for (bAnimListElem *ale : items) {
      ale->update = eAnim_Update_Flags(ale->update | flag);
    }
    ANIM_animdata_update(&ac, &list);
  }
};

/** How the Graph Editor shows a curve's values: (value + offset) * scale. */
struct ValueMapping {
  float scale = 1.0f;
  float offset = 0.0f;
};

ValueMapping value_mapping(const Curves &curves, bAnimListElem *ale)
{
  ValueMapping mapping;
  mapping.scale = ANIM_unit_mapping_get_factor(
      curves.ac.scene, ale->id, static_cast<FCurve *>(ale->key_data),
      ANIM_get_normalization_flags(curves.ac.sl), &mapping.offset);
  return mapping;
}

/** A key's selection, interpolation, easing and handle types, packed into one number. */
int key_flags(const BezTriple &bezt)
{
  return ((bezt.f2 & SELECT) ? 1 : 0) | ((bezt.f1 & SELECT) ? 2 : 0) | ((bezt.f3 & SELECT) ? 4 : 0) |
         (int(bezt.ipo) << 4) | (int(bezt.easing) << 10) | (int(bezt.h1) << 12) |
         (int(bezt.h2) << 15);
}

/** Segments drawn by sampling: anything but Bézier, linear and constant, and curves whose
 * modifiers change their shape. */
bool needs_samples(const FCurve &fcu)
{
  if (fcu.modifiers.first || fcu.totvert == 0) {
    return true;
  }
  for (int i = 0; i + 1 < fcu.totvert; i++) {
    if (!ELEM(fcu.bezt[i].ipo, BEZT_IPO_BEZ, BEZT_IPO_LIN, BEZT_IPO_CONST)) {
      return true;
    }
  }
  return false;
}

/** What a key asked of the native editor itself, such as framing the curves. */
struct KeyRequest {
  int sequence = 0;
  std::string action;
};
KeyRequest key_request;

/** FNV-1a over raw bytes, to tell whether the curves changed since they were last read. */
struct Fingerprint {
  uint64_t value = 1469598103934665603ull;
  void add(const void *data, const size_t size)
  {
    const unsigned char *bytes = static_cast<const unsigned char *>(data);
    for (size_t i = 0; i < size; i++) {
      value = (value ^ bytes[i]) * 1099511628211ull;
    }
  }
  template<typename T> void add(const T &item)
  {
    add(&item, sizeof(T));
  }
};

/** A drag of keys or a handle: where what it moves was when it began, to move from. */
struct Drag {
  std::string interaction;
  /** Per curve, its keys as they were, in scene time. */
  std::map<FCurve *, std::vector<BezTriple>> keys;
};
Drag drag;

/** The last read, kept while the curves stay as they were. */
struct LastRead {
  uint64_t fingerprint = 0;
  std::shared_ptr<DictionaryValue> result;
};
LastRead last_read;

/** The curves as the Graph Editor shows them, see #native_graph_read. */
std::shared_ptr<DictionaryValue> read_curves(bContext *C, const DictionaryValue &state)
{
  auto read = std::make_shared<DictionaryValue>();
  DictionaryValue &result = *read;
  const Scene *scene = CTX_data_scene(C);
  if (scene) {
    result.append_int("frame", scene->r.cfra);
  }
  Curves curves(C);
  if (!curves.valid) {
    result.append_array("curves");
    return read;
  }
  /* The range the native editor shows, where sampled curves are sampled. */
  float range[2] = {float(scene ? scene->r.sfra : 1), float(scene ? scene->r.efra : 250)};
  if (const ArrayValue *shown = state.lookup_array("range")) {
    if (shown->elements().size() == 2) {
      for (int i = 0; i < 2; i++) {
        if (const DoubleValue *number = shown->elements()[i]->as_double_value()) {
          range[i] = float(number->value());
        }
        else if (const IntValue *number = shown->elements()[i]->as_int_value()) {
          range[i] = float(number->value());
        }
      }
    }
  }
  /* Reading thousands of keys out takes a while, and the native interface asks often: the same
   * curves read as they did. Curves with modifiers are always read, as their shape depends on more
   * than their keys. */
  Fingerprint fingerprint;
  fingerprint.add(range);
  fingerprint.add(scene ? scene->r.cfra : 0);
  fingerprint.add(key_request.sequence);
  fingerprint.add(int(state.lookup_int("normalize").value_or(0)));
  bool cacheable = true;
  for (bAnimListElem *ale : curves.items) {
    const FCurve &fcu = *static_cast<const FCurve *>(ale->key_data);
    cacheable &= fcu.modifiers.first == nullptr;
    fingerprint.add(ale->id);
    if (ale->id) {
      fingerprint.add(ale->id->name, strlen(ale->id->name));
    }
    fingerprint.add(fcu.flag);
    fingerprint.add(fcu.extend);
    fingerprint.add(fcu.color);
    fingerprint.add(fcu.array_index);
    if (fcu.rna_path) {
      fingerprint.add(fcu.rna_path, strlen(fcu.rna_path));
    }
    fingerprint.add(fcu.totvert);
    if (fcu.bezt) {
      fingerprint.add(fcu.bezt, sizeof(BezTriple) * fcu.totvert);
    }
  }
  /* While a drag goes on, the native editor draws it from where it began. */
  if (last_read.result &&
      (!drag.interaction.empty() || (cacheable && fingerprint.value == last_read.fingerprint)))
  {
    return last_read.result;
  }
  auto list = result.append_array("curves");
  for (bAnimListElem *ale : curves.items) {
    FCurve &fcu = *static_cast<FCurve *>(ale->key_data);
    auto item = list->append_dict();
    const bAnimChannelType *acf = ANIM_channel_get_typeinfo(ale);
    char name[256] = "";
    if (acf && acf->name) {
      acf->name(ale, name);
    }
    /* Cut to fit, maybe in the middle of a character, which JSON cannot hold. */
    BLI_str_utf8_invalid_strip(name, strlen(name));
    item->append_str("name", name);
    item->append_str("owner", ale->id ? ale->id->name + 2 : "");
    auto color = item->append_array("color");
    for (int i = 0; i < 3; i++) {
      color->append_double(fcu.color[i]);
    }
    item->append_int("visible", (fcu.flag & FCURVE_VISIBLE) != 0);
    item->append_int("locked", (fcu.flag & FCURVE_PROTECTED) != 0);
    item->append_int("muted", (fcu.flag & FCURVE_MUTED) != 0);
    item->append_int("selected", (fcu.flag & FCURVE_SELECTED) != 0);
    item->append_int("active", (fcu.flag & FCURVE_ACTIVE) != 0);
    const ValueMapping mapping = value_mapping(curves, ale);
    item->append_double("scale", mapping.scale);
    item->append_double("offset", mapping.offset);
    /* In scene time, as the Graph Editor draws them. */
    ANIM_nla_mapping_apply_if_needed_fcurve(ale, &fcu, false, false);
    auto keys = item->append_array("keys");
    auto flags = item->append_array("flags");
    for (int i = 0; i < fcu.totvert; i++) {
      const BezTriple &bezt = fcu.bezt[i];
      for (int point = 0; point < 3; point++) {
        keys->append_double(bezt.vec[point][0]);
        keys->append_double((bezt.vec[point][1] + mapping.offset) * mapping.scale);
      }
      flags->append_int(key_flags(bezt));
    }
    ANIM_nla_mapping_apply_if_needed_fcurve(ale, &fcu, true, false);
    item->append_int("extrapolation", fcu.extend);
    if (needs_samples(fcu) && range[1] > range[0]) {
      /* Evaluated where the editor shows, about two samples a point of a wide view. */
      const int count = 600;
      const float step = (range[1] - range[0]) / float(count - 1);
      auto samples = item->append_array("samples");
      samples->append_double(range[0]);
      samples->append_double(step);
      for (int i = 0; i < count; i++) {
        float frame = range[0] + step * float(i);
        if (ale->adt) {
          frame = BKE_nla_tweakedit_remap(ale->adt, frame, NLATIME_CONVERT_UNMAP);
        }
        const float value = (evaluate_fcurve(&fcu, frame) + mapping.offset) * mapping.scale;
        /* JSON has no infinity or NaN, as a curve dividing by zero gives. */
        samples->append_double(std::isfinite(value) ? value : 0.0);
      }
    }
  }
  if (key_request.sequence) {
    auto request = result.append_dict("request");
    request->append_int("sequence", key_request.sequence);
    request->append_str("action", key_request.action);
  }
  last_read = {cacheable ? fingerprint.value : 0, read};
  return read;
}


double number(const DictionaryValue &query, const char *key, const double fallback = 0.0)
{
  if (const std::optional<double> value = query.lookup_double(key)) {
    return *value;
  }
  if (const std::optional<int64_t> value = query.lookup_int(key)) {
    return double(*value);
  }
  return fallback;
}

void deselect_all(const Curves &curves)
{
  for (bAnimListElem *ale : curves.items) {
    FCurve &fcu = *static_cast<FCurve *>(ale->key_data);
    for (int i = 0; i < fcu.totvert; i++) {
      BEZT_DESEL_ALL(&fcu.bezt[i]);
    }
  }
}

/** The curve made active, as clicking it in the Graph Editor does. */
void activate(Curves &curves, const int index)
{
  if (index < 0 || index >= int(curves.items.size())) {
    return;
  }
  bAnimListElem *ale = curves.items[index];
  ANIM_anim_channels_select_set(&curves.ac, ACHANNEL_SETFLAG_CLEAR);
  FCurve *fcu = static_cast<FCurve *>(ale->key_data);
  fcu->flag |= FCURVE_SELECTED;
  ANIM_set_active_channel(&curves.ac,
                          curves.ac.data,
                          eAnimCont_Types(curves.ac.datatype),
                          curves_filter,
                          fcu,
                          ANIMTYPE_FCURVE);
}

/** Moves the dragged keys, and their handles, by a frame and value delta from where they began;
 * or one handle to a place. */
void apply_drag(Curves &curves, const DictionaryValue &query)
{
  const double delta_frame = number(query, "df");
  const double delta_value = number(query, "dv");
  const int handle_curve = int(number(query, "curve", -1));
  const int handle_key = int(number(query, "key", -1));
  const int handle_side = int(number(query, "side", 0));
  for (int index = 0; index < int(curves.items.size()); index++) {
    bAnimListElem *ale = curves.items[index];
    FCurve &fcu = *static_cast<FCurve *>(ale->key_data);
    auto found = drag.keys.find(&fcu);
    /* Only what the canvas draws moves, as in the Graph Editor: a hidden curve's selected keys
     * stay where they are (ROUND6 EDIT-1). */
    if (found == drag.keys.end() || int(found->second.size()) != fcu.totvert ||
        (fcu.flag & FCURVE_PROTECTED) || !(fcu.flag & FCURVE_VISIBLE))
    {
      continue;
    }
    const ValueMapping mapping = value_mapping(curves, ale);
    const float dv = float(delta_value) / (mapping.scale != 0.0f ? mapping.scale : 1.0f);
    ANIM_nla_mapping_apply_if_needed_fcurve(ale, &fcu, false, false);
    for (int i = 0; i < fcu.totvert; i++) {
      BezTriple &bezt = fcu.bezt[i];
      const BezTriple &from = found->second[i];
      if (handle_side != 0) {
        if (index != handle_curve || i != handle_key) {
          continue;
        }
        /* A handle on its own: auto handles become aligned, as dragging one does in Blender. */
        const int point = handle_side < 0 ? 0 : 2;
        bezt.vec[point][0] = from.vec[point][0] + float(delta_frame);
        bezt.vec[point][1] = from.vec[point][1] + dv;
        if (ELEM(bezt.h1, HD_AUTO, HD_AUTO_ANIM)) {
          bezt.h1 = HD_ALIGN;
        }
        if (ELEM(bezt.h2, HD_AUTO, HD_AUTO_ANIM)) {
          bezt.h2 = HD_ALIGN;
        }
        continue;
      }
      if (from.f2 & SELECT) {
        for (int point = 0; point < 3; point++) {
          bezt.vec[point][0] = from.vec[point][0] + float(delta_frame);
          bezt.vec[point][1] = from.vec[point][1] + dv;
        }
      }
    }
    ANIM_nla_mapping_apply_if_needed_fcurve(ale, &fcu, true, false);
    ale->update = eAnim_Update_Flags(ale->update | ANIM_UPDATE_DEPS | ANIM_UPDATE_HANDLES);
  }
  ANIM_animdata_update(&curves.ac, &curves.list);
}

void begin_drag(Curves &curves, const std::string &interaction)
{
  drag = {};
  drag.interaction = interaction;
  for (bAnimListElem *ale : curves.items) {
    FCurve &fcu = *static_cast<FCurve *>(ale->key_data);
    std::vector<BezTriple> keys(fcu.bezt, fcu.bezt + fcu.totvert);
    /* Kept in scene time, as the drag moves them. */
    ANIM_nla_mapping_apply_if_needed_fcurve(ale, &fcu, false, false);
    keys.assign(fcu.bezt, fcu.bezt + fcu.totvert);
    ANIM_nla_mapping_apply_if_needed_fcurve(ale, &fcu, true, false);
    drag.keys[&fcu] = std::move(keys);
  }
}

/** Blender's own operators on the selected keys, as their menus and keys run them. */
bool run_operator(bContext *C, const DictionaryValue &query)
{
  static const std::set<std::string> allowed = {
      "GRAPH_OT_interpolation_type", "GRAPH_OT_easing_type",  "GRAPH_OT_handle_type",
      "GRAPH_OT_extrapolation_type", "GRAPH_OT_delete",       "GRAPH_OT_duplicate",
      "GRAPH_OT_smooth",             "GRAPH_OT_clean",        "GRAPH_OT_snap",
      "GRAPH_OT_euler_filter",       "GRAPH_OT_keyframe_insert", "GRAPH_OT_bake_keys",
      "GRAPH_OT_mirror",             "GRAPH_OT_equalize_handles"};
  const std::string idname = std::string(query.lookup_str("operator").value_or(""));
  if (!allowed.count(idname)) {
    return false;
  }
  wmOperatorType *ot = WM_operatortype_find(idname.c_str(), false);
  if (!ot || !WM_operator_poll(C, ot)) {
    return false;
  }
  PointerRNA properties = WM_operator_properties_create_ptr(ot);
  if (const DictionaryValue *values = query.lookup_dict("properties")) {
    for (const auto &item : values->elements()) {
      PropertyRNA *prop = RNA_struct_find_property(&properties, item.first.c_str());
      if (!prop) {
        continue;
      }
      if (const StringValue *text = item.second->as_string_value()) {
        if (RNA_property_type(prop) == PROP_ENUM) {
          RNA_enum_set_identifier(C, &properties, item.first.c_str(), text->value().c_str());
        }
      }
      else if (const BooleanValue *flag = item.second->as_boolean_value()) {
        RNA_property_boolean_set(&properties, prop, flag->value());
      }
      else if (const IntValue *integer = item.second->as_int_value()) {
        if (RNA_property_type(prop) == PROP_BOOLEAN) {
          RNA_property_boolean_set(&properties, prop, integer->value() != 0);
        }
        else if (RNA_property_type(prop) == PROP_FLOAT) {
          RNA_property_float_set(&properties, prop, float(integer->value()));
        }
        else {
          RNA_property_int_set(&properties, prop, int(integer->value()));
        }
      }
      else if (const DoubleValue *real = item.second->as_double_value()) {
        RNA_property_float_set(&properties, prop, float(real->value()));
      }
    }
  }
  const wmOperatorStatus status = WM_operator_name_call_ptr(
      C, ot, wm::OpCallContext::ExecDefault, &properties, nullptr);
  WM_operator_properties_free(&properties);
  return status & OPERATOR_FINISHED;
}

bool keymap_modifier_matches(const int8_t item, const bool held)
{
  return item == KM_ANY || (item == KM_MOD_HELD) == held;
}

/**
 * A hardware key pressed in the native curve editor, run as the Graph Editor's keymap has it, the
 * user's or the selected preset's. Framing the view is asked of the native editor; operators that
 * follow the pointer, or ask which kind with a menu, belong to its own gestures and menus.
 */
void run_key(bContext *C, const DictionaryValue &query)
{
  wmWindowManager *wm = CTX_wm_manager(C);
  const bool shift = query.lookup_int("shift").value_or(0), ctrl = query.lookup_int("ctrl").value_or(0),
             alt = query.lookup_int("alt").value_or(0), oskey = query.lookup_int("oskey").value_or(0);
  /* Keys as Blender names them; the Mac's Delete is Backspace, which Blender also takes. */
  std::vector<std::string> names = {std::string(query.lookup_str("key").value_or(""))};
  if (names[0] == "BACK_SPACE") {
    names.push_back("DEL");
  }
  auto find = [&](const int type, const bool use_ctrl, const bool use_oskey) -> wmKeyMapItem * {
    for (const char *keymap_name : {"Graph Editor", "Graph Editor Generic", "Animation"}) {
      wmKeyMap *keymap = WM_keymap_find_all(wm, keymap_name, SPACE_GRAPH, RGN_TYPE_WINDOW);
      if (!keymap) {
        keymap = WM_keymap_find_all(wm, keymap_name, SPACE_EMPTY, RGN_TYPE_WINDOW);
      }
      keymap = keymap ? WM_keymap_active(wm, keymap) : nullptr;
      if (!keymap) {
        continue;
      }
      for (wmKeyMapItem &item : keymap->items) {
        if ((item.flag & KMI_INACTIVE) || item.type != type ||
            !ELEM(item.val, KM_PRESS, KM_ANY, KM_CLICK) || !keymap_modifier_matches(item.shift, shift) ||
            !keymap_modifier_matches(item.ctrl, use_ctrl) || !keymap_modifier_matches(item.alt, alt) ||
            !keymap_modifier_matches(item.oskey, use_oskey))
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
    return;
  }
  const std::string idname = item->idname;
  if (ELEM(idname, std::string("GRAPH_OT_view_all"), std::string("GRAPH_OT_view_selected"))) {
    key_request.sequence++;
    key_request.action = idname == "GRAPH_OT_view_all" ? "frame_all" : "frame_selected";
    return;
  }
  /* Duplicating moves the copies with the pointer in Blender; here they stay where they were. */
  wmOperatorType *ot = WM_operatortype_find(
      idname == "GRAPH_OT_duplicate_move" ? "GRAPH_OT_duplicate" : idname.c_str(), false);
  if (!ot || !ot->exec || ot->modal || (ot->flag & OPTYPE_MACRO) ||
      StringRef(ot->idname).startswith("TRANSFORM_OT") || !WM_operator_poll(C, ot))
  {
    return;
  }
  /* A kind asked for with a menu, which the editor's own menus give instead. */
  if (ot->invoke == WM_menu_invoke && ot->prop &&
      !(item->ptr && RNA_property_is_set(item->ptr, ot->prop)))
  {
    return;
  }
  WM_operator_name_call_ptr(C,
                            ot,
                            wm::OpCallContext::ExecDefault,
                            idname == "GRAPH_OT_duplicate_move" ? nullptr : item->ptr,
                            nullptr);
}

/** Applies one of the native editor's edits; the undo step's name, or empty for none. */
std::optional<std::string> apply_edit(bContext *C, const DictionaryValue &query)
{
  const std::string action = std::string(query.lookup_str("action").value_or(""));
  if (action == "operator") {
    /* Pushes its own undo step. */
    return run_operator(C, query) ? std::optional<std::string>("") : std::nullopt;
  }
  if (action == "key") {
    /* Keys the keymap has nothing for are let go quietly. Operators push their own undo step. */
    run_key(C, query);
    return std::string("");
  }
  Curves curves(C);
  if (!curves.valid) {
    return std::nullopt;
  }
  if (action == "select") {
    /* Keys or handles, as [curve, key, part] with part 0 the key, -1 and 1 its handles. */
    if (!query.lookup_int("extend").value_or(0)) {
      deselect_all(curves);
    }
    int first_curve = -1;
    if (const ArrayValue *picks = query.lookup_array("keys")) {
      for (const auto &pick : picks->elements()) {
        const ArrayValue *triple = pick->as_array_value();
        if (!triple || triple->elements().size() != 3) {
          continue;
        }
        int values[3];
        for (int i = 0; i < 3; i++) {
          const IntValue *number = triple->elements()[i]->as_int_value();
          values[i] = number ? int(number->value()) : 0;
        }
        FCurve *fcu = curves.fcurve(values[0]);
        if (!fcu || values[1] < 0 || values[1] >= int(fcu->totvert)) {
          continue;
        }
        BezTriple &bezt = fcu->bezt[values[1]];
        if (values[2] < 0) {
          bezt.f1 |= SELECT;
        }
        else if (values[2] > 0) {
          bezt.f3 |= SELECT;
        }
        else {
          BEZT_SEL_ALL(&bezt);
        }
        if (first_curve < 0) {
          first_curve = values[0];
        }
      }
    }
    if (first_curve >= 0) {
      activate(curves, first_curve);
    }
    WM_event_add_notifier(C, NC_ANIMATION | ND_KEYFRAME | NA_SELECTED, nullptr);
    return std::string("Select Keyframes");
  }
  if (action == "select_all") {
    const bool select = query.lookup_int("value").value_or(1);
    for (bAnimListElem *ale : curves.items) {
      FCurve &fcu = *static_cast<FCurve *>(ale->key_data);
      if (!(fcu.flag & FCURVE_VISIBLE)) {
        continue;
      }
      for (int i = 0; i < fcu.totvert; i++) {
        if (select) {
          BEZT_SEL_ALL(&fcu.bezt[i]);
        }
        else {
          BEZT_DESEL_ALL(&fcu.bezt[i]);
        }
      }
    }
    WM_event_add_notifier(C, NC_ANIMATION | ND_KEYFRAME | NA_SELECTED, nullptr);
    return std::string(select ? "Select All" : "Deselect All");
  }
  if (action == "box") {
    /* Keys inside a frame and shown value range, of the curves shown. */
    const float frames[2] = {float(number(query, "f0")), float(number(query, "f1"))};
    const float values[2] = {float(number(query, "v0")), float(number(query, "v1"))};
    if (!query.lookup_int("extend").value_or(0)) {
      deselect_all(curves);
    }
    for (bAnimListElem *ale : curves.items) {
      FCurve &fcu = *static_cast<FCurve *>(ale->key_data);
      if (!(fcu.flag & FCURVE_VISIBLE)) {
        continue;
      }
      const ValueMapping mapping = value_mapping(curves, ale);
      ANIM_nla_mapping_apply_if_needed_fcurve(ale, &fcu, false, false);
      for (int i = 0; i < fcu.totvert; i++) {
        BezTriple &bezt = fcu.bezt[i];
        const float value = (bezt.vec[1][1] + mapping.offset) * mapping.scale;
        if (bezt.vec[1][0] >= std::min(frames[0], frames[1]) &&
            bezt.vec[1][0] <= std::max(frames[0], frames[1]) &&
            value >= std::min(values[0], values[1]) && value <= std::max(values[0], values[1]))
        {
          BEZT_SEL_ALL(&bezt);
        }
      }
      ANIM_nla_mapping_apply_if_needed_fcurve(ale, &fcu, true, false);
    }
    WM_event_add_notifier(C, NC_ANIMATION | ND_KEYFRAME | NA_SELECTED, nullptr);
    return std::string("Box Select");
  }
  if (action == "move") {
    /* A drag: each update moves the keys from where they began, the end makes it one step. */
    const std::string interaction = std::string(query.lookup_str("interaction").value_or(""));
    const std::string phase = std::string(query.lookup_str("phase").value_or("end"));
    if (interaction.empty() || drag.interaction != interaction) {
      begin_drag(curves, interaction);
    }
    if (phase == "cancel") {
      for (bAnimListElem *ale : curves.items) {
        FCurve &fcu = *static_cast<FCurve *>(ale->key_data);
        auto found = drag.keys.find(&fcu);
        if (found != drag.keys.end() && int(found->second.size()) == fcu.totvert) {
          ANIM_nla_mapping_apply_if_needed_fcurve(ale, &fcu, false, false);
          std::copy(found->second.begin(), found->second.end(), fcu.bezt);
          ANIM_nla_mapping_apply_if_needed_fcurve(ale, &fcu, true, false);
        }
      }
      curves.update(ANIM_UPDATE_DEFAULT);
      drag = {};
      return std::string("");
    }
    apply_drag(curves, query);
    WM_event_add_notifier(C, NC_ANIMATION | ND_KEYFRAME | NA_EDITED, nullptr);
    if (phase == "update") {
      return std::string("");
    }
    /* Keys passed by others are sorted back into order once let go, as in Blender. */
    curves.update(ANIM_UPDATE_DEFAULT);
    drag = {};
    return std::string(number(query, "side") != 0 ? "Move Handle" : "Move Keyframes");
  }
  if (action == "set") {
    /* The selected keys' frame or value, typed in, their handles moving with them. */
    const std::optional<double> frame = query.lookup_double("frame").has_value() ?
                                            query.lookup_double("frame") :
                                            (query.lookup_int("frame") ?
                                                 std::optional<double>(*query.lookup_int("frame")) :
                                                 std::nullopt);
    const std::optional<double> value = query.lookup_double("value").has_value() ?
                                            query.lookup_double("value") :
                                            (query.lookup_int("value") ?
                                                 std::optional<double>(*query.lookup_int("value")) :
                                                 std::nullopt);
    for (bAnimListElem *ale : curves.items) {
      FCurve &fcu = *static_cast<FCurve *>(ale->key_data);
      if ((fcu.flag & FCURVE_PROTECTED) || !(fcu.flag & FCURVE_VISIBLE)) {
        continue;
      }
      const ValueMapping mapping = value_mapping(curves, ale);
      ANIM_nla_mapping_apply_if_needed_fcurve(ale, &fcu, false, false);
      for (int i = 0; i < fcu.totvert; i++) {
        BezTriple &bezt = fcu.bezt[i];
        if (!(bezt.f2 & SELECT)) {
          continue;
        }
        const float df = frame ? float(*frame) - bezt.vec[1][0] : 0.0f;
        const float dv = value ? float(*value) / (mapping.scale != 0.0f ? mapping.scale : 1.0f) -
                                     mapping.offset - bezt.vec[1][1] :
                                 0.0f;
        for (int point = 0; point < 3; point++) {
          bezt.vec[point][0] += df;
          bezt.vec[point][1] += dv;
        }
      }
      ANIM_nla_mapping_apply_if_needed_fcurve(ale, &fcu, true, false);
    }
    curves.update(ANIM_UPDATE_DEFAULT);
    WM_event_add_notifier(C, NC_ANIMATION | ND_KEYFRAME | NA_EDITED, nullptr);
    return std::string("Set Keyframe Value");
  }
  if (action == "channel") {
    /* A channel's eye, lock, mute, or making it the active one. */
    const int index = int(number(query, "curve", -1));
    if (index < 0 || index >= int(curves.items.size())) {
      return std::nullopt;
    }
    const std::string setting = std::string(query.lookup_str("setting").value_or(""));
    if (setting == "active") {
      activate(curves, index);
      WM_event_add_notifier(C, NC_ANIMATION | ND_ANIMCHAN | NA_SELECTED, nullptr);
      return std::string("Select Channel");
    }
    const eAnimChannel_Settings which = setting == "visible" ? ACHANNEL_SETTING_VISIBLE :
                                        setting == "locked"  ? ACHANNEL_SETTING_PROTECT :
                                                               ACHANNEL_SETTING_MUTE;
    ANIM_channel_setting_set(&curves.ac,
                             curves.items[index],
                             which,
                             query.lookup_int("value").value_or(0) ? ACHANNEL_SETFLAG_ADD :
                                                                     ACHANNEL_SETFLAG_CLEAR);
    curves.update(ANIM_UPDATE_DEPS);
    WM_event_add_notifier(C, NC_ANIMATION | ND_ANIMCHAN | NA_EDITED, nullptr);
    return std::string("Channel Setting");
  }
  return std::nullopt;
}

}  // namespace

/**
 * The curves, for the state the native Graph Editor shows them in: `only_selected` (the selected
 * objects' curves, as the Graph Editor's default), `normalize`, and `range`, the frames shown,
 * where curves that cannot be drawn from their keys alone are sampled.
 */
std::shared_ptr<DictionaryValue> native_graph_read(bContext *C, const DictionaryValue &state)
{
  GraphSpaceContext space(C, &state);
  return read_curves(C, state);
}

}  // namespace blender::ed::graph

namespace blender {

void ED_graph_native_exit()
{
  /* Its read holds Blender's allocations, which must not outlive it at quit. */
  ed::graph::last_read = {};
  ed::graph::drag = {};
}

ScrArea *ED_graph_native_area(bContext *C)
{
  ScrArea *area = ed::graph::native_graph_area(C);
  /* As `GraphSpaceContext` shows it: keys and curves, not drivers. */
  static_cast<SpaceGraph *>(area->spacedata.first)->mode = SIPO_MODE_ANIMATION;
  return area;
}

}  // namespace blender

namespace blender::ed::graph {

/** An edit of the curves, with the `state` they are shown in: why it failed, if it did. */
std::string native_graph_edit(bContext *C, const DictionaryValue &edit)
{
  const DictionaryValue *state = edit.lookup_dict("state");
  GraphSpaceContext space(C, state ? state : &edit);
  const std::optional<std::string> undo = apply_edit(C, edit);
  if (!undo) {
    return "This curve change could not be made.";
  }
  if (!undo->empty()) {
    ED_undo_push(C, undo->c_str());
  }
  return "";
}

}  // namespace blender::ed::graph
