/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#include "testing/testing.h"

#include <algorithm>
#include <map>

#include "view_tree.hh"

namespace blender::wm::native_ui::tests {

/** A panel with a number for each value, as a view's whole build. */
static flatbuffers::Offset<protocol::Update> build_panel(
    ViewState &state,
    flatbuffers::FlatBufferBuilder &buffer,
    std::initializer_list<std::pair<const char *, double>> values,
    const bool reset = false,
    const char *panel_label = "Transform")
{
  ViewBuilder builder(state, reset);
  const NodeId panel = builder.top("panel", [&](auto &node, NodeFields &fields) {
    fields.label = panel_label;
    return protocol::CreatePanel(node);
  });
  for (const auto &[key, value] : values) {
    builder.add(panel, key, [&](auto &node, NodeFields &fields) {
      fields.label = key;
      return protocol::CreateNumber(node, value);
    });
  }
  return builder.finish(buffer, 1);
}

/** An update as the interface reads it. */
struct Read {
  bool reset = false;
  std::string top;
  std::map<std::string, double> numbers;
  std::map<std::string, std::string> labels;
  std::map<std::string, std::vector<std::string>> children;
  std::vector<std::string> removed;
  uint32_t version = 0;
};

static std::optional<Read> update(flatbuffers::FlatBufferBuilder &buffer,
                                  const flatbuffers::Offset<protocol::Update> offset)
{
  if (offset.IsNull()) {
    return std::nullopt;
  }
  buffer.Finish(offset);
  flatbuffers::Verifier verifier(buffer.GetBufferPointer(), buffer.GetSize());
  EXPECT_TRUE(verifier.VerifyBuffer<protocol::Update>(nullptr));
  const auto *update = flatbuffers::GetRoot<protocol::Update>(buffer.GetBufferPointer());
  Read read;
  read.reset = update->reset();
  read.version = update->version();
  read.top = update->top() ? update->top()->str() : "";
  for (const protocol::NodeBuffer *nested : *update->nodes()) {
    /* Each node is a buffer of its own, read in place. */
    EXPECT_EQ(uintptr_t(nested->node()->data()) % alignof(uint64_t), 0);
    const protocol::Node *node = nested->node_nested_root();
    read.labels[node->key()->str()] = node->label() ? node->label()->str() : "";
    if (const protocol::Number *number = node->content_as_Number()) {
      read.numbers[node->key()->str()] = number->value();
    }
  }
  for (const protocol::Children *children : *update->children()) {
    std::vector<std::string> keys;
    for (const flatbuffers::String *key : *children->keys()) {
      keys.push_back(key->str());
    }
    read.children[children->parent()->str()] = keys;
  }
  for (const flatbuffers::String *key : *update->removed()) {
    read.removed.push_back(key->str());
  }
  return read;
}

TEST(native_ui_view_tree, first_update_is_whole)
{
  ViewState state;
  flatbuffers::FlatBufferBuilder buffer;
  const auto read = update(buffer, build_panel(state, buffer, {{"x", 1.0}, {"y", 2.0}}, true));
  ASSERT_TRUE(read);
  EXPECT_TRUE(read->reset);
  EXPECT_EQ(read->top, "panel");
  EXPECT_EQ(read->version, 1);
  EXPECT_EQ(read->labels.size(), 3);
  EXPECT_EQ(read->numbers.at("y"), 2.0);
  EXPECT_EQ(read->children.at("panel"), (std::vector<std::string>{"x", "y"}));
  EXPECT_TRUE(read->removed.empty());
}

TEST(native_ui_view_tree, unchanged_sends_nothing)
{
  ViewState state;
  flatbuffers::FlatBufferBuilder buffer;
  build_panel(state, buffer, {{"x", 1.0}, {"y", 2.0}}, true);
  flatbuffers::FlatBufferBuilder next;
  EXPECT_FALSE(update(next, build_panel(state, next, {{"x", 1.0}, {"y", 2.0}})));
  EXPECT_EQ(state.version(), 1);
}

TEST(native_ui_view_tree, only_changed_nodes)
{
  ViewState state;
  flatbuffers::FlatBufferBuilder buffer;
  build_panel(state, buffer, {{"x", 1.0}, {"y", 2.0}}, true);
  flatbuffers::FlatBufferBuilder next;
  const auto read = update(next, build_panel(state, next, {{"x", 1.0}, {"y", 3.0}}));
  ASSERT_TRUE(read);
  EXPECT_FALSE(read->reset);
  EXPECT_EQ(read->version, 2);
  EXPECT_EQ(read->numbers, (std::map<std::string, double>{{"y", 3.0}}));
  EXPECT_EQ(read->labels.size(), 1);
  EXPECT_TRUE(read->children.empty());
  EXPECT_TRUE(read->removed.empty());
}

TEST(native_ui_view_tree, parent_change_sends_parent_only)
{
  ViewState state;
  flatbuffers::FlatBufferBuilder buffer;
  build_panel(state, buffer, {{"x", 1.0}}, true);
  flatbuffers::FlatBufferBuilder next;
  const auto read = update(next, build_panel(state, next, {{"x", 1.0}}, false, "Location"));
  ASSERT_TRUE(read);
  EXPECT_EQ(read->labels, (std::map<std::string, std::string>{{"panel", "Location"}}));
  EXPECT_TRUE(read->children.empty());
}

TEST(native_ui_view_tree, removed_and_added)
{
  ViewState state;
  flatbuffers::FlatBufferBuilder buffer;
  build_panel(state, buffer, {{"x", 1.0}, {"y", 2.0}}, true);
  flatbuffers::FlatBufferBuilder next;
  const auto read = update(next, build_panel(state, next, {{"x", 1.0}, {"z", 4.0}}));
  ASSERT_TRUE(read);
  /* The new node, and the panel's children; the panel itself is unchanged. */
  EXPECT_EQ(read->numbers, (std::map<std::string, double>{{"z", 4.0}}));
  EXPECT_EQ(read->labels.size(), 1);
  EXPECT_EQ(read->children.at("panel"), (std::vector<std::string>{"x", "z"}));
  EXPECT_EQ(read->removed, (std::vector<std::string>{"y"}));
}

TEST(native_ui_view_tree, reorder_sends_children_only)
{
  ViewState state;
  flatbuffers::FlatBufferBuilder buffer;
  build_panel(state, buffer, {{"x", 1.0}, {"y", 2.0}}, true);
  flatbuffers::FlatBufferBuilder next;
  const auto read = update(next, build_panel(state, next, {{"y", 2.0}, {"x", 1.0}}));
  ASSERT_TRUE(read);
  EXPECT_TRUE(read->labels.empty());
  EXPECT_EQ(read->children.at("panel"), (std::vector<std::string>{"y", "x"}));
}

TEST(native_ui_view_tree, emptied_children_are_sent)
{
  ViewState state;
  flatbuffers::FlatBufferBuilder buffer;
  build_panel(state, buffer, {{"x", 1.0}}, true);
  flatbuffers::FlatBufferBuilder next;
  const auto read = update(next, build_panel(state, next, {}));
  ASSERT_TRUE(read);
  EXPECT_EQ(read->children.at("panel"), std::vector<std::string>());
  EXPECT_EQ(read->removed, (std::vector<std::string>{"x"}));
}

TEST(native_ui_view_tree, reset_resends_everything)
{
  ViewState state;
  flatbuffers::FlatBufferBuilder buffer;
  build_panel(state, buffer, {{"x", 1.0}}, true);
  flatbuffers::FlatBufferBuilder next;
  const auto read = update(next, build_panel(state, next, {{"x", 1.0}}, true));
  ASSERT_TRUE(read);
  EXPECT_TRUE(read->reset);
  EXPECT_EQ(read->labels.size(), 2);
  EXPECT_EQ(read->children.at("panel"), (std::vector<std::string>{"x"}));
}

TEST(native_ui_view_tree, several_views_in_one_buffer)
{
  ViewState first, second;
  flatbuffers::FlatBufferBuilder buffer;
  std::vector<flatbuffers::Offset<protocol::Update>> updates;
  updates.push_back(build_panel(first, buffer, {{"x", 1.0}}, true));
  updates.push_back(build_panel(second, buffer, {{"y", 2.0}}, true));
  buffer.Finish(protocol::CreateUpdates(buffer, buffer.CreateVector(updates)));
  flatbuffers::Verifier verifier(buffer.GetBufferPointer(), buffer.GetSize());
  ASSERT_TRUE(verifier.VerifyBuffer<protocol::Updates>(nullptr));
  const auto *read = flatbuffers::GetRoot<protocol::Updates>(buffer.GetBufferPointer());
  ASSERT_EQ(read->updates()->size(), 2);
  EXPECT_EQ(read->updates()->Get(1)->nodes()->size(), 2);
}

}  // namespace blender::wm::native_ui::tests
