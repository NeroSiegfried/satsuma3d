/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup edinterface
 *
 * Blender's panels as views of controls for a platform's own interface, see
 * `WM_native_ui_views.hh`: the Properties editor, the tool settings, the viewport's shading and
 * overlays, and the Preferences. Panels are drawn and read as `native_properties_describe` reads
 * them, and edited the way it edits them, so a view and the panels Blender draws itself agree.
 *
 * Parameters: `tab`, such as `OBJECT`, `TOOL`, `SHADING` or a Preferences section, and
 * `properties`, set for the Properties editor's own Tool tab rather than the tool settings.
 */

#include <deque>
#include <set>
#include <sstream>
#include <unordered_map>

#include "BLI_map.hh"
#include "BLI_serialize.hh"
#include "BLI_string.h"
#include "BLI_string_ref.hh"

#include "WM_api.hh"
#include "WM_native_ui_views.hh"
#include "WM_types.hh"

namespace blender::ui {

void native_properties_describe(bContext *C,
                                const std::string &json,
                                io::serialize::DictionaryValue &r_result);
std::string native_properties_query(bContext *C, const std::string &json, bool execute);

namespace {

using namespace io::serialize;
using namespace wm::native_ui;
using Fields = flatbuffers::FlatBufferBuilder;

/** What a properties view keeps between its builds and the commands that follow them. */
struct PropertiesData : public ViewData {
  std::string tab;
  /** The Properties editor's own Tool tab, rather than the tool settings. */
  bool tool_tab = false;
  /** Per tab: its open panels, once an interface opened or closed one. Kept for as long as
   * Blender runs, as a view shown again is subscribed to again. */
  Map<std::string, std::set<std::string>> &expanded = shared_expanded();
  /** Per tab: sub-panels an interface opened or closed. */
  Map<std::string, Map<std::string, bool>> &subpanels = shared_subpanels();

  static Map<std::string, std::set<std::string>> &shared_expanded()
  {
    static Map<std::string, std::set<std::string>> expanded;
    return expanded;
  }
  static Map<std::string, Map<std::string, bool>> &shared_subpanels()
  {
    static Map<std::string, Map<std::string, bool>> subpanels;
    return subpanels;
  }

  /** The last description, which the nodes below point into. */
  std::unique_ptr<DictionaryValue> described;
  std::deque<DictionaryValue> owned;
  /** What each node edits, by its key: a field of a panel. */
  Map<std::string, const DictionaryValue *> edits;
  /** Buttons beside a list or a row, by their key: the control they are beside. */
  Map<std::string, const DictionaryValue *> owners;
  /** Rows of lists, by their key: their list and index. */
  Map<std::string, std::pair<const DictionaryValue *, int64_t>> rows;
  /** Panels by their node's key: their id, whether a tab's outer panel, and open. */
  struct PanelState {
    std::string id;
    bool outer;
    bool open;
  };
  Map<std::string, PanelState> panels;
  /** The described object and tab, which edits name. */
  std::string identity;
  /** A drag's interaction, which makes one undo step of it. */
  int interaction = 0;
  bool dragging = false;

  /** The tab's open panels: those open now, the first time one is opened or closed. */
  std::set<std::string> &expanded_panels()
  {
    return expanded.lookup_or_add_cb(tab, [&]() {
      std::set<std::string> opened;
      for (const PanelState &state : panels.values()) {
        if (state.outer && state.open) {
          opened.insert(state.id);
        }
      }
      return opened;
    });
  }
};

std::string encode(const Value &value)
{
  std::ostringstream stream;
  JsonFormatter().serialize(stream, value);
  return stream.str();
}

std::string_view text(const DictionaryValue &dictionary, const StringRef key)
{
  const std::optional<StringRefNull> value = dictionary.lookup_str(key);
  return value ? std::string_view(*value) : std::string_view();
}

/** A number, written as an integer, a double or a bool. */
double number(const DictionaryValue &dictionary, const StringRef key, const double fallback = 0.0)
{
  const std::shared_ptr<Value> *value = dictionary.lookup(key);
  if (value == nullptr) {
    return fallback;
  }
  switch ((*value)->type()) {
    case eValueType::Int:
      return double((*value)->as_int_value()->value());
    case eValueType::Double:
      return (*value)->as_double_value()->value();
    case eValueType::Boolean:
      return (*value)->as_boolean_value()->value() ? 1.0 : 0.0;
    default:
      return fallback;
  }
}

bool flag(const DictionaryValue &dictionary, const StringRef key, const bool fallback = false)
{
  return number(dictionary, key, fallback ? 1.0 : 0.0) != 0.0;
}

protocol::Animation animation(const std::string_view state)
{
  if (state == "KEYED") {
    return protocol::Animation::Keyed;
  }
  if (state == "ANIMATED") {
    return protocol::Animation::Animated;
  }
  if (state == "CHANGED") {
    return protocol::Animation::Changed;
  }
  if (state == "DRIVEN") {
    return protocol::Animation::Driven;
  }
  return protocol::Animation::None;
}

/* -------------------------------------------------------------------- */
/** \name From Panels to Controls
 * \{ */

class Converter {
  ViewBuilder &builder_;
  PropertiesData &data_;
  /** Keys given to nodes so far: a property drawn twice gets a second key. */
  std::set<std::string> used_;
  std::unordered_map<const DictionaryValue *, std::string> keys_;
  std::vector<flatbuffers::Offset<protocol::Option>> options_;
  std::vector<flatbuffers::Offset<flatbuffers::String>> strings_;
  /** Buttons made here rather than described, which their nodes' edits point to. */
  std::deque<DictionaryValue> &owned_;

