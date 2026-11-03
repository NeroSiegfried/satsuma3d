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

#include "BLI_vector.hh"

#include "view_tree.hh"

namespace blender {
struct bContext;
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
  /**
   * The least time between builds that notifiers ask for, in seconds, for a view costly to build
   * that changes often, such as during playback. Commands are shown at once all the same, except
   * the updates of a drag, which the interface shows itself.
   */
  double min_interval = 0.0;
  /** Data of its own for each subscription, see #ViewData, or none. */
  std::unique_ptr<ViewData> (*create)() = nullptr;
  void (*build)(bContext *C, const Params &params, ViewData *data, ViewBuilder &builder) = nullptr;
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

}  // namespace blender::wm::native_ui
