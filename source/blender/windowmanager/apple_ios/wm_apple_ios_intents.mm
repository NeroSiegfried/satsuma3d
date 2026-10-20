/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup wm
 *
 * Siri and Shortcuts: the app's intents ask Blender through `bl_ui.native_intents`, which answers
 * with JSON. The request runs on the engine thread between frames, as the document's own work
 * does, and the answer comes back on the main queue, so the intent waits without holding up the
 * interface.
 */

#import <Foundation/Foundation.h>

#include <string>

#include "GHOST_IOSRuntime.hh"

#include "BLI_utildefines.h"

#include "MEM_guardedalloc.h"

#ifdef WITH_PYTHON
#  include "BPY_extern_run.hh"
#endif

/** A Python string literal holding `text`. */
static std::string intent_python_string(const char *text)
{
  std::string literal = "\"";
  for (const char *c = text; *c; c++) {
    switch (*c) {
      case '\\':
        literal += "\\\\";
        break;
      case '"':
        literal += "\\\"";
        break;
      case '\n':
        literal += "\\n";
        break;
      case '\r':
        literal += "\\r";
        break;
      case '\t':
        literal += "\\t";
        break;
      default:
        literal += *c;
        break;
    }
  }
  return literal + "\"";
}

/** See `wm_apple_ios_swift_bridge.h`. */
extern "C" void wm_apple_ios_intent_perform(const char *request,
                                            void (^completion)(NSString *answer))
{
  void (^done)(NSString *) = [completion copy];
  const std::string expression = "bl_ui.native_intents.perform(bpy.context, " +
                                 intent_python_string(request ? request : "{}") + ")";
  GHOST_ios_engine_perform([expression, done](blender::bContext *C) {
    NSString *answer = nil;
#ifdef WITH_PYTHON
    if (C) {
      const char *imports[] = {"bpy", "bl_ui", nullptr};
      char *result = nullptr;
      if (BPY_run_string_as_string(C, imports, expression.c_str(), nullptr, &result)) {
        answer = [[NSString alloc] initWithUTF8String:result];
        MEM_delete(result);
      }
    }
#else
    UNUSED_VARS(C, expression);
#endif
    dispatch_async(dispatch_get_main_queue(), ^{
      done(answer);
      [answer release];
      [done release];
    });
  });
}
