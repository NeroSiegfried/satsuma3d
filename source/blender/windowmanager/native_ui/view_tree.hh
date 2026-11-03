/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * Views as trees of nodes with stable keys, see `protocol.fbs`: building one, and what changed
 * between two of them, as the update an interface applies. Plain C++, so it can be tested on its
 * own, see `tests/view_tree_test.cc`.
 */

#pragma once

#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>

#include "protocol_generated.h"

namespace blender::wm::native_ui {

namespace protocol = ::Blender::NativeUI;

/** A view's nodes by key, and its top node. */
struct ViewTree {
  std::unordered_map<std::string, std::unique_ptr<protocol::NodeT>> nodes;
  std::string top;
};

/**
 * Builds a view: its top node, then children added under nodes already added, in order.
 *
 *   ViewBuilder builder;
 *   protocol::NodeT &panel = builder.top("object", protocol::PanelT{});
 *   builder.add(panel, "object.location[0]", number).label = "X";
 */
class ViewBuilder {
  ViewTree tree_;

 public:
  template<typename Content> protocol::NodeT &top(std::string key, Content content)
  {
    tree_.top = key;
    return add_node(std::move(key), std::move(content));
  }

  /**
   * A child of \a parent, after its other children. Keys must be unique within the view: one
   * already added is replaced, keeping its place.
   */
  template<typename Content>
  protocol::NodeT &add(protocol::NodeT &parent, std::string key, Content content)
  {
    if (!tree_.nodes.contains(key)) {
      parent.children.push_back(key);
    }
    return add_node(std::move(key), std::move(content));
  }

  /** A child without content of its own, such as a label. */
  protocol::NodeT &add(protocol::NodeT &parent, std::string key)
  {
    return add(parent, std::move(key), protocol::LabelT{});
  }

  /** The node added with \a key, or null. */
  protocol::NodeT *find(const std::string &key);

  ViewTree finish()
  {
    return std::move(tree_);
  }

 private:
  template<typename Content> protocol::NodeT &add_node(std::string key, Content content)
  {
    auto node = std::make_unique<protocol::NodeT>();
    node->key = key;
    node->content.Set(std::move(content));
    protocol::NodeT &result = *node;
    tree_.nodes[std::move(key)] = std::move(node);
    return result;
  }
};

/**
 * What changed from \a sent, the view as the interface has it, to \a next: nodes new or changed
 * in any way, sent whole, and keys of nodes gone. Null when nothing changed. With \a reset, the
 * whole of \a next. Moves \a next into \a sent.
 */
std::unique_ptr<protocol::UpdateT> view_update(ViewTree &sent, ViewTree next, bool reset);

}  // namespace blender::wm::native_ui
