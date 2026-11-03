/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#include "testing/testing.h"

#include <algorithm>

#include "view_tree.hh"

namespace blender::wm::native_ui::tests {

static protocol::NumberT number(const double value)
{
  protocol::NumberT number;
  number.value = value;
  return number;
}

/** A panel with a number for each value. */
static ViewTree panel(std::initializer_list<std::pair<const char *, double>> values)
{
  ViewBuilder builder;
  protocol::NodeT &panel = builder.top("panel", protocol::PanelT{});
  panel.label = "Transform";
  for (const auto &[key, value] : values) {
    builder.add(panel, key, number(value)).label = key;
  }
  return builder.finish();
}

static std::vector<std::string> keys(const protocol::UpdateT &update)
{
  std::vector<std::string> keys;
  for (const auto &node : update.nodes) {
    keys.push_back(node->key);
  }
  std::sort(keys.begin(), keys.end());
  return keys;
}

TEST(native_ui_view_tree, builder)
{
  const ViewTree tree = panel({{"x", 1.0}, {"y", 2.0}});
  EXPECT_EQ(tree.top, "panel");
  EXPECT_EQ(tree.nodes.size(), 3);
  const protocol::NodeT &top = *tree.nodes.at("panel");
  EXPECT_EQ(top.children, (std::vector<std::string>{"x", "y"}));
  EXPECT_EQ(tree.nodes.at("y")->content.AsNumber()->value, 2.0);
}

TEST(native_ui_view_tree, first_update_is_whole)
{
  ViewTree sent;
  const auto update = view_update(sent, panel({{"x", 1.0}}), true);
  ASSERT_NE(update, nullptr);
  EXPECT_TRUE(update->reset);
  EXPECT_EQ(update->top, "panel");
  EXPECT_EQ(keys(*update), (std::vector<std::string>{"panel", "x"}));
  EXPECT_TRUE(update->removed.empty());
}

TEST(native_ui_view_tree, unchanged_sends_nothing)
{
  ViewTree sent;
  view_update(sent, panel({{"x", 1.0}, {"y", 2.0}}), true);
  EXPECT_EQ(view_update(sent, panel({{"x", 1.0}, {"y", 2.0}}), false), nullptr);
}

TEST(native_ui_view_tree, only_changed_nodes)
{
  ViewTree sent;
  view_update(sent, panel({{"x", 1.0}, {"y", 2.0}}), true);
  const auto update = view_update(sent, panel({{"x", 1.0}, {"y", 3.0}}), false);
  ASSERT_NE(update, nullptr);
  EXPECT_FALSE(update->reset);
  EXPECT_EQ(keys(*update), (std::vector<std::string>{"y"}));
}

TEST(native_ui_view_tree, label_change_is_a_change)
{
  ViewTree sent;
  view_update(sent, panel({{"x", 1.0}}), true);
  ViewTree next = panel({{"x", 1.0}});
  next.nodes.at("x")->label = "Location X";
  const auto update = view_update(sent, std::move(next), false);
  ASSERT_NE(update, nullptr);
  EXPECT_EQ(keys(*update), (std::vector<std::string>{"x"}));
}

TEST(native_ui_view_tree, removed_and_added)
{
  ViewTree sent;
  view_update(sent, panel({{"x", 1.0}, {"y", 2.0}}), true);
  const auto update = view_update(sent, panel({{"x", 1.0}, {"z", 4.0}}), false);
  ASSERT_NE(update, nullptr);
  /* The panel's children changed, and the new node. */
  EXPECT_EQ(keys(*update), (std::vector<std::string>{"panel", "z"}));
  EXPECT_EQ(update->removed, (std::vector<std::string>{"y"}));
}

TEST(native_ui_view_tree, reorder_sends_parent_only)
{
  ViewTree sent;
  view_update(sent, panel({{"x", 1.0}, {"y", 2.0}}), true);
  const auto update = view_update(sent, panel({{"y", 2.0}, {"x", 1.0}}), false);
  ASSERT_NE(update, nullptr);
  EXPECT_EQ(keys(*update), (std::vector<std::string>{"panel"}));
}

TEST(native_ui_view_tree, packs_and_reads_back)
{
  ViewTree sent;
  auto update = view_update(sent, panel({{"x", 1.5}}), true);
  ASSERT_NE(update, nullptr);
  update->subscription = 7;
  update->version = 1;
  protocol::UpdatesT updates;
  updates.updates.push_back(std::move(update));

  flatbuffers::FlatBufferBuilder builder;
  builder.Finish(protocol::Updates::Pack(builder, &updates));
  flatbuffers::Verifier verifier(builder.GetBufferPointer(), builder.GetSize());
  ASSERT_TRUE(verifier.VerifyBuffer<protocol::Updates>(nullptr));

  const protocol::Updates *read = flatbuffers::GetRoot<protocol::Updates>(builder.GetBufferPointer());
  ASSERT_EQ(read->updates()->size(), 1);
  const protocol::Update *first = read->updates()->Get(0);
  EXPECT_EQ(first->subscription(), 7);
  EXPECT_EQ(first->top()->str(), "panel");
  bool found = false;
  for (const protocol::Node *node : *first->nodes()) {
    if (node->key()->str() == "x") {
      found = true;
      EXPECT_EQ(node->content_as_Number()->value(), 1.5);
    }
  }
  EXPECT_TRUE(found);
}

}  // namespace blender::wm::native_ui::tests
