/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 */

#include "view_tree.hh"

namespace blender::wm::native_ui {

protocol::NodeT *ViewBuilder::find(const std::string &key)
{
  const auto found = tree_.nodes.find(key);
  return found == tree_.nodes.end() ? nullptr : found->second.get();
}

std::unique_ptr<protocol::UpdateT> view_update(ViewTree &sent, ViewTree next, const bool reset)
{
  auto update = std::make_unique<protocol::UpdateT>();
  update->reset = reset;
  if (reset || next.top != sent.top) {
    update->reset = true;
    update->top = next.top;
  }
  for (const auto &[key, node] : next.nodes) {
    if (!update->reset) {
      const auto previous = sent.nodes.find(key);
      if (previous != sent.nodes.end() && *previous->second == *node) {
        continue;
      }
    }
    update->nodes.push_back(std::make_unique<protocol::NodeT>(*node));
  }
  if (!update->reset) {
    for (const auto &[key, node] : sent.nodes) {
      if (!next.nodes.contains(key)) {
        update->removed.push_back(key);
      }
    }
  }
  sent = std::move(next);
  if (!update->reset && update->nodes.empty() && update->removed.empty()) {
    return nullptr;
  }
  return update;
}

}  // namespace blender::wm::native_ui
