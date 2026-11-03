/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * The views an interface subscribes to, see `WM_native_ui_views.hh`: subscriptions and commands
 * taken from the interface's thread, views built on Blender's loop when notifiers say they
 * changed, and updates handed back without being copied.
 */

#include <atomic>
#include <chrono>
#include <deque>
#include <limits>
#include <variant>

#include "BKE_context.hh"
#include "BKE_report.hh"

#include "CLG_log.h"

#include "BLI_map.hh"

#include "DNA_windowmanager_types.h"

#include "ED_undo.hh"

#include "GHOST_Mailbox.hh"

#include "RNA_access.hh"
#include "RNA_path.hh"
#include "RNA_prototypes.hh"

#include "WM_api.hh"
#if defined(WITH_APPLE_CROSSPLATFORM) && APPLE_TARGET_IOS
#  include "WM_apple_ios.hh"
#endif
#include "WM_native_ui.h"
#include "WM_native_ui.hh"
#include "WM_native_ui_views.hh"
#include "WM_types.hh"

#include "wm_native_ui_timing.hh"

static CLG_LogRef LOG = {"wm.native.views"};

namespace blender {
/* The old bridge's handling of undo while an operator runs, which commands share. */
extern bool bridge_dispatching;
void bridge_undo_push_pending(bContext *C);
namespace ui {
void native_properties_interaction_finish(bContext *C);
}
}  // namespace blender

