/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */
/** \file
 * \ingroup GHOST
 *
 * Messages and snapshots passed between Blender's loop and a native interface running on its own
 * thread, such as the iPad's, without either waiting for the other.
 */

#pragma once

#include <atomic>
#include <utility>
#include <vector>

/**
 * Tells the other side that a message or snapshot is waiting: Blender's loop, which sleeps while
 * it has nothing to do, or the native interface, which updates from snapshots instead of polling
 * for them. Each platform with a native interface defines it, see `GHOST_SystemIOS.mm`.
 */
void GHOST_mailbox_published();

/** Multiple producers, one consumer. Producers never take a lock held by the consumer.
 * A detached batch is reversed to preserve submission order. Destruction requires all
 * producers to have stopped. Values, including their payloads, belong to the queue. */
template<typename T> class GHOST_MessageQueue {
  struct Node {
    T value;
    Node *next;
  };
  std::atomic<Node *> head_{nullptr};

 public:
  ~GHOST_MessageQueue()
  {
    take();
  }

  void push(T value)
  {
    Node *node = new Node{std::move(value), head_.load(std::memory_order_relaxed)};
    while (!head_.compare_exchange_weak(
        node->next, node, std::memory_order_release, std::memory_order_relaxed))
    {
    }
    GHOST_mailbox_published();
  }

  std::vector<T> take()
  {
    Node *node = head_.exchange(nullptr, std::memory_order_acquire);
    Node *ordered = nullptr;
    while (node) {
      Node *next = node->next;
      node->next = ordered;
      ordered = node;
      node = next;
    }
    std::vector<T> result;
    while (ordered) {
      result.push_back(std::move(ordered->value));
      Node *next = ordered->next;
      delete ordered;
      ordered = next;
    }
    return result;
  }

  /** Replace adjacent previews only. Final edits and unrelated commands remain barriers. */
  template<typename Supersedes> std::vector<T> take_coalesced(Supersedes supersedes)
  {
    std::vector<T> result;
    for (T &value : take()) {
      if (!result.empty() && supersedes(result.back(), value)) {
        result.back() = std::move(value);
      }
      else {
        result.push_back(std::move(value));
      }
    }
    return result;
  }
};

/** Single-consumer latest-value mailbox. Superseded snapshots are reclaimed without
 * waiting for the consumer; taking a value transfers exclusive ownership to it. */
template<typename T> class GHOST_Latest {
  std::atomic<T *> value_{nullptr};

 public:
  ~GHOST_Latest()
  {
    delete value_.load();
  }
  void publish(T value)
  {
    delete value_.exchange(new T(std::move(value)));
    GHOST_mailbox_published();
  }
  bool take(T &value)
  {
    T *latest = value_.exchange(nullptr);
    if (!latest) {
      return false;
    }
    value = std::move(*latest);
    delete latest;
    return true;
  }
};
