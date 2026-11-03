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

#include "BLI_map.hh"

#include "DNA_windowmanager_types.h"

#include "ED_undo.hh"

#include "GHOST_Mailbox.hh"

#include "RNA_access.hh"
#include "RNA_path.hh"
#include "RNA_prototypes.hh"

#include "WM_api.hh"
#include "WM_native_ui.h"
#include "WM_native_ui.hh"
#include "WM_native_ui_views.hh"
#include "WM_types.hh"

#include "wm_native_ui_timing.hh"

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

static Map<std::string, ViewType> &view_types()
{
  static Map<std::string, ViewType> types;
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

/** Set a property to a command's value, as the property's type takes it. */
static bool property_set(bContext *C,
                         PointerRNA &ptr,
                         PropertyRNA *prop,
                         const int index,
                         const protocol::Command &command,
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

static void commands_execute(bContext *C,
                             const std::vector<uint8_t> &bytes,
                             flatbuffers::FlatBufferBuilder &buffer,
                             std::vector<flatbuffers::Offset<protocol::Ack>> &acks)
{
  const auto *commands = flatbuffers::GetRoot<protocol::Commands>(bytes.data());
  if (commands->commands() == nullptr) {
    return;
  }
  for (const protocol::Command *command : *commands->commands()) {
    std::string error;
    Subscription *subscription = subscriptions().lookup_ptr(command->subscription());
    if (subscription == nullptr) {
      error = "No such view";
    }
    else {
      CommandResult result = CommandResult::NotHandled;
      if (subscription->type->command) {
        result = subscription->type->command(
            C, subscription->params(), subscription->data.get(), *command, error);
      }
      if (result == CommandResult::NotHandled) {
        property_command(C, *command, error);
      }
      /* Shown again with what the command did: at once, but for a drag's updates, which the
       * interface shows itself, and which then show at the view's pace. */
      subscription->dirty = true;
      if (!ELEM(command->phase(), protocol::Phase::Begin, protocol::Phase::Update)) {
        subscription->urgent = true;
      }
      any_dirty = true;
    }
    if (command->id() != 0) {
      acks.push_back(protocol::CreateAck(
          buffer, command->id(), error.empty() ? 0 : buffer.CreateString(error)));
    }
  }
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
    const Vector<uint32_t> &notifiers = subscription.type->notifiers;
    if (notifiers.is_empty() || notifiers.contains(note.category)) {
      subscription.dirty = true;
      any_dirty = true;
    }
  }
}

double WM_native_ui_views_idle_seconds()
{
  if (!any_dirty) {
    return std::numeric_limits<double>::infinity();
  }
  /* The soonest a view waiting for its interval may be built. */
  const auto now = std::chrono::steady_clock::now();
  double soonest = std::numeric_limits<double>::infinity();
  for (const Subscription &subscription : subscriptions().values()) {
    if (subscription.dirty || subscription.reset) {
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
  if (messages.empty() && !subscriptions_dirty()) {
    return;
  }
  BridgeTimer timer("views");
  flatbuffers::FlatBufferBuilder buffer;
  std::vector<flatbuffers::Offset<protocol::Ack>> acks;
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
      commands_execute(C, commands->commands, buffer, acks);
    }
  }

  any_dirty = false;
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
    BridgeTimer view_timer(subscription.type->timing_name.c_str());
    ViewBuilder builder(subscription.state, subscription.reset);
    subscription.type->build(C, subscription.params(), subscription.data.get(), builder);
    const auto update = builder.finish(buffer, item.key);
    if (!update.IsNull()) {
      updates.push_back(update);
    }
    subscription.dirty = false;
    subscription.reset = false;
  }

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
