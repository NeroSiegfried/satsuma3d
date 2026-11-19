/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 */

#include "view_tree.hh"

#include "xxhash.h"

namespace blender::wm::native_ui {

ViewBuilder::ViewBuilder(ViewState &state, const bool reset) : state_(state), reset_(reset)
{
  state_.build_++;
}

void ViewBuilder::finish_node(const NodeId parent,
                              const std::string_view key,
                              const NodeFields &fields,
                              const protocol::Content type,
                              const flatbuffers::Offset<void> content)
{
  flatbuffers::FlatBufferBuilder &buffer = node_buffer_;
  const auto text = [&](const std::string_view value) {
    return value.empty() ? flatbuffers::Offset<flatbuffers::String>() :
                           buffer.CreateString(value.data(), value.size());
  };
  const auto key_offset = buffer.CreateString(key.data(), key.size());
  const auto label = text(fields.label);
  const auto icon = text(fields.icon);
  const auto description = text(fields.description);
  const auto property = text(fields.property);
  const auto short_label = text(fields.short_label);
  const auto leading_icon = text(fields.leading_icon);
  buffer.Finish(protocol::CreateNode(buffer,
                                     key_offset,
                                     type,
                                     content,
                                     label,
                                     icon,
                                     description,
                                     fields.enabled,
                                     fields.mixed,
                                     fields.animation,
                                     fields.animatable,
                                     property,
                                     fields.role,
                                     short_label,
                                     leading_icon));

  const uint8_t *bytes = buffer.GetBufferPointer();
  const size_t size = buffer.GetSize();
  const uint64_t hash = XXH3_64bits(bytes, size);
  auto sent = state_.sent_.find(key);
  if (sent == state_.sent_.end()) {
    /* The only allocation for a node, when it first shows. */
    sent = state_.sent_.emplace(std::string(key), ViewState::Sent{}).first;
  }
  sent->second.build = state_.build_;
  if (reset_ || sent->second.node != hash) {
    if (sent->second.node != hash) {
      /* The update this build makes, which carries it. */
      sent->second.changed = state_.version_ + 1;
    }
    sent->second.node = hash;
    changed_starts_.push_back(changed_.size());
    changed_.insert(changed_.end(), bytes, bytes + size);
  }

  nodes_.push_back({uint32_t(keys_.size()), uint32_t(key.size()), parent});
  keys_.append(key);
}

flatbuffers::Offset<protocol::Update> ViewBuilder::finish(flatbuffers::FlatBufferBuilder &buffer,
                                                          const uint32_t subscription)
{
  /* Each node's children, in order, as a list after its first child. */
  std::vector<NodeId> first_child(nodes_.size(), no_parent);
  std::vector<NodeId> last_child(nodes_.size(), no_parent);
  std::vector<NodeId> next_sibling(nodes_.size(), no_parent);
  for (NodeId id = 0; id < nodes_.size(); id++) {
    const NodeId parent = nodes_[id].parent;
    if (parent == no_parent) {
      continue;
    }
    /* A node now under another parent is another thing to whoever tapped it, such as the second
     * modifier's Remove keyed by its place once the first is gone (ROUND6 BUSY-2). */
    ViewState::Sent &moved = state_.sent_.find(key(nodes_[id]))->second;
    if (moved.parent != key(nodes_[parent])) {
      if (!moved.parent.empty() || moved.changed == 0) {
        moved.changed = state_.version_ + 1;
      }
      moved.parent.assign(key(nodes_[parent]));
    }
    if (first_child[parent] == no_parent) {
      first_child[parent] = id;
    }
    else {
      next_sibling[last_child[parent]] = id;
    }
    last_child[parent] = id;
  }

  /* Children lists that changed, written with their keys. */
  std::vector<flatbuffers::Offset<protocol::Children>> children;
  std::vector<flatbuffers::Offset<flatbuffers::String>> child_keys;
  for (NodeId id = 0; id < nodes_.size(); id++) {
    /* Each key hashed with the hash of those before it, so order counts, and "ab", "c" differs
     * from "a", "bc". */
    uint64_t hash = 0;
    for (NodeId child = first_child[id]; child != no_parent; child = next_sibling[child]) {
      const std::string_view child_key = key(nodes_[child]);
      hash = XXH3_64bits_withSeed(child_key.data(), child_key.size(), hash + 1);
    }
    ViewState::Sent &sent = state_.sent_.find(key(nodes_[id]))->second;
    if (hash == sent.children && !(reset_ && hash != 0)) {
      continue;
    }
    sent.children = hash;
    child_keys.clear();
    for (NodeId child = first_child[id]; child != no_parent; child = next_sibling[child]) {
      const std::string_view child_key = key(nodes_[child]);
      child_keys.push_back(buffer.CreateString(child_key.data(), child_key.size()));
    }
    const std::string_view parent_key = key(nodes_[id]);
    children.push_back(protocol::CreateChildren(buffer,
                                                buffer.CreateString(parent_key.data(),
                                                                    parent_key.size()),
                                                buffer.CreateVector(child_keys)));
  }

  /* Nodes gone since the last build. */
  std::vector<flatbuffers::Offset<flatbuffers::String>> removed;
  if (state_.removed_.size() > 512) {
    state_.removed_.clear();
  }
  for (auto sent = state_.sent_.begin(); sent != state_.sent_.end();) {
    if (sent->second.build == state_.build_) {
      ++sent;
      continue;
    }
    removed.push_back(buffer.CreateString(sent->first));
    state_.removed_.insert_or_assign(sent->first, state_.version_ + 1);
    sent = state_.sent_.erase(sent);
  }

  const std::string_view top = top_ == no_parent ? std::string_view() : key(nodes_[top_]);
  const bool top_changed = top != state_.top_;
  if (!reset_ && !top_changed && changed_starts_.empty() && children.empty() && removed.empty()) {
    return 0;
  }
  state_.top_.assign(top);

  std::vector<flatbuffers::Offset<protocol::NodeBuffer>> nodes;
  nodes.reserve(changed_starts_.size());
  for (size_t i = 0; i < changed_starts_.size(); i++) {
    const size_t start = changed_starts_[i];
    const size_t end = i + 1 < changed_starts_.size() ? changed_starts_[i + 1] : changed_.size();
    /* The node's buffer as it is, aligned as FlatBuffers needs for reading it in place. */
    buffer.ForceVectorAlignment(
        end - start, sizeof(uint8_t), flatbuffers::AlignOf<flatbuffers::largest_scalar_t>());
    nodes.push_back(protocol::CreateNodeBuffer(
        buffer, buffer.CreateVector(changed_.data() + start, end - start)));
  }
  return protocol::CreateUpdate(buffer,
                                subscription,
                                ++state_.version_,
                                reset_,
                                reset_ || top_changed ? buffer.CreateString(top.data(), top.size()) :
                                                        0,
                                buffer.CreateVector(nodes),
                                buffer.CreateVector(children),
                                buffer.CreateVector(removed));
}

}  // namespace blender::wm::native_ui
