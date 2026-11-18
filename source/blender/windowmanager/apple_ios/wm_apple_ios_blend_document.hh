/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once

#import <UIKit/UIKit.h>

/**
 * A Blender file as an iOS document. Blender reads and writes the file itself; the document
 * coordinates access to it and saves changes without being asked, as documents do on iPadOS.
 */
@interface WMIOSBlendDocument : UIDocument
@property(nonatomic) BOOL templateDocument;
/** Follows Blender's unsaved changes, which drive saving. */
- (void)setBlenderModified:(BOOL)modified;
/**
 * Save now, if there are changes. Documents save only when closed and when the app leaves the
 * foreground, never while being edited: writing the file and its preview would interrupt work.
 */
- (void)saveChangesWithCompletionHandler:(void (^)(BOOL success))completionHandler;
/** Save now, as a save along the way writes, when anything changed since the last save. */
- (void)saveNow;
/** Blender loads the document's file again, as when it opened; `revert` only names it so in the
 * log (Revert has removed the auto-save first, see #WM_apple_ios_document_command). */
- (void)reopen:(BOOL)revert;
/** A write was refused, see #WM_apple_ios_document_write: Blender has another file loaded. */
@property(nonatomic, readonly) BOOL refused;
@end

/**
 * Save As (ROUND5 9D.2, decision 63): the document saved, then a copy exported where the person
 * picks, the window staying on its document. Save a Copy when a write was refused: what is loaded,
 * written as a copy and exported. From the shell's menu, Blender's Save As in either interface and
 * the refusal's alert. \a presenter may be nil: the topmost view then presents.
 */
void wm_apple_ios_document_save_as(UIViewController *presenter);
/** The view controller a sheet or alert is presented from: the topmost of the shown window. */
UIViewController *wm_apple_ios_top_presenter();

/**
 * Copy a validated document seed ("" aliases General) to a temporary location,
 * for the document browser to add as a new document. Calls `completion` on the main thread, with
 * nil on failure.
 */
void wm_apple_ios_document_create(NSString *app_template, void (^completion)(NSURL *url));

/** Bundled, versioned templates with resolved seed and preview URLs. No Blender calls. */
NSArray<NSDictionary *> *wm_apple_ios_document_templates();
void wm_apple_ios_template_save(NSString *title,
                                NSDictionary *presentation,
                                void (^completion)(NSString *error));
/** Personal templates only, except Duplicate which also accepts bundled templates. */
BOOL wm_apple_ios_template_manage(NSString *identifier, NSString *action, NSString *title);