 public:
  Converter(ViewBuilder &builder, PropertiesData &data)
      : builder_(builder), data_(data), owned_(data.owned)
  {
  }

  void view(const DictionaryValue &described)
  {
    const NodeId top = builder_.top("properties", [&](Fields &buffer, NodeFields &fields) {
      fields.label = text(described, "name");
      /* What it shows: another object's controls start again. */
      fields.property = text(described, "id");
      return protocol::CreateGroup(buffer);
    });
    tabs(top, described);
    if (const DictionaryValue *style = described.lookup_dict("text_style")) {
      text_style(top, *style);
    }
    const ArrayValue *sections = described.lookup_array("sections");
    if (sections == nullptr) {
      return;
    }
    if (text(described, "tab") == "PHYSICS") {
      physics(top, *sections);
      return;
    }
    for (const std::shared_ptr<Value> &section : sections->elements()) {
      if (const DictionaryValue *dictionary = section->as_dictionary_value()) {
        this->section(top, dictionary, std::string(text(*dictionary, "id")));
      }
    }
  }

 private:
  /** A key of its own for \a field, the same each time it is asked for. */
  const std::string &key(const DictionaryValue &field, const std::string_view fallback = {})
  {
    auto found = keys_.find(&field);
    if (found != keys_.end()) {
      return found->second;
    }
    std::string base(text(field, "key"));
    if (base.empty()) {
      base = fallback;
    }
    std::string key = base;
    for (int i = 2; used_.count(key); i++) {
      key = base + "#" + std::to_string(i);
    }
    used_.insert(key);
    return keys_.emplace(&field, std::move(key)).first->second;
  }

  void tabs(const NodeId parent, const DictionaryValue &described)
  {
    const ArrayValue *tabs = described.lookup_array("tabs");
    if (tabs == nullptr || tabs->elements().is_empty()) {
      return;
    }
    builder_.add(parent, "tabs", [&](Fields &buffer, NodeFields & /*fields*/) {
      options_.clear();
      for (const std::shared_ptr<Value> &tab : tabs->elements()) {
        if (const DictionaryValue *item = tab->as_dictionary_value()) {
          options_.push_back(protocol::CreateOptionDirect(buffer,
                                                          text(*item, "id").data(),
                                                          text(*item, "title").data(),
                                                          text(*item, "icon").data(),
                                                          nullptr,
                                                          nullptr,
                                                          int32_t(number(*item, "group")),
                                                          flag(*item, "external")));
        }
      }
      return protocol::CreateChoice(buffer,
                                    buffer.CreateString(text(described, "tab")),
                                    buffer.CreateVector(options_),
                                    protocol::ChoiceStyle::Tabs);
    });
  }

  /**
   * A panel of \a section, or of only its title and \a id without one. \a switch_field heads it,
   * as a physics' switch heads its settings.
   */
  void section(const NodeId parent,
               const DictionaryValue *section_ptr,
               const std::string &id,
               const DictionaryValue *switch_field = nullptr,
               const std::string_view title = {},
               const std::string_view icon = {})
  {
    static const DictionaryValue empty;
    const DictionaryValue &section = section_ptr ? *section_ptr : empty;
    const ArrayValue *properties = section.lookup_array("properties");
    const std::string panel_key = "panel:" + id;
    /* Its header's controls, keyed before the panel is written. */
    std::vector<std::string> header;
    if (switch_field) {
      header.push_back(key(*switch_field, panel_key + ":header"));
    }
    /* A sub-panel's header controls are its own. */
    std::unordered_map<std::string, std::vector<std::string>> subpanel_headers;
    if (properties) {
      for (const std::shared_ptr<Value> &property : properties->elements()) {
        const DictionaryValue *field = property->as_dictionary_value();
        if (field && flag(*field, "header")) {
          const std::string &field_key = key(*field, panel_key + ":header");
          if (text(*field, "section").empty()) {
            header.push_back(field_key);
          }
          else {
            subpanel_headers[std::string(text(*field, "subpanel"))].push_back(field_key);
          }
        }
      }
    }
    const bool open = section_ptr && flag(section, "open", true);
    data_.panels.add_overwrite(panel_key, {id, true, open});
    const NodeId panel = builder_.add(parent, panel_key, [&](Fields &buffer, NodeFields &fields) {
      fields.label = section_ptr ? text(section, "title") : title;
      fields.icon = icon.empty() ? text(section, "icon") : icon;
      strings_.clear();
      for (const std::string &key : header) {
        strings_.push_back(buffer.CreateString(key));
      }
      return protocol::CreatePanel(buffer,
                                   open,
                                   flag(section, "header_hidden"),
                                   buffer.CreateVector(strings_),
                                   flag(section, "active"),
                                   int32_t(number(section, "stack_index", -1)),
                                   section_ptr != nullptr);
    });
    if (switch_field) {
      this->field(panel, *switch_field);
    }
    if (properties == nullptr) {
      return;
    }

    /* Sub-panels nest by depth; components of a vector share a row. */
    std::vector<std::pair<int64_t, NodeId>> nested;
    std::unordered_map<std::string, NodeId> subpanels;
    std::unordered_map<std::string, NodeId> rows;
    std::unordered_map<std::string, NodeId> toggles;
    for (const std::shared_ptr<Value> &property : properties->elements()) {
      const DictionaryValue *field = property->as_dictionary_value();
      if (field == nullptr) {
        continue;
      }
      const std::string_view subpanel = text(*field, "subpanel");
      if (text(*field, "type") == "SUBPANEL") {
        const int64_t depth = int64_t(number(*field, "depth", 1));
        while (!nested.empty() && nested.back().first >= depth) {
          nested.pop_back();
        }
        const std::string key = "panel:" + std::string(subpanel);
        const bool open = flag(*field, "open", true);
        data_.panels.add_overwrite(key, {std::string(subpanel), false, open});
        const NodeId node = builder_.add(
            nested.empty() ? panel : nested.back().second,
            key,
            [&](Fields &buffer, NodeFields &fields) {
              fields.label = text(*field, "section");
              strings_.clear();
              for (const std::string &key : subpanel_headers[std::string(subpanel)]) {
                strings_.push_back(buffer.CreateString(key));
              }
              return protocol::CreatePanel(buffer, open, false, buffer.CreateVector(strings_));
            });
        nested.emplace_back(depth, node);
        subpanels[std::string(subpanel)] = node;
        continue;
      }
      NodeId parent_node = panel;
      if (!subpanel.empty()) {
        const auto found = subpanels.find(std::string(subpanel));
        if (found != subpanels.end()) {
          parent_node = found->second;
        }
      }
      if (const std::string_view group = text(*field, "toggle_group"); !group.empty()) {
        /* Toggles drawn together, such as a mirror's X, Y and Z. */
        const std::string key = "toggles:" + std::string(group);
        auto found = toggles.find(key);
        if (found == toggles.end()) {
          const NodeId row = builder_.add(
              parent_node, key, [&](Fields &buffer, NodeFields &fields) {
                const std::string_view caption = text(*field, "toggle_caption");
                fields.label = caption.empty() ? text(*field, "label") : caption;
                return protocol::CreateGroup(buffer, protocol::Layout::Joined);
              });
          found = toggles.emplace(key, row).first;
        }
        this->field(found->second, *field);
        continue;
      }
      if (const std::string_view group = text(*field, "group_key"); !group.empty()) {
        const std::string key = "group:" + std::string(group);
        auto found = rows.find(key);
        if (found == rows.end()) {
          const NodeId row = builder_.add(
              parent_node, key, [&](Fields &buffer, NodeFields &fields) {
                fields.label = text(*field, "group");
                return protocol::CreateGroup(buffer, protocol::Layout::Row);
              });
          /* A rotation's mode, once for its components. */
          if (const DictionaryValue *mode = field->lookup_dict("group_menu")) {
            this->field(row, *mode, true, protocol::Role::Mode);
          }
          found = rows.emplace(key, row).first;
        }
        this->field(found->second, *field, false);
        continue;
      }
      this->field(parent_node, *field);
    }
  }