namespace blender::wm::native_ui {

/* -------------------------------------------------------------------- */
/** \name Parameters
 * \{ */

const protocol::Param *Params::find(const std::string_view key) const
{
  if (params_ == nullptr) {
    return nullptr;
  }
  for (const protocol::Param *param : *params_) {
    if (param->key()->string_view() == key) {
      return param;
    }
  }
  return nullptr;
}

std::optional<std::string_view> Params::text(const std::string_view key) const
{
  const protocol::Param *param = find(key);
  if (const protocol::TextValue *value = param ? param->value_as_TextValue() : nullptr) {
    return value->value() ? value->value()->string_view() : std::string_view();
  }
  return std::nullopt;
}

std::optional<double> Params::number(const std::string_view key) const
{
  const protocol::Param *param = find(key);
  if (param == nullptr) {
    return std::nullopt;
  }
  if (const protocol::FloatValue *value = param->value_as_FloatValue()) {
    return value->value();
  }
  if (const protocol::IntValue *value = param->value_as_IntValue()) {
    return double(value->value());
  }
  return std::nullopt;
}

bool Params::flag(const std::string_view key) const
{
  const protocol::Param *param = find(key);
  const protocol::BoolValue *value = param ? param->value_as_BoolValue() : nullptr;
  return value && value->value();
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name View Types and Subscriptions
 *
 * Subscriptions, commands and updates cross between threads through mailboxes: the interface's
 * thread only queues them and takes updates, and everything else happens on Blender's loop.
 * \{ */

static Map<std::string, ViewType> builtin_view_types();

static Map<std::string, ViewType> &view_types()
{
  static Map<std::string, ViewType> types = builtin_view_types();
  return types;
}

void view_type_add(ViewType type)
{
  type.timing_name = "view." + type.name;
  std::string name = type.name;
  view_types().add_overwrite(std::move(name), std::move(type));
}

namespace {

struct Subscription {
  const ViewType *type = nullptr;
  /** The interface's `protocol::Subscribe`, which the parameters are read from. */
  std::vector<uint8_t> request;
  ViewState state;
  std::unique_ptr<ViewData> data;
  bool dirty = true;
  /** Built on the next pass whatever #ViewType::min_interval says. */
  bool urgent = false;
  std::chrono::steady_clock::time_point last_build;
  bool reset = true;

  Params params() const
  {
    return Params(flatbuffers::GetRoot<protocol::Subscribe>(request.data())->params());
  }
};

struct SubscribeMessage {
  uint32_t subscription;
  std::vector<uint8_t> request;
};
struct UnsubscribeMessage {
  uint32_t subscription;
};
struct CommandsMessage {
  std::vector<uint8_t> commands;
};
using Message = std::variant<SubscribeMessage, UnsubscribeMessage, CommandsMessage>;

GHOST_MessageQueue<Message> inbox;
GHOST_MessageQueue<flatbuffers::DetachedBuffer> outbox;
std::atomic<uint32_t> last_subscription{0};

/** Only touched on Blender's loop. */
Map<uint32_t, Subscription> &subscriptions()
{
  static Map<uint32_t, Subscription> subscriptions;
  return subscriptions;
}

/** Whether a subscription waits to be built, which notifiers and commands mark. */
bool any_dirty = false;

bool subscriptions_dirty()
{
  return any_dirty;
}

}  // namespace

/** \} */

/* -------------------------------------------------------------------- */
/** \name Commands
 * \{ */

/** Set a property to the value of a command or a parameter, as the property's type takes it. */
template<typename Holder>
static bool property_set(bContext *C,
                         PointerRNA &ptr,
                         PropertyRNA *prop,
                         const int index,
                         const Holder &command,
                         std::string &r_error)
{
  const auto number = [&]() -> std::optional<double> {
    if (const protocol::FloatValue *value = command.value_as_FloatValue()) {
      return value->value();
    }
    if (const protocol::IntValue *value = command.value_as_IntValue()) {
      return double(value->value());
    }
    if (const protocol::BoolValue *value = command.value_as_BoolValue()) {
      return value->value() ? 1.0 : 0.0;
    }
    return std::nullopt;
  };
  const bool array = RNA_property_array_check(prop) && index == -1;

  switch (RNA_property_type(prop)) {
    case PROP_BOOLEAN:
    case PROP_INT:
    case PROP_FLOAT: {
      if (array) {
        const protocol::FloatsValue *values = command.value_as_FloatsValue();
        const int length = RNA_property_array_length(&ptr, prop);
        if (values == nullptr || values->value() == nullptr || int(values->value()->size()) != length)
        {
          r_error = "Expected a value for each component";
          return false;
        }
        for (int i = 0; i < length; i++) {
          const double value = values->value()->Get(i);
          switch (RNA_property_type(prop)) {
            case PROP_BOOLEAN:
              RNA_property_boolean_set_index(&ptr, prop, i, value != 0.0);
              break;
            case PROP_INT:
              RNA_property_int_set_index(&ptr, prop, i, int(value));
              break;
            default:
              RNA_property_float_set_index(&ptr, prop, i, float(value));
              break;
          }
        }
        return true;
      }
      const std::optional<double> value = number();
      if (!value) {
        r_error = "Expected a number";
        return false;
      }
      const bool indexed = RNA_property_array_check(prop);
      switch (RNA_property_type(prop)) {
        case PROP_BOOLEAN:
          indexed ? RNA_property_boolean_set_index(&ptr, prop, index, *value != 0.0) :
                    RNA_property_boolean_set(&ptr, prop, *value != 0.0);
          break;
        case PROP_INT:
          indexed ? RNA_property_int_set_index(&ptr, prop, index, int(*value)) :
                    RNA_property_int_set(&ptr, prop, int(*value));
          break;
        default:
          indexed ? RNA_property_float_set_index(&ptr, prop, index, float(*value)) :
                    RNA_property_float_set(&ptr, prop, float(*value));
          break;
      }
      return true;
    }
    case PROP_STRING: {
      const protocol::TextValue *value = command.value_as_TextValue();
      if (value == nullptr) {
        r_error = "Expected text";
        return false;
      }
      RNA_property_string_set(&ptr, prop, value->value() ? value->value()->c_str() : "");
      return true;
    }
    case PROP_ENUM: {
      const protocol::TextValue *value = command.value_as_TextValue();
      if (value == nullptr || value->value() == nullptr) {
        r_error = "Expected an option";
        return false;
      }
      int result = 0;
      if (RNA_property_flag(prop) & PROP_ENUM_FLAG) {
        /* Several options, separated by commas. */
        std::string_view rest = value->value()->string_view();
        while (!rest.empty()) {
          const size_t comma = rest.find(',');
          const std::string identifier(rest.substr(0, comma));
          int bit = 0;
          if (!RNA_property_enum_value(C, &ptr, prop, identifier.c_str(), &bit)) {
            r_error = "No option " + identifier;
            return false;
          }
          result |= bit;
          rest = comma == std::string_view::npos ? std::string_view() : rest.substr(comma + 1);
        }
      }
      else if (!RNA_property_enum_value(C, &ptr, prop, value->value()->c_str(), &result)) {
        r_error = "No option " + value->value()->str();
        return false;
      }
      RNA_property_enum_set(&ptr, prop, result);
      return true;
    }
    default:
      r_error = "This kind of property cannot be set yet";
      return false;
  }
}

/** A command aimed at a node keyed by a property's data path, see `WM_native_ui_views.hh`. */
static bool property_command(bContext *C, const protocol::Command &command, std::string &r_error)
{
  PointerRNA main_ptr = RNA_main_pointer_create(CTX_data_main(C));
  PointerRNA ptr;
  PropertyRNA *prop = nullptr;
  int index = -1;
  if (!RNA_path_resolve_full(&main_ptr, command.target()->c_str(), &ptr, &prop, &index) ||
      prop == nullptr)
  {
    r_error = "Nothing to do for " + command.target()->str();
    return false;
  }
  if (!RNA_property_editable(&ptr, prop)) {
    r_error = "It cannot be edited";
    return false;
  }
  if (command.op() != protocol::Op::Set) {
    r_error = "Not supported yet";
    return false;
  }
  if (!property_set(C, ptr, prop, index, command, r_error)) {
    return false;
  }
  RNA_property_update(C, &ptr, prop);
  /* A drag is one step to undo, pushed as it ends. */
  if (ELEM(command.phase(), protocol::Phase::Once, protocol::Phase::End)) {
    ED_undo_push(C, RNA_property_ui_name(prop));
  }
  return true;
}

/** Commands that wait for a stroke or other modal operator to end, in the order they came. */
struct WaitingCommand {
  std::shared_ptr<std::vector<uint8_t>> bytes;
  const protocol::Command *command;
};
static std::deque<WaitingCommand> waiting;

static bool command_live(const Subscription *subscription, const protocol::Command &command)
{
  if (subscription && subscription->type->live) {
    return subscription->type->live(command);
  }
  return ELEM(command.op(), protocol::Op::Set, protocol::Op::Open, protocol::Op::Close);
}

/** Answers to commands, sent with the views showing what they did. */
static std::vector<std::pair<uint32_t, std::string>> answers;

void view_type_dirty(const std::string_view name)
{
  for (Subscription &subscription : subscriptions().values()) {
    if (subscription.type->name == name) {
      subscription.dirty = true;
      any_dirty = true;
    }
  }
}

static void command_execute(bContext *C, const protocol::Command &command)
{
  CLOG_DEBUG(&LOG,
             "Command %u to %s: %s %s",
             command.id(),
             command.target()->c_str(),
             protocol::EnumNameOp(command.op()),
             protocol::EnumNamePhase(command.phase()));
  std::string error;
  Subscription *subscription = subscriptions().lookup_ptr(command.subscription());
  if (subscription == nullptr) {
    error = "No such view";
  }
#if defined(WITH_APPLE_CROSSPLATFORM) && APPLE_TARGET_IOS
  else if (WM_apple_ios_dialog_active(CTX_wm_window(C)) &&
           !ELEM(command.op(), protocol::Op::Open, protocol::Op::Close))
  {
    error = "Finish the current dialog first";
  }
#endif
  else {
    if (command.op() != protocol::Op::Set) {
      /* A drag of a value in Properties ends with anything else. */
      ui::native_properties_interaction_finish(C);
    }
    /* Undo steps it pushes while an operator runs wait for the operator to end. */
    bridge_dispatching = true;
    CommandResult result = CommandResult::NotHandled;
    if (subscription->type->command) {
      result = subscription->type->command(
          C, subscription->params(), subscription->data.get(), command, error);
    }
    if (result == CommandResult::NotHandled) {
      property_command(C, command, error);
    }
    bridge_dispatching = false;
    /* Shown again with what the command did: at once, but for a drag's updates, which the
     * interface shows itself, and which then show at the view's pace. */
    subscription->dirty = true;
    if (!ELEM(command.phase(), protocol::Phase::Begin, protocol::Phase::Update)) {
      subscription->urgent = true;
    }
    any_dirty = true;
  }
  if (!error.empty()) {
    CLOG_DEBUG(&LOG, "Command %u failed: %s", command.id(), error.c_str());
  }
  if (command.id() != 0) {
    answers.emplace_back(command.id(), std::move(error));
  }
}

/**
 * Run commands, those waiting first. While a stroke or another modal operator runs, one hand can
 * keep changing things with the other: values change at once, but what would change data under
 * the operator waits for it to end, see #ViewType::live.
 */
static bool commands_execute(bContext *C, std::vector<std::vector<uint8_t>> received)
{
  bool executed = false;
  std::deque<WaitingCommand> commands = std::move(waiting);
  waiting.clear();
  for (std::vector<uint8_t> &bytes : received) {
    auto shared = std::make_shared<std::vector<uint8_t>>(std::move(bytes));
    const auto *list = flatbuffers::GetRoot<protocol::Commands>(shared->data())->commands();
    if (list) {
      for (const protocol::Command *command : *list) {
        commands.push_back({shared, command});
      }
    }
  }
  for (WaitingCommand &item : commands) {
    const bool running = WM_native_ui_engine_busy(C);
    if (!running) {
      bridge_undo_push_pending(C);
    }
    const Subscription *subscription = subscriptions().lookup_ptr(item.command->subscription());
    if ((running || !waiting.empty()) && !command_live(subscription, *item.command)) {
      waiting.push_back(std::move(item));
      continue;
    }
    command_execute(C, *item.command);
    executed = true;
  }
  if (!WM_native_ui_engine_busy(C)) {
    bridge_undo_push_pending(C);
  }
  return executed;
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Records
 * \{ */

using io::serialize::ArrayValue;
using io::serialize::DictionaryValue;
using io::serialize::eValueType;

/** A value written as a parameter, or null for one that needs nodes of its own. */
static std::optional<std::pair<protocol::Value, flatbuffers::Offset<void>>> record_value(
    flatbuffers::FlatBufferBuilder &buffer, const io::serialize::Value &value)
{
  switch (value.type()) {
    case eValueType::String:
      return std::pair{protocol::Value::TextValue,
                       protocol::CreateTextValue(
                           buffer, buffer.CreateString(value.as_string_value()->value()))
                           .Union()};
    case eValueType::Int:
      return std::pair{protocol::Value::IntValue,
                       protocol::CreateIntValue(buffer, value.as_int_value()->value()).Union()};
    case eValueType::Double:
      return std::pair{protocol::Value::FloatValue,
                       protocol::CreateFloatValue(buffer, value.as_double_value()->value()).Union()};
    case eValueType::Boolean:
      return std::pair{protocol::Value::BoolValue,
                       protocol::CreateBoolValue(buffer, value.as_boolean_value()->value()).Union()};
    case eValueType::Array: {
      const Span<std::shared_ptr<io::serialize::Value>> items =
          value.as_array_value()->elements();
      const auto all = [&](auto test) {
        return std::all_of(items.begin(), items.end(), [&](const auto &item) { return test(*item); });
      };
      if (all([](const io::serialize::Value &item) { return item.type() == eValueType::Int; })) {
        std::vector<int64_t> ints;
        for (const auto &item : items) {
          ints.push_back(item->as_int_value()->value());
        }
        return std::pair{protocol::Value::IntsValue,
                         protocol::CreateIntsValue(buffer, buffer.CreateVector(ints)).Union()};
      }
      if (all([](const io::serialize::Value &item) {
            return ELEM(item.type(), eValueType::Int, eValueType::Double);
          }))
      {
        std::vector<double> doubles;
        for (const auto &item : items) {
          doubles.push_back(item->type() == eValueType::Int ? double(item->as_int_value()->value()) :
                                                              item->as_double_value()->value());
        }
        return std::pair{protocol::Value::FloatsValue,
                         protocol::CreateFloatsValue(buffer, buffer.CreateVector(doubles)).Union()};
      }
      if (all([](const io::serialize::Value &item) { return item.type() == eValueType::String; })) {
        std::vector<flatbuffers::Offset<flatbuffers::String>> texts;
        for (const auto &item : items) {
          texts.push_back(buffer.CreateString(item->as_string_value()->value()));
        }
        return std::pair{protocol::Value::TextsValue,
                         protocol::CreateTextsValue(buffer, buffer.CreateVector(texts)).Union()};
      }
      return std::nullopt;
    }
    default:
      return std::nullopt;
  }
}

/** Whether a value is written as a parameter, see #record_value. */
static bool record_value_fits(const io::serialize::Value &value)
{
  if (value.type() != eValueType::Array) {
    return ELEM(value.type(), eValueType::String, eValueType::Int, eValueType::Double, eValueType::Boolean);
  }
  const Span<std::shared_ptr<io::serialize::Value>> items = value.as_array_value()->elements();
  const bool numbers = std::all_of(items.begin(), items.end(), [](const auto &item) {
    return ELEM(item->type(), eValueType::Int, eValueType::Double);
  });
  const bool texts = std::all_of(items.begin(), items.end(), [](const auto &item) {
    return item->type() == eValueType::String;
  });
  return numbers || texts;
}

/** The key an item of a list keeps as others come and go. */
static std::string record_item_key(const io::serialize::Value &item, const int index)
{
  if (const DictionaryValue *dictionary = item.as_dictionary_value()) {
    for (const char *name : {"key", "id"}) {
      if (const std::shared_ptr<io::serialize::Value> *found = dictionary->lookup(name)) {
        if (const io::serialize::StringValue *text = (*found)->as_string_value()) {
          return text->value();
        }
        if (const io::serialize::IntValue *number = (*found)->as_int_value()) {
          return std::to_string(number->value());
        }
      }
    }
  }
  return "#" + std::to_string(index);
}

static void record_child(ViewBuilder &builder,
                         NodeId parent,
                         const std::string &key,
                         std::string_view name,
                         const io::serialize::Value &value);

/** A record labelled with its \a name in the record it is a value of. */
static NodeId record_add(ViewBuilder &builder,
                         const std::optional<NodeId> parent,
                         const std::string &key,
                         const std::string_view name,
                         const DictionaryValue &value)
{
  std::vector<const DictionaryValue::Item *> children;
  const auto write = [&](flatbuffers::FlatBufferBuilder &buffer, NodeFields &fields) {
    fields.label = name;
    std::vector<flatbuffers::Offset<protocol::Param>> params;
    for (const DictionaryValue::Item &item : value.elements()) {
      if (item.second->type() == eValueType::Null) {
        continue;
      }
      if (const auto written = record_value(buffer, *item.second)) {
        params.push_back(protocol::CreateParam(
            buffer, buffer.CreateString(item.first), written->first, written->second));
      }
      else {
        children.push_back(&item);
      }
    }
    return protocol::CreateRecord(buffer, buffer.CreateVector(params));
  };
  const NodeId node = parent ? builder.add(*parent, key, write) : builder.top(key, write);
  for (const DictionaryValue::Item *item : children) {
    record_child(builder, node, key + "/" + item->first, item->first, *item->second);
  }
  return node;
}

NodeId records_add(ViewBuilder &builder,
                   const std::optional<NodeId> parent,
                   const std::string &key,
                   const DictionaryValue &value)
{
  return record_add(builder, parent, key, "", value);
}

/** A value that is a dictionary or a list of more than numbers or texts, see #records_add. */
static void record_child(ViewBuilder &builder,
                         const NodeId parent,
                         const std::string &key,
                         const std::string_view name,
                         const io::serialize::Value &value)
{
  if (const DictionaryValue *dictionary = value.as_dictionary_value()) {
    record_add(builder, parent, key, name, *dictionary);
    return;
  }
  const ArrayValue *array = value.as_array_value();
  const NodeId group = builder.add(parent, key, [&](flatbuffers::FlatBufferBuilder &buffer, NodeFields &fields) {
    fields.label = name;
    return protocol::CreateGroup(buffer);
  });
  if (array == nullptr) {
    return;
  }
  int index = 0;
  for (const std::shared_ptr<io::serialize::Value> &item : array->elements()) {
    const std::string item_key = key + "/" + record_item_key(*item, index++);
    if (const DictionaryValue *dictionary = item->as_dictionary_value()) {
      record_add(builder, group, item_key, "", *dictionary);
    }
    else if (item->type() == eValueType::Array && !record_value_fits(*item)) {
      record_child(builder, group, item_key, "", *item);
    }
    else {
      /* A value of its own: a number, a text, a list of them, or none. */
      builder.add(group, item_key, [&](flatbuffers::FlatBufferBuilder &buffer, NodeFields &) {
        const auto written = item->type() == eValueType::Null ? std::nullopt :
                                                                 record_value(buffer, *item);
        return written ? protocol::CreateData(buffer, written->first, written->second) :
                         protocol::CreateData(buffer);
      });
    }
  }
}

/** The dictionary in \a dictionary named \a name, added if there is none. */
static DictionaryValue &dictionary_ensure(DictionaryValue &dictionary, const std::string &name)
{
  for (const DictionaryValue::Item &item : dictionary.elements()) {
    if (item.first == name && item.second->as_dictionary_value()) {
      return *const_cast<DictionaryValue *>(item.second->as_dictionary_value());
    }
  }
  return *dictionary.append_dict(name);
}

std::unique_ptr<DictionaryValue> params_dictionary(
    const flatbuffers::Vector<flatbuffers::Offset<protocol::Param>> *params)
{
  auto root = std::make_unique<DictionaryValue>();
  if (params == nullptr) {
    return root;
  }
  for (const protocol::Param *param : *params) {
    /* A value of a dictionary in it, as `properties.type`. */
    std::string key = param->key()->str();
    DictionaryValue *result = root.get();
    for (size_t dot = key.find('.'); dot != std::string::npos; dot = key.find('.')) {
      result = &dictionary_ensure(*result, key.substr(0, dot));
      key = key.substr(dot + 1);
    }
    switch (param->value_type()) {
      case protocol::Value::BoolValue:
        result->append(key,
                       std::make_shared<io::serialize::BooleanValue>(param->value_as_BoolValue()->value()));
        break;
      case protocol::Value::IntValue:
        result->append_int(key, param->value_as_IntValue()->value());
        break;
      case protocol::Value::FloatValue:
        result->append_double(key, param->value_as_FloatValue()->value());
        break;
      case protocol::Value::TextValue: {
        const flatbuffers::String *text = param->value_as_TextValue()->value();
        result->append_str(key, text ? text->str() : "");
        break;
      }
      case protocol::Value::FloatsValue: {
        auto array = result->append_array(key);
        if (const auto *values = param->value_as_FloatsValue()->value()) {
          for (const double value : *values) {
            array->append_double(value);
          }
        }
        break;
      }
      case protocol::Value::IntsValue: {
        auto array = result->append_array(key);
        if (const auto *values = param->value_as_IntsValue()->value()) {
          for (const int64_t value : *values) {
            array->append_int(value);
          }
        }
        break;
      }
      case protocol::Value::TextsValue: {
        auto array = result->append_array(key);
        if (const auto *values = param->value_as_TextsValue()->value()) {
          for (const flatbuffers::String *value : *values) {
            array->append_str(value->str());
          }
        }
        break;
      }
      default:
        break;
    }
  }
  return root;
}

/** \} */

/* -------------------------------------------------------------------- */
/** \name Operators
 *
 * The `operators` view, which shows nothing: `Invoke` runs the operator its target names, with
 * the command's parameters as its properties, see #operator_run.
 * \{ */

/** Operators that animate the view when invoked, and change nothing an operator holds. */
static bool operator_navigates(const std::string_view idname)
{
  return ELEM(idname,
              "VIEW3D_OT_view_selected",
              "VIEW3D_OT_view_all",
              "VIEW3D_OT_view_camera",
              "VIEW3D_OT_view_persportho",
              "VIEW3D_OT_view_axis",
              "VIEW3D_OT_view_orbit",
              "VIEW3D_OT_view_roll");
}

static std::string operator_idname(const std::string_view name)
{
  char idname[OP_MAX_TYPENAME];
  WM_operator_bl_idname(idname, std::string(name).c_str());
  return idname;
}

bool operator_run(bContext *C,
                  const std::string_view name,
                  const flatbuffers::Vector<flatbuffers::Offset<protocol::Param>> *params,
                  std::string &r_error)
{
  const std::string idname = operator_idname(name);
  wmOperatorType *ot = WM_operatortype_find(idname.c_str(), true);
  if (ot == nullptr) {
    r_error = "No operator " + std::string(name);
    return false;
  }
  if (!WM_operator_poll(C, ot)) {
    r_error = "It cannot run here";
    return false;
  }
  PointerRNA ptr = WM_operator_properties_create_ptr(ot);
  bool valid = true;
  if (params) {
    for (const protocol::Param *param : *params) {
      PropertyRNA *prop = RNA_struct_find_property(&ptr, param->key()->c_str());
      if (prop == nullptr) {
        r_error = "No property " + param->key()->str();
        valid = false;
        break;
      }
      if (!property_set(C, ptr, prop, -1, *param, r_error)) {
        valid = false;
        break;
      }
    }
  }
  if (valid) {
    /* Navigation is invoked, so it animates; anything else runs as a button runs it. Why it
     * failed, as it reports it, answers the command. */
    ReportList *reports = CTX_wm_reports(C);
    const Report *before = reports ? BKE_reports_last_displayable(reports) : nullptr;
    WM_operator_name_call_ptr(C,
                              ot,
                              operator_navigates(idname) ? OpCallContext::InvokeRegionWin :
                                                           OpCallContext::ExecRegionWin,
                              &ptr,
                              nullptr);
    const Report *report = reports ? BKE_reports_last_displayable(reports) : nullptr;
    if (report && report != before && report->type >= RPT_ERROR) {
      r_error = report->message;
      valid = false;
    }
  }
  WM_operator_properties_free(&ptr);
  return valid;
}

static void operators_build(bContext * /*C*/,
                            const Params & /*params*/,
                            ViewData * /*data*/,
                            ViewBuilder &builder)
{
  builder.top("operators", [](auto &buffer, NodeFields & /*fields*/) {
    return protocol::CreateGroup(buffer);
  });
}

static CommandResult operators_command(bContext *C,
                                       const Params & /*params*/,
                                       ViewData * /*data*/,
                                       const protocol::Command &command,
                                       std::string &r_error)
{
  if (command.op() != protocol::Op::Invoke) {
    r_error = "Operators are only run";
    return CommandResult::Failed;
  }
  return operator_run(C, command.target()->string_view(), command.params(), r_error) ?
             CommandResult::Done :
             CommandResult::Failed;
}

static Map<std::string, ViewType> builtin_view_types()
{
  Map<std::string, ViewType> types;
  ViewType operators;
  operators.name = "operators";
  operators.timing_name = "view.operators";
  /* It shows nothing, which nothing changes. */
  operators.notifiers = {0};
  operators.build = operators_build;
  operators.command = operators_command;
  operators.live = [](const protocol::Command &command) {
    return operator_navigates(operator_idname(command.target()->string_view()));
  };
  types.add("operators", std::move(operators));
  return types;
}

/** \} */

}  // namespace blender::wm::native_ui

/* -------------------------------------------------------------------- */
/** \name Blender's Loop
 * \{ */

namespace blender {

using namespace wm::native_ui;

void WM_native_ui_views_notify(const wmNotifier &note)
{
  for (Subscription &subscription : subscriptions().values()) {
    const ViewType &type = *subscription.type;
    if ((type.notifiers.is_empty() || type.notifiers.contains(note.category)) &&
        (type.wants == nullptr || type.wants(note)))
    {
      subscription.dirty = true;
      any_dirty = true;
    }
  }
}

double WM_native_ui_views_idle_seconds()
{
  if (!answers.empty()) {
    return 0.0;
  }
  if (!any_dirty) {
    return std::numeric_limits<double>::infinity();
  }
  /* The soonest a view waiting for its interval may be built. */
  const auto now = std::chrono::steady_clock::now();
  double soonest = std::numeric_limits<double>::infinity();
  for (const Subscription &subscription : subscriptions().values()) {
    if (subscription.urgent || subscription.reset) {
      return 0.0;
    }
    if (subscription.dirty) {
      const auto due = subscription.last_build +
                       std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                           std::chrono::duration<double>(subscription.type->min_interval));
      soonest = std::min(soonest, std::max(0.0, std::chrono::duration<double>(due - now).count()));
    }
  }
  return soonest;
}

void WM_native_ui_views_flush(bContext *C)
{
  /* Nothing to do, as long as no interface shows a view and none sent anything: the only cost on
   * a platform without an interface, or between changes. */
  std::vector<Message> messages = inbox.take();
  if (messages.empty() && !subscriptions_dirty() && waiting.empty()) {
    return;
  }
  BridgeTimer timer("views");
  std::vector<std::vector<uint8_t>> received;
  for (Message &message : messages) {
    if (auto *subscribe = std::get_if<SubscribeMessage>(&message)) {
      const auto *request = flatbuffers::GetRoot<protocol::Subscribe>(subscribe->request.data());
      const ViewType *type = view_types().lookup_ptr(request->view()->str());
      if (type == nullptr) {
        continue;
      }
      Subscription subscription;
      subscription.type = type;
      if (type->create) {
        subscription.data = type->create();
      }
      subscription.request = std::move(subscribe->request);
      subscriptions().add_overwrite(subscribe->subscription, std::move(subscription));
      any_dirty = true;
    }
    else if (auto *unsubscribe = std::get_if<UnsubscribeMessage>(&message)) {
      subscriptions().remove(unsubscribe->subscription);
    }
    else if (auto *commands = std::get_if<CommandsMessage>(&message)) {
      received.push_back(std::move(commands->commands));
    }
  }
  /* Views show what commands did once Blender handled it, as the notifiers they sent, on the
   * next pass; but at least every other pass, so a drag's stream of commands does not hold them
   * back. */
  static bool deferred = false;
  if ((!received.empty() || !waiting.empty()) && commands_execute(C, std::move(received)) &&
      !deferred)
  {
    deferred = true;
    any_dirty = true;
    return;
  }
  deferred = false;

  any_dirty = false;
  flatbuffers::FlatBufferBuilder buffer;
  const auto now = std::chrono::steady_clock::now();
  std::vector<flatbuffers::Offset<protocol::Update>> updates;
  for (const auto item : subscriptions().items()) {
    Subscription &subscription = item.value;
    if (!subscription.dirty && !subscription.reset) {
      continue;
    }
    if (!subscription.reset && !subscription.urgent &&
        now - subscription.last_build <
            std::chrono::duration<double>(subscription.type->min_interval))
    {
      /* Later, still dirty. */
      any_dirty = true;
      continue;
    }
    subscription.last_build = now;
    subscription.urgent = false;
    /* Before it is built, which may ask to be built again soon. */
    subscription.dirty = false;
    BridgeTimer view_timer(subscription.type->timing_name.c_str());
    ViewBuilder builder(subscription.state, subscription.reset);
    subscription.type->build(C, subscription.params(), subscription.data.get(), builder);
    const auto update = builder.finish(buffer, item.key);
    if (!update.IsNull()) {
      updates.push_back(update);
    }
    subscription.reset = false;
  }

  std::vector<flatbuffers::Offset<protocol::Ack>> acks;
  for (const auto &[id, error] : answers) {
    acks.push_back(protocol::CreateAck(buffer, id, error.empty() ? 0 : buffer.CreateString(error)));
  }
  answers.clear();
  if (updates.empty() && acks.empty()) {
    return;
  }
  buffer.Finish(
      protocol::CreateUpdates(buffer, buffer.CreateVector(updates), buffer.CreateVector(acks)));
  outbox.push(buffer.Release());
}

}  // namespace blender

/** \} */

/* -------------------------------------------------------------------- */
/** \name The Interface's Thread
 * \{ */

using namespace blender::wm::native_ui;

/** A buffer of updates taken by the interface, until it frees it. */
struct WMNativeUIBuffer {
  flatbuffers::DetachedBuffer buffer;
};

/** Verify what the interface sent, so a bad buffer is dropped rather than read out of bounds. */
template<typename Table> static bool verified(const uint8_t *data, const size_t size)
{
  flatbuffers::Verifier verifier(data, size);
  return data != nullptr && verifier.VerifyBuffer<Table>(nullptr);
}

uint32_t WM_native_ui_subscribe(const uint8_t *request, const size_t size)
{
  if (!verified<protocol::Subscribe>(request, size)) {
    return 0;
  }
  const uint32_t subscription = ++last_subscription;
  inbox.push(SubscribeMessage{subscription, std::vector<uint8_t>(request, request + size)});
  return subscription;
}

void WM_native_ui_unsubscribe(const uint32_t subscription)
{
  inbox.push(UnsubscribeMessage{subscription});
}

void WM_native_ui_send(const uint8_t *commands, const size_t size)
{
  if (verified<protocol::Commands>(commands, size)) {
    inbox.push(CommandsMessage{std::vector<uint8_t>(commands, commands + size)});
  }
}

WMNativeUIBuffer *WM_native_ui_take_updates()
{
  /* Updates are applied in order: what one batch leaves out the next one builds on. Only the
   * interface's thread takes them. */
  static std::deque<flatbuffers::DetachedBuffer> waiting;
  for (flatbuffers::DetachedBuffer &buffer : outbox.take()) {
    waiting.push_back(std::move(buffer));
  }
  if (waiting.empty()) {
    return nullptr;
  }
  WMNativeUIBuffer *result = new WMNativeUIBuffer{std::move(waiting.front())};
  waiting.pop_front();
  return result;
}

const uint8_t *WM_native_ui_buffer_data(const WMNativeUIBuffer *buffer, size_t *r_size)
{
  *r_size = buffer->buffer.size();
  return buffer->buffer.data();
}

void WM_native_ui_buffer_free(WMNativeUIBuffer *buffer)
{
  delete buffer;
}

/** \} */
