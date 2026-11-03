/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup GHOST
 *
 * Where no native interface runs beside Blender, nothing waits on the mailbox: a message or
 * snapshot published is taken on Blender's own next pass.
 */

#include "GHOST_Mailbox.hh"

void GHOST_mailbox_published() {}
