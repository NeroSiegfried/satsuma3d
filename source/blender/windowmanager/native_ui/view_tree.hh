/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * Views as trees of nodes with stable keys, see `protocol.fbs`, and the updates that bring an
 * interface's copy of one up to date. Plain C++, so it can be tested on its own, see
 * `tests/view_tree_test.cc`.
 *
 * Each node is written straight into a buffer of its own and hashed. Only nodes whose bytes
 * changed since the interface was last sent them are copied into the update; a view keeps no more
 * than a hash of each node between builds. Children are compared apart from their parents, so a
 * row added to a list resends the list's children, not its rows.
 */

#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <type_traits>
#include <unordered_map>
#include <vector>

#include "protocol_generated.h"

namespace blender::wm::native_ui {

namespace protocol = ::Blender::NativeUI;

using NodeId = uint32_t;

/** The table a `flatbuffers::Offset` points to. */
template<typename Offset> struct OffsetTarget;
template<typename T> struct OffsetTarget<flatbuffers::Offset<T>> {
  using type = T;
};

/** What every node has besides its content, see `protocol::Node`. Only read while it is added. */
struct NodeFields {
  std::string_view label;
  std::string_view icon;
  std::string_view description;
  std::string_view property;
  std::string_view short_label;
  std::string_view leading_icon;
  bool enabled = true;
  bool mixed = false;
  bool animatable = false;
  protocol::Animation animation = protocol::Animation::None;
  protocol::Role role = protocol::Role::None;
};

/** A view as an interface has it, as far as updates need: a hash of each node it was sent. */
class ViewState {
  friend class ViewBuilder;

  struct StringHash {
    using is_transparent = void;
    size_t operator()(std::string_view text) const
    {
      return std::hash<std::string_view>{}(text);
    }
  };
  struct Sent {
    uint64_t node = 0;
    /** Of its children's keys, or 0 without children. */
    uint64_t children = 0;
    /** The build that last had it. */
    uint32_t build = 0;
  };
  std::unordered_map<std::string, Sent, StringHash, std::equal_to<>> sent_;
  std::string top_;
  uint32_t build_ = 0;
  uint32_t version_ = 0;

 public:
  /** The version of the last update, see `protocol::Update::version`. */
  uint32_t version() const
  {
    return version_;
  }
};

/**
 * Builds a view, from its top node down, and the update it makes to \a state.
 *
 *   ViewBuilder builder(state, false);
 *   const NodeId panel = builder.top("object", [](auto &buffer, NodeFields &fields) {
 *     fields.label = "Object";
 *     return protocol::CreatePanel(buffer);
 *   });
 *   builder.add(panel, "location_x", [&](auto &buffer, NodeFields &fields) {
 *     fields.label = "X";
 *     return protocol::CreateNumber(buffer, location[0]);
 *   });
 *   const auto update = builder.finish(updates, subscription);
 *
 * A node's content is written with the buffer passed to it, before its fields are read.
 */
class ViewBuilder {
  ViewState &state_;
  bool reset_;
  flatbuffers::FlatBufferBuilder node_buffer_;

  struct Built {
    uint32_t key_start;
    uint32_t key_size;
    NodeId parent;
  };
  /** Every node's key, back to back, and where each is. */
  std::string keys_;
  std::vector<Built> nodes_;
  /** Changed nodes' buffers, back to back, and where each starts. */
  std::vector<uint8_t> changed_;
  std::vector<size_t> changed_starts_;

  static constexpr NodeId no_parent = UINT32_MAX;
  NodeId top_ = no_parent;

 public:
  /** With \a reset, the whole view is sent, as to an interface that has none of it. */
  ViewBuilder(ViewState &state, bool reset);

  template<typename Write> NodeId top(std::string_view key, Write write)
  {
    top_ = add_node(no_parent, key, write);
    return top_;
  }

  /** A child of \a parent, after its other children. Keys must be unique within the view. */
  template<typename Write> NodeId add(NodeId parent, std::string_view key, Write write)
  {
    return add_node(parent, key, write);
  }

  /**
   * The update to send, written into \a buffer, which may hold other views' updates too. Null
   * (an offset of 0) when nothing changed.
   */
  flatbuffers::Offset<protocol::Update> finish(flatbuffers::FlatBufferBuilder &buffer,
                                               uint32_t subscription);

 private:
  template<typename Write> NodeId add_node(NodeId parent, std::string_view key, Write write)
  {
    node_buffer_.Clear();
    NodeFields fields;
    const auto content = write(node_buffer_, fields);
    using ContentType = typename OffsetTarget<std::decay_t<decltype(content)>>::type;
    finish_node(parent,
                key,
                fields,
                protocol::ContentTraits<ContentType>::enum_value,
                content.Union());
    return NodeId(nodes_.size() - 1);
  }

  void finish_node(NodeId parent,
                   std::string_view key,
                   const NodeFields &fields,
                   protocol::Content type,
                   flatbuffers::Offset<void> content);
  std::string_view key(const Built &node) const
  {
    return std::string_view(keys_).substr(node.key_start, node.key_size);
  }
};

}  // namespace blender::wm::native_ui