  /** What every control has. */
  void common(const DictionaryValue &field, NodeFields &fields)
  {
    fields.label = text(field, "label");
    fields.icon = text(field, "icon");
    fields.enabled = flag(field, "editable", true);
    fields.mixed = flag(field, "mixed");
    fields.animation = animation(text(field, "anim_state"));
    fields.property = text(field, "property");
    const ArrayValue *actions = field.lookup_array("animation");
    fields.animatable = actions && !actions->elements().is_empty();
    fields.short_label = text(field, "toolbar_label");
    fields.leading_icon = text(field, "leading_icon");
    if (flag(field, "header_name")) {
      fields.role = protocol::Role::Name;
    }
    else if (flag(field, "header_cluster")) {
      fields.role = protocol::Role::Visibility;
    }
  }

  flatbuffers::Offset<flatbuffers::Vector<flatbuffers::Offset<protocol::Option>>> options(
      Fields &buffer, const DictionaryValue &field)
  {
    options_.clear();
    if (const ArrayValue *items = field.lookup_array("options")) {
      for (const std::shared_ptr<Value> &item : items->elements()) {
        const DictionaryValue *option = item->as_dictionary_value();
        if (option == nullptr) {
          continue;
        }
        /* A heading names the options after it, and has no value. */
        const std::string_view heading = text(*option, "heading");
        const std::string users = users_text(*option);
        options_.push_back(protocol::CreateOptionDirect(
            buffer,
            heading.empty() ? text(*option, "value").data() : nullptr,
            heading.empty() ? text(*option, "label").data() : heading.data(),
            text(*option, "icon").data(),
            text(*option, "preview").data(),
            users.empty() ? nullptr : users.c_str()));
      }
    }
    return buffer.CreateVector(options_);
  }

  /** Who uses a data-block, as its options describe it. */
  static std::string users_text(const DictionaryValue &item)
  {
    std::string result;
    const int64_t users = int64_t(number(item, "users", -1));
    if (users > 1) {
      result = std::to_string(users) + " users";
    }
    else if (users == 0) {
      result = "No users";
    }
    if (flag(item, "linked")) {
      result += result.empty() ? "Linked" : " · Linked";
    }
    return result;
  }

