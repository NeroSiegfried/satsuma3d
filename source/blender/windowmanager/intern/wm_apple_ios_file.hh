/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

#pragma once

#include "WM_types.hh"

#include <functional>
#include <string>

namespace blender {
struct bContext;
struct wmOperator;

bool WM_apple_ios_fileselect_begin(bContext *C, wmOperator *op);
bool WM_apple_ios_fileselect_active(wmOperator *op);
void WM_apple_ios_fileselect_cancel(wmOperator *op);
void WM_apple_ios_fileselect_flush(bContext *C);
wmOperatorStatus WM_apple_ios_fileselect_exec(bContext *C, wmOperator *op);

/**
 * Blender's own dialog for an operator's properties, for the Desktop Interface, whose OK and
 * Cancel hand the operator back (true for OK) instead of running or freeing it: a file selector's
 * options before the system picker (ROUND6 FILES-2). Defined in `wm_operators.cc`.
 */
void WM_apple_ios_options_dialog(bContext *C,
                                 wmOperator *op,
                                 std::string title,
                                 std::string confirm_text,
                                 std::function<void(bContext *, bool)> then);

namespace ui {
/** The native interface's operator dialog, handing the operator back on OK and Cancel (true for
 * OK) instead of owning it. False when another dialog is open. See
 * `interface_native_properties.cc`. */
bool native_operator_dialog_handback(bContext *C,
                                     wmOperator *op,
                                     const std::string &title,
                                     const std::string &confirm,
                                     std::function<void(bContext *, bool)> then);
/** Close the dialog of \a op, if one is open, without handing it back. */
void native_operator_dialog_abandon(const wmOperator *op);
}  // namespace ui

}  // namespace blender
