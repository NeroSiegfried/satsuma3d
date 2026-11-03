/* SPDX-FileCopyrightText: 2025 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * Private to the native iPhone, iPad and Apple Vision Pro interface: Blender's commands and the
 * helpers its files share, implemented in `wm_apple_ios_interface.mm`.
 */

#pragma once

#import <MetalKit/MetalKit.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include "BLI_utildefines.h"

#include "GHOST_IOSNativeInterface.hh"
#include "GHOST_IOSRuntime.hh"

#import "wm_apple_ios_blend_document.hh"
#import "wm_apple_ios_icons.hh"
#import "wm_apple_ios_launcher.hh"

#include "WM_native_ui.h"

/* Helpers shared by the interface's files. */
UIImage *blenderIOSIcon(NSString *key, NSString *systemImage);
UIImage *blenderIOSBrushImage(NSString *previewPath, CGFloat diameter);
UIImage *blenderIOSActionIcon(NSString *opName, NSString *propertyName, NSString *propertyValue);
Class blenderIOSSwiftClass(NSString *name);
UIImage *blenderIOSMenuIcon(NSDictionary *item);
/** A Blender menu's items, given once Blender built them, or nil should it not; with \a position,
 * Blender's cursor there in the window's pixels. */
void blenderIOSMenuItems(NSString *route,
                         const CGPoint *position,
                         void (^completion)(NSArray *_Nullable items));
/** Run a menu's item by its route, with Blender's cursor at \a position if any. */
void blenderIOSMenuRun(NSString *route, const CGPoint *position);
UIMenu *blenderIOSNativeSubmenu(NSDictionary *item, NSString *identifier);
NSArray<UIMenuElement *> *blenderIOSNativeMenuElements(NSArray *items);

/** The SwiftUI document window, `WMIOSSwiftDocumentController` in `DocumentWindow.swift`. */
@protocol WMIOSDocumentController <GHOST_IOSWindowController>
- (instancetype)initWithMetalView:(MTKView *)metalView window:(void *)window;
- (void)updateDocumentControls;
@end