  NodeId field(const NodeId parent,
               const DictionaryValue &field,
               const bool with_group_menu = true,
               const protocol::Role role = protocol::Role::None)
  {
    const std::string &key = this->key(field, "field");
    data_.edits.add_overwrite(key, &field);
    const std::string_view type = text(field, "type");
    /* What every control has, and what this one is to its parent. */
    const auto common = [&](const DictionaryValue &field, NodeFields &fields) {
      this->common(field, fields);
      if (role != protocol::Role::None) {
        fields.role = role;
      }
    };
    NodeId node;
    if (type == "BOOLEAN") {
      node = builder_.add(parent, key, [&](Fields &buffer, NodeFields &fields) {
        common(field, fields);
        return protocol::CreateToggle(buffer, flag(field, "value"));
      });
    }
    else if (type == "INT" || type == "FLOAT") {
      node = builder_.add(parent, key, [&](Fields &buffer, NodeFields &fields) {
        common(field, fields);
        const DictionaryValue *slider = field.lookup_dict("slider");
        const double min = number(field, "min", -INFINITY);
        const double max = number(field, "max", INFINITY);
        const std::string_view scale = slider ? text(*slider, "scale") : std::string_view();
        return protocol::CreateNumber(
            buffer,
            number(field, "value"),
            type == "INT",
            flag(field, "angle") ? protocol::NumberKind::Angle : protocol::NumberKind::Plain,
            min,
            max,
            slider ? number(*slider, "min", min) : min,
            slider ? number(*slider, "max", max) : max,
            number(field, "dragStep"),
            3,
            slider != nullptr,
            scale == "LOG"   ? protocol::Scale::Logarithmic :
            scale == "CUBIC" ? protocol::Scale::Cubic :
                               protocol::Scale::Linear,
            buffer.CreateString(text(field, "unit_suffix")));
      });
    }
    else if (type == "STRING") {
      node = builder_.add(parent, key, [&](Fields &buffer, NodeFields &fields) {
        common(field, fields);
        return protocol::CreateTextFieldDirect(buffer, text(field, "value").data());
      });
    }
    else if (type == "ENUM" || type == "OPERATOR_MENU") {
      node = builder_.add(parent, key, [&](Fields &buffer, NodeFields &fields) {
        common(field, fields);
        const auto choices = options(buffer, field);
        return protocol::CreateChoice(buffer,
                                      buffer.CreateString(text(field, "value")),
                                      choices,
                                      type == "OPERATOR_MENU" ? protocol::ChoiceStyle::Actions :
                                      flag(field, "expand")   ? protocol::ChoiceStyle::Expanded :
                                                                protocol::ChoiceStyle::Menu);
      });
    }
    else if (type == "COLOR") {
      node = builder_.add(parent, key, [&](Fields &buffer, NodeFields &fields) {
        common(field, fields);
        std::vector<double> values;
        if (const ArrayValue *components = field.lookup_array("value")) {
          for (const std::shared_ptr<Value> &component : components->elements()) {
            const DoubleValue *value = component->as_double_value();
            values.push_back(value ? value->value() : 0.0);
          }
        }
        return protocol::CreateColor(buffer, buffer.CreateVector(values), flag(field, "alpha"));
      });
    }
    else if (type == "ID") {
      node = builder_.add(parent, key, [&](Fields &buffer, NodeFields &fields) {
        common(field, fields);
        const auto choices = options(buffer, field);
        return protocol::CreateReference(buffer,
                                         buffer.CreateString(text(field, "id_type")),
                                         buffer.CreateString(text(field, "name")),
                                         buffer.CreateString(text(field, "value")),
                                         int32_t(number(field, "users")),
                                         flag(field, "linked"),
                                         flag(field, "fake_user"),
                                         flag(field, "can_new"),
                                         flag(field, "can_unlink"),
                                         flag(field, "can_single_user"),
                                         field.lookup("fake_user") != nullptr,
                                         choices,
                                         buffer.CreateString(text(field, "preview")),
                                         flag(field, "font_picker"),
                                         buffer.CreateString(text(field, "font_file")));
      });
    }
    else if (type == "LIST") {
      node = list(parent, key, field);
    }
    else if (type == "ITEM_ROW") {
      /* A row like a list's, with none to choose from. */
      node = builder_.add(parent, key, [&](Fields &buffer, NodeFields &fields) {
        common(field, fields);
        return protocol::CreateRow(buffer);
      });
      children(node, field, "controls");
      buttons(node, field, "operators", field);
    }
    else if (type == "PREVIEW") {
      node = builder_.add(parent, key, [&](Fields &buffer, NodeFields &fields) {
        common(field, fields);
        return protocol::CreatePictureDirect(buffer, text(field, "preview").data());
      });
    }
    else if (type == "MENU") {
      node = builder_.add(parent, key, [&](Fields &buffer, NodeFields &fields) {
        common(field, fields);
        const auto menu = protocol::CreateTextValueDirect(buffer, text(field, "menu").data());
        const auto param = protocol::CreateParamDirect(
            buffer, "menu", protocol::Value::TextValue, menu.Union());
        return protocol::CreateMenuButton(
            buffer, buffer.CreateString("menu"), buffer.CreateVector(&param, 1));
      });
    }
    else if (type == "OPERATOR" && flag(field, "checkbox")) {
      node = builder_.add(parent, key, [&](Fields &buffer, NodeFields &fields) {
        common(field, fields);
        return protocol::CreateToggle(buffer, flag(field, "value"));
      });
    }
    else if (type == "OPERATOR") {
      node = builder_.add(parent, key, [&](Fields &buffer, NodeFields &fields) {
        common(field, fields);
        return protocol::CreateButton(buffer);
      });
    }
    else {
      /* A property of a kind not shown, such as a collection, named for information. */
      node = builder_.add(parent, key, [&](Fields &buffer, NodeFields &fields) {
        common(field, fields);
        return protocol::CreateLabelDirect(buffer, text(field, "value").data());
      });
    }
    /* Shown with it: a rotation's mode, a component's lock, a preview's shape. */
    for (const auto &[attached, attached_role] : {std::pair{"group_menu", protocol::Role::Mode},
                                                  std::pair{"lock", protocol::Role::Lock},
                                                  std::pair{"shape", protocol::Role::Shape}})
    {
      if (!with_group_menu && STREQ(attached, "group_menu")) {
        continue;
      }
      if (const DictionaryValue *child = field.lookup_dict(attached)) {
        this->field(node, *child, true, attached_role);
      }
    }
    return node;
  }

