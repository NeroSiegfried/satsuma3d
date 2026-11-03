/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * Views a platform's own interface shows, as Blender's code provides them, see `protocol.fbs` in
 * `native_ui/`. A view type builds its view from Blender's state whenever notifiers say that state
 * changed, and the bridge sends interfaces only what changed. Only built with `WITH_NATIVE_UI`.
 *
 * A control that edits a property is keyed by the property's data path from `bpy.data`, such as
 * `objects["Cube"].location[0]`: commands setting it, its keyframes included, are then carried out
 * by the bridge, with one undo step for a whole drag. A view type only handles commands for its
 * other nodes, such as buttons.
 */

#pragma once

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

#include "BLI_serialize.hh"
#include "BLI_vector.hh"

#include "view_tree.hh"

namespace blender {
struct bContext;
struct wmNotifier;
}

namespace blender::wm::native_ui {

/** A view's parameters, as the interface subscribed with them. */
class Params {
  const flatbuffers::Vector<flatbuffers::Offset<protocol::Param>> *params_;

 public:
  explicit Params(const flatbuffers::Vector<flatbuffers::Offset<protocol::Param>> *params)
      : params_(params)
  {
  }

  const protocol::Param *find(std::string_view key) const;
  std::optional<std::string_view> text(std::string_view key) const;
  std::optional<double> number(std::string_view key) const;
  bool flag(std::string_view key) const;
};

/**
 * What a view type keeps for each subscription between its builds and the commands that follow
 * them, such as what each of its nodes edits.
 */
class ViewData {
 public:
  virtual ~ViewData() = default;
};

/** The outcome of a command a view type handled. */
enum class CommandResult {
  /** Not one of its own: the bridge sets the property the node is keyed by. */
  NotHandled,
  Done,
  Failed,
};

struct ViewType {
  /** What interfaces subscribe to it by, such as `tool_settings`. */
  std::string name;
  /** Notifier categories (`NC_*`) that may change it; none to rebuild on any notifier. */
  Vector<uint32_t> notifiers;
  /** Of those, the notifiers that may change it, by what else they say, or all without this. */
  bool (*wants)(const wmNotifier &note) = nullptr;
  /**
   * The least time between builds that notifiers ask for, in seconds, for a view costly to build
   * that changes often, such as during playback. Commands are shown at once all the same, except
   * the updates of a drag, which the interface shows itself.
   */
  double min_interval = 0.0;
  /** Data of its own for each subscription, see #ViewData, or none. */
  std::unique_ptr<ViewData> (*create)() = nullptr;
  void (*build)(bContext *C, const Params &params, ViewData *data, ViewBuilder &builder) = nullptr;
  /**
   * Whether a command can be carried out while a stroke or other modal operator runs, rather than
   * waiting for it to end. Without this, only commands that set a value, or open or close
   * something, can: anything else may change data the operator holds.
   */
  bool (*live)(const protocol::Command &command) = nullptr;
  /** A command aimed at one of its nodes, see #CommandResult. */
  CommandResult (*command)(bContext *C,
                           const Params &params,
                           ViewData *data,
                           const protocol::Command &command,
                           std::string &r_error) = nullptr;

  /** What its builds are timed as, set when added. */
  std::string timing_name;
};

/** Make a view type available to interfaces, at startup. */
void view_type_add(ViewType type);
/** Build the views of a type again, for a change no notifier tells of. */
void view_type_dirty(std::string_view name);

/**
 * Write \a value, a dictionary as JSON describes it, as a canvas's records, see
 * `protocol::Record`: a record of its values keyed \a key, under \a parent, or as the view's top
 * node without one. A value that is a dictionary is a record of its own, and one that is a list of
 * anything but numbers or texts a group, each as a child labelled with the value's name; the items
 * of such a list are its children in turn, keyed by their own `key` or `id` where they have one,
 * as they then keep it when others come and go, or else by their place.
 */
NodeId records_add(ViewBuilder &builder,
                   std::optional<NodeId> parent,
                   const std::string &key,
                   const io::serialize::DictionaryValue &value);

/** A command's parameters as a dictionary, as the records of #records_add take them: a value of a
 * dictionary in it is named by both, as `properties.type`. */
std::unique_ptr<io::serialize::DictionaryValue> params_dictionary(
    const flatbuffers::Vector<flatbuffers::Offset<protocol::Param>> *params);

/**
 * Run an operator by its name, in Python's or C's form, with properties set from \a params,
 * whose values are given as the properties take them. Views of navigation run invoked, so they
 * animate; others are executed, as a button runs them. False with the reason when it cannot run.
 */
bool operator_run(bContext *C,
                  std::string_view name,
                  const flatbuffers::Vector<flatbuffers::Offset<protocol::Param>> *params,
                  std::string &r_error);

}  // namespace blender::wm::native_ui
