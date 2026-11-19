/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once

#import <UIKit/UIKit.h>

/** The name the app calls itself, from its `Info.plist` (`IOS_PRODUCT_NAME`); the same as
 * `AppIdentity.name` in Swift (ROUND5 8A). */
NSString *wm_apple_ios_app_name();

/** The open document, or nil in the launcher. */
UIDocument *wm_apple_ios_launcher_document();
/** Whether a document is open that the system's back action can return from. */
bool wm_apple_ios_launcher_can_show_documents();
/** Close the document, which saves it, and return to the launcher. */
void wm_apple_ios_launcher_show_documents(id sender);
/** Choose a template and create an independent document without replacing unsaved work. */
void wm_apple_ios_launcher_new_document(UIViewController *presenter);
/** The document could not be opened: back to the launcher, which says why in Blender's words
 * and takes files again at once (ROUND6 SAFE-2). */
void wm_apple_ios_launcher_open_failed(UIDocument *document, NSString *reason);
/** A copy of the open document's work, written beside it at `next_to` and opened in its place
 * (ROUND6 SAFE-2: Save a Copy and Work on That). */
void wm_apple_ios_launcher_adopt_copy(NSURL *copy, NSURL *next_to);
/** A check launch's `document …` step, see `Snapshots.swift`; `done` gets what it logged. */
void wm_apple_ios_document_check_step(NSString *step, void (^done)(NSString *answer));

/* The document window, which GHOST shows over the launcher. */
#include "GHOST_IOSNativeInterface.hh"