  void children(const NodeId parent, const DictionaryValue &field, const StringRef name)
  {
    if (const ArrayValue *controls = field.lookup_array(name)) {
      for (const std::shared_ptr<Value> &control : controls->elements()) {
        if (const DictionaryValue *child = control->as_dictionary_value()) {
          this->field(parent, *child);
        }
      }
    }
  }

  /** Buttons beside a list or a row: operators, run as from the panel of \a owner. */
  void buttons(const NodeId parent,
               const DictionaryValue &field,
               const StringRef name,
               const DictionaryValue &owner)
  {
    const ArrayValue *operators = field.lookup_array(name);
    if (operators == nullptr) {
      return;
    }
    for (const std::shared_ptr<Value> &item : operators->elements()) {
      if (const DictionaryValue *button = item->as_dictionary_value()) {
        this->button(parent, *button, owner);
      }
    }
  }

  void button(const NodeId parent,
              const DictionaryValue &button,
              const DictionaryValue &owner,
              const protocol::Role role = protocol::Role::None)
  {
    const std::string &key = this->key(button, "button");
    data_.edits.add_overwrite(key, &button);
    data_.owners.add_overwrite(key, &owner);
    builder_.add(parent, key, [&](Fields &buffer, NodeFields &fields) {
      fields.label = text(button, "label");
      fields.icon = text(button, "icon");
      fields.enabled = flag(button, "editable", true);
      fields.role = role;
      return protocol::CreateButton(buffer, button_style(button));
    });
  }

  static protocol::ButtonStyle button_style(const DictionaryValue &button)
  {
    const std::string_view operator_id = text(button, "operator");
    const std::string_view label = text(button, "label");
    const bool destructive = operator_id.find("remove") != std::string_view::npos ||
                             operator_id.find("delete") != std::string_view::npos ||
                             label.substr(0, 6) == "Remove" || label.substr(0, 6) == "Delete";
    return destructive ? protocol::ButtonStyle::Destructive : protocol::ButtonStyle::Normal;
  }

  NodeId list(const NodeId parent, const std::string &key, const DictionaryValue &field)
  {
    const ArrayValue *rows = field.lookup_array("rows");
    const int64_t active = int64_t(number(field, "value", -1));
    std::string active_key;
    bool tree = false;
    if (rows) {
      for (const std::shared_ptr<Value> &item : rows->elements()) {
        const DictionaryValue *row = item->as_dictionary_value();
        if (row && int64_t(number(*row, "index")) == active) {
          active_key = key + ":" + std::to_string(active);
        }
        tree |= row && number(*row, "depth") > 0;
      }
    }
    const NodeId list = builder_.add(parent, key, [&](Fields &buffer, NodeFields &fields) {
      common(field, fields);
      return protocol::CreateListDirect(buffer,
                                        active_key.c_str(),
                                        field.lookup_dict("add") != nullptr,
                                        field.lookup_dict("remove") != nullptr,
                                        flag(field, "reorder"),
                                        tree,
                                        text(field, "menu").data());
    });
    if (rows) {
      for (const std::shared_ptr<Value> &item : rows->elements()) {
        const DictionaryValue *row = item->as_dictionary_value();
        if (row == nullptr) {
          continue;
        }
        const int64_t index = int64_t(number(*row, "index"));
        const std::string row_key = key + ":" + std::to_string(index);
        data_.rows.add_overwrite(row_key, {&field, index});
        const NodeId node = builder_.add(list, row_key, [&](Fields &buffer, NodeFields &fields) {
          fields.label = text(*row, "label");
          fields.icon = text(*row, "icon");
          return protocol::CreateRowDirect(buffer,
                                           int32_t(number(*row, "depth")),
                                           index == active,
                                           flag(*row, "rename") ||
                                               !text(*row, "rename_key").empty(),
                                           text(*row, "preview").data());
        });
        children(node, *row, "controls");
      }
    }
    /* Adding and removing are the list's own commands; the rest are buttons beside it. */
    buttons(list, field, "extras", field);
    if (const std::string_view duplicate = text(field, "duplicate"); !duplicate.empty()) {
      DictionaryValue &button = owned_.emplace_back();
      button.append_str("key", key + ":duplicate");
      button.append_str("operator_call", std::string(duplicate));
      button.append_str("label", "Duplicate");
      button.append_str("icon", "DUPLICATE");
      this->button(list, button, field, protocol::Role::Duplicate);
    }
    return list;
  }

  /** Physics are switched on and off by the buttons of a panel of their own; each is a panel
   * here, its switch in its header and its settings, while on, below. */
  void physics(const NodeId parent, const ArrayValue &sections)
  {
    const DictionaryValue *add = nullptr;
    Map<std::string, const DictionaryValue *> by_id;
    for (const std::shared_ptr<Value> &item : sections.elements()) {
      if (const DictionaryValue *section = item->as_dictionary_value()) {
        if (text(*section, "id") == "PHYSICS_PT_add") {
          add = section;
        }
        else {
          by_id.add_overwrite(std::string(text(*section, "id")), section);
        }
      }
    }
    std::set<std::string> used;
    if (const ArrayValue *switches = add ? add->lookup_array("properties") : nullptr) {
      for (const std::shared_ptr<Value> &item : switches->elements()) {
        const DictionaryValue *toggle = item->as_dictionary_value();
        if (toggle == nullptr) {
          continue;
        }
        std::string id(text(*toggle, "physics_panel"));
        if (id.empty()) {
          id = text(*toggle, "key");
        }
        const DictionaryValue *const *settings = by_id.lookup_ptr(id);
        const bool on = flag(*toggle, "value") && settings;
        section(parent,
                on ? *settings : nullptr,
                id,
                toggle,
                text(*toggle, "label"),
                text(*toggle, "leading_icon"));
        if (on) {
          used.insert(id);
        }
      }
    }
    for (const std::shared_ptr<Value> &item : sections.elements()) {
      const DictionaryValue *section = item->as_dictionary_value();
      if (section && section != add && !used.count(std::string(text(*section, "id")))) {
        this->section(parent, section, std::string(text(*section, "id")));
      }
    }
  }

  /** A text object's style, which an interface shows as its own text formatting controls. */
  void text_style(const NodeId parent, const DictionaryValue &style)
  {
    const NodeId group = builder_.add(parent, "text_style", [&](Fields &buffer, NodeFields &) {
      return protocol::CreateGroup(buffer);
    });
    for (const DictionaryValue::Item &item : style.elements()) {
      const std::string key = "text_style:" + item.first;
      if (const StringValue *value = item.second->as_string_value()) {
        builder_.add(group, key, [&](Fields &buffer, NodeFields &fields) {
          fields.label = item.first;
          return protocol::CreateTextFieldDirect(buffer, value->value().c_str());
        });
      }
      else if (const DoubleValue *value = item.second->as_double_value()) {
        builder_.add(group, key, [&](Fields &buffer, NodeFields &fields) {
          fields.label = item.first;
          return protocol::CreateNumber(buffer, value->value());
        });
      }
      else {
        builder_.add(group, key, [&](Fields &buffer, NodeFields &fields) {
          fields.label = item.first;
          return protocol::CreateToggle(buffer, number(style, item.first) != 0.0);
        });
      }
    }
  }
};

/** \} */

/* -------------------------------------------------------------------- */
/** \name The View
 * \{ */

std::unique_ptr<ViewData> properties_create()
{
  return std::make_unique<PropertiesData>();
}

std::string properties_request(const PropertiesData &data)
{
  DictionaryValue request;
  request.append_str("tab", data.tab);
  request.append_int("properties", data.tool_tab);
  if (const std::set<std::string> *expanded = data.expanded.lookup_ptr(data.tab)) {
    std::shared_ptr<ArrayValue> list = request.append_array("expanded");
    for (const std::string &id : *expanded) {
      list->append_str(id);
    }
  }
  if (const Map<std::string, bool> *subpanels = data.subpanels.lookup_ptr(data.tab)) {
    std::shared_ptr<DictionaryValue> states = request.append_dict("subpanels");
    for (const auto item : subpanels->items()) {
      states->append(item.key, std::make_shared<BooleanValue>(item.value));
    }
  }
  return encode(request);
}

void properties_build(bContext *C, const Params &params, ViewData *view_data, ViewBuilder &builder)
{
  PropertiesData &data = static_cast<PropertiesData &>(*view_data);
  if (data.tab.empty()) {
    data.tab = params.text("tab").value_or("OBJECT");
    data.tool_tab = params.flag("properties");
  }
  auto described = std::make_unique<DictionaryValue>();
  native_properties_describe(C, properties_request(data), *described);
  data.edits.clear();
  data.owners.clear();
  data.rows.clear();
  data.panels.clear();
  data.owned.clear();
  data.identity = text(*described, "id");
  if (const std::string_view tab = text(*described, "tab"); !tab.empty()) {
    data.tab = tab;
  }
  Converter(builder, data).view(*described);
  /* Kept, as the nodes' edits point into it. */
  data.described = std::move(described);
}

/** The key of the name field on row \a index of \a list, if it has one. */
std::string row_rename_key(const DictionaryValue &list, const int64_t index)
{
  if (const ArrayValue *rows = list.lookup_array("rows")) {
    for (const std::shared_ptr<Value> &item : rows->elements()) {
      const DictionaryValue *row = item->as_dictionary_value();
      if (row && int64_t(number(*row, "index")) == index) {
        return std::string(text(*row, "rename_key"));
      }
    }
  }
  return {};
}

/** A value of a command, as an edit takes it. */
std::shared_ptr<Value> value_of(const protocol::Command &command)
{
  if (const protocol::BoolValue *value = command.value_as_BoolValue()) {
    return std::make_shared<BooleanValue>(value->value());
  }
  if (const protocol::IntValue *value = command.value_as_IntValue()) {
    return std::make_shared<IntValue>(value->value());
  }
  if (const protocol::FloatValue *value = command.value_as_FloatValue()) {
    return std::make_shared<DoubleValue>(value->value());
  }
  if (const protocol::TextValue *value = command.value_as_TextValue()) {
    return std::make_shared<StringValue>(value->value() ? value->value()->str() : "");
  }
  if (const protocol::FloatsValue *values = command.value_as_FloatsValue()) {
    auto array = std::make_shared<ArrayValue>();
    if (values->value()) {
      for (const double value : *values->value()) {
        array->append_double(value);
      }
    }
    return array;
  }
  return nullptr;
}

/** An edit of \a field, with \a extra in place of what it has of the same names. */
std::string edit_request(const DictionaryValue &field,
                         std::initializer_list<std::pair<const char *, std::shared_ptr<Value>>> extra)
{
  DictionaryValue request;
  for (const DictionaryValue::Item &item : field.elements()) {
    if (std::none_of(extra.begin(), extra.end(), [&](const auto &pair) {
          return item.first == pair.first;
        }))
    {
      request.append(item.first, item.second);
    }
  }
  for (const auto &[name, value] : extra) {
    if (value) {
      request.append(name, value);
    }
  }
  return encode(request);
}

std::shared_ptr<Value> string_value(std::string text)
{
  return std::make_shared<StringValue>(std::move(text));
}

std::shared_ptr<Value> int_value(const int64_t value)
{
  return std::make_shared<IntValue>(value);
}

CommandResult properties_command(bContext *C,
                                 const Params & /*params*/,
                                 ViewData *view_data,
                                 const protocol::Command &command,
                                 std::string &r_error)
{
  PropertiesData &data = static_cast<PropertiesData &>(*view_data);
  const std::string target = command.target()->str();
  const protocol::Op op = command.op();
  const auto run = [&](const std::string &request) {
    r_error = native_properties_query(C, request, true);
    return r_error.empty() ? CommandResult::Done : CommandResult::Failed;
  };
  const auto text_value = [&]() -> std::string {
    const protocol::TextValue *value = command.value_as_TextValue();
    return value && value->value() ? value->value()->str() : "";
  };

  if (target == "tabs" && op == protocol::Op::Set) {
    data.tab = text_value();
    return CommandResult::Done;
  }

  if (const PropertiesData::PanelState *panel = data.panels.lookup_ptr(target)) {
    if (ELEM(op, protocol::Op::Open, protocol::Op::Close)) {
      const bool open = op == protocol::Op::Open;
      if (panel->outer) {
        std::set<std::string> &expanded = data.expanded_panels();
        open ? (void)expanded.insert(panel->id) : (void)expanded.erase(panel->id);
      }
      else {
        data.subpanels.lookup_or_add_default(data.tab).add_overwrite(panel->id, open);
      }
      return CommandResult::Done;
    }
    if (op == protocol::Op::Move) {
      /* A stack's panel, such as a modifier, to its place in the stack. */
      DictionaryValue request;
      request.append_str("action", "property");
      request.append_str("id", data.identity);
      request.append_int("native", 1);
      request.append_str("panel", panel->id);
      request.append_str("tab", data.tab);
      request.append_str("panel_action", "reorder");
      request.append_int("to", int64_t(std::stoll(text_value().empty() ? "0" : text_value())));
      return run(encode(request));
    }
    r_error = "Panels only open, close and move";
    return CommandResult::Failed;
  }

  if (const auto *row = data.rows.lookup_ptr(target)) {
    const DictionaryValue &list = *row->first;
    switch (op) {
      case protocol::Op::Activate:
        return run(edit_request(list,
                                {{"action", string_value("property")},
                                 {"id", string_value(data.identity)},
                                 {"value", int_value(row->second)}}));
      case protocol::Op::Rename:
        if (const std::string rename_key = row_rename_key(list, row->second); !rename_key.empty())
        {
          /* Renamed by the name field Blender draws on it. */
          DictionaryValue request;
          request.append_str("action", "property");
          request.append_str("id", data.identity);
          request.append_int("native", 1);
          request.append_str("key", rename_key);
          request.append_str("panel", std::string(text(list, "panel")));
          request.append_str("tab", std::string(text(list, "tab")));
          request.append_str("type", "STRING");
          request.append_str("value", text_value());
          return run(encode(request));
        }
        return run(edit_request(list,
                                {{"action", string_value("property")},
                                 {"id", string_value(data.identity)},
                                 {"native", int_value(1)},
                                 {"list_action", string_value("rename")},
                                 {"index", int_value(row->second)},
                                 {"name", string_value(text_value())}}));
      case protocol::Op::Move: {
        /* Before the row named, or to the end. */
        const auto *before = data.rows.lookup_ptr(text_value());
        const ArrayValue *rows = list.lookup_array("rows");
        const int64_t to = before ? before->second : rows ? int64_t(rows->elements().size()) : 0;
        return run(edit_request(list,
                                {{"action", string_value("property")},
                                 {"id", string_value(data.identity)},
                                 {"native", int_value(1)},
                                 {"list_action", string_value("move")},
                                 {"from", int_value(row->second)},
                                 {"to", int_value(to)}}));
      }
      default:
        r_error = "Rows are activated, renamed and moved";
        return CommandResult::Failed;
    }
  }

  const DictionaryValue *const *found = data.edits.lookup_ptr(target);
  if (found == nullptr) {
    r_error = "Nothing to do for " + target;
    return CommandResult::Failed;
  }
  const DictionaryValue &field = **found;
  const std::string_view type = text(field, "type");
  /* What a request of a picker, list or button names, as the panel it is in has it. */
  const auto request = [&](std::initializer_list<std::pair<const char *, std::shared_ptr<Value>>>
                               extra) {
    DictionaryValue base;
    base.append_str("action", "property");
    base.append_str("id", data.identity);
    base.append_int("native", 1);
    base.append_str("key", std::string(text(field, "key")));
    base.append_str("panel", std::string(text(field, "panel")));
    base.append_str("tab", std::string(text(field, "tab")));
    if (flag(field, "header")) {
      base.append_int("header", 1);
    }
    return edit_request(base, extra);
  };

  if (type == "ID") {
    switch (op) {
      case protocol::Op::Set:
        return run(request({{"id_action", string_value("select")},
                            {"value", string_value(text_value())}}));
      case protocol::Op::Add: {
        const protocol::TextsValue *files = command.value_as_TextsValue();
        if (files == nullptr || files->value() == nullptr || files->value()->size() == 0) {
          return run(request({{"id_action", string_value("new")}}));
        }
        /* A font from its file, with the faces of its family for the other slots. */
        std::shared_ptr<DictionaryValue> family;
        if (files->value()->size() == 4) {
          family = std::make_shared<DictionaryValue>();
          const char *roles[] = {"font", "font_bold", "font_italic", "font_bold_italic"};
          for (int i = 0; i < 4; i++) {
            family->append_str(roles[i], files->value()->Get(i)->str());
          }
        }
        return run(request({{"id_action", string_value("load_font")},
                            {"value", string_value(files->value()->Get(0)->str())},
                            {"family", family}}));
      }
      case protocol::Op::Remove:
        return run(request({{"id_action", string_value("unlink")}}));
      case protocol::Op::Rename:
        return run(request({{"id_action", string_value("rename")},
                            {"value", string_value(text_value())}}));
      case protocol::Op::Invoke:
        return run(request({{"id_action", string_value(text_value())}}));
      default:
        break;
    }
  }
  else if (type == "LIST" && ELEM(op, protocol::Op::Add, protocol::Op::Remove)) {
    const DictionaryValue *button = field.lookup_dict(op == protocol::Op::Add ? "add" : "remove");
    if (button == nullptr) {
      r_error = "The list cannot do that";
      return CommandResult::Failed;
    }
    DictionaryValue base;
    base.append_str("action", "property");
    base.append_str("id", data.identity);
    base.append_int("native", 1);
    base.append_str("key", std::string(text(*button, "key")));
    base.append_str("panel", std::string(text(field, "panel")));
    base.append_str("tab", std::string(text(field, "tab")));
    return run(encode(base));
  }
  else if (type == "OPERATOR_MENU" && op == protocol::Op::Set) {
    return run(request({{"value", string_value(text_value())}}));
  }
  else if (op == protocol::Op::Invoke) {
    if (const std::string_view operator_id = text(field, "operator_call"); !operator_id.empty()) {
      /* Run as from the interface, on what is active. */
      const std::string name(operator_id);
      return WM_operator_name_call(C, name.c_str(), wm::OpCallContext::InvokeDefault, nullptr, nullptr) &
                     OPERATOR_FINISHED ?
                 CommandResult::Done :
                 CommandResult::Failed;
    }
    if (const DictionaryValue *const *owner = data.owners.lookup_ptr(target)) {
      /* A button beside a list or a row, run by its key from the panel of what it is beside. */
      DictionaryValue base;
      base.append_str("action", "property");
      base.append_str("id", data.identity);
      base.append_int("native", 1);
      base.append_str("key", std::string(text(field, "key")));
      base.append_str("panel", std::string(text(**owner, "panel")));
      base.append_str("tab", std::string(text(**owner, "tab")));
      base.append_str("type", "OPERATOR");
      return run(encode(base));
    }
    return run(edit_request(field, {{"id", string_value(data.identity)}}));
  }
  else if (ELEM(op,
                 protocol::Op::KeyframeInsert,
                 protocol::Op::KeyframeDelete,
                 protocol::Op::KeyframesClear))
  {
    /* Of all of an array's components when asked, or when the property has no others. */
    const char *verb = op == protocol::Op::KeyframeInsert ? "insert" :
                       op == protocol::Op::KeyframeDelete ? "delete" :
                                                            "clear";
    const protocol::BoolValue *all = command.value_as_BoolValue();
    std::string action = std::string(verb) + "_single";
    bool single = false;
    if (const ArrayValue *actions = field.lookup_array("animation")) {
      for (const std::shared_ptr<Value> &item : actions->elements()) {
        const DictionaryValue *entry = item->as_dictionary_value();
        single |= entry && text(*entry, "id") == action;
      }
    }
    if ((all && all->value()) || !single) {
      action = std::string(verb) + "_all";
    }
    return run(edit_request(field,
                            {{"action", string_value("animation")},
                             {"animation_action", string_value(action)},
                             {"id", string_value(data.identity)}}));
  }
  else if (op == protocol::Op::Set) {
    std::shared_ptr<Value> value = value_of(command);
    if (type == "OPERATOR") {
      /* A switch that runs its operator: turning on a physics opens its settings. */
      const std::string_view physics = text(field, "physics_panel");
      const protocol::BoolValue *on = command.value_as_BoolValue();
      if (!physics.empty() && on && on->value()) {
        data.expanded_panels().insert(std::string(physics));
      }
      return run(edit_request(field, {{"id", string_value(data.identity)}}));
    }
    if (ELEM(command.phase(), protocol::Phase::Once)) {
      data.dragging = false;
      return run(edit_request(field,
                              {{"action", string_value("property")},
                               {"id", string_value(data.identity)},
                               {"value", value}}));
    }
    /* A drag: one interaction, so one undo step, from its first update to its end. */
    if (!data.dragging || command.phase() == protocol::Phase::Begin) {
      data.interaction++;
      data.dragging = true;
    }
    const char *phase = command.phase() == protocol::Phase::End    ? "end" :
                        command.phase() == protocol::Phase::Cancel ? "cancel" :
                                                                     "update";
    if (ELEM(command.phase(), protocol::Phase::End, protocol::Phase::Cancel)) {
      data.dragging = false;
    }
    return run(edit_request(field,
                            {{"action", string_value("property")},
                             {"id", string_value(data.identity)},
                             {"value", value},
                             {"interaction", string_value("native-" + std::to_string(data.interaction))},
                             {"phase", string_value(phase)}}));
  }
  r_error = "Not something this control does";
  return CommandResult::Failed;
}

/** \} */

}  // namespace

void native_views_register()
{
  ViewType properties;
  properties.name = "properties";
  /* As the panels were read before: at most four times a second while changes keep coming. */
  properties.min_interval = 0.25;
  properties.create = properties_create;
  properties.build = properties_build;
  properties.command = properties_command;
  view_type_add(std::move(properties));
}

}  // namespace blender::ui
