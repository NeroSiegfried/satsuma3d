/* SPDX-FileCopyrightText: 2026 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * A number as Blender draws it (ROUND5 6D): exactly the decimals Blender shows for its property
 * and value, never a float's noise, and no sign on a value that shows as zero (ROUND5 7E/E5: a
 * Median of -0.00001 reads `0.0000`, not `-0.0000`). Foundation only, so
 * `tests/ios/test_number_text.py` can build it alone on the Mac.
 */

import Foundation

enum BlenderNumberText {
  /** \a shown (already in the unit shown, degrees for an angle) with \a decimals decimals and
   * \a unit after a space when there is one. */
  static func format(_ shown: Double, decimals: Int, unit: String?, locale: Locale = .current) -> String {
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.roundingMode = .halfUp
    formatter.minimumFractionDigits = decimals
    formatter.maximumFractionDigits = decimals
    var text = formatter.string(from: NSNumber(value: shown)) ?? "\(shown)"
    /* A value that rounds to zero at these decimals is zero: no sign (Blender's own drawing never
     * shows `-0.000` either). */
    let minus = formatter.minusSign ?? "-"
    if text.hasPrefix(minus) && !text.dropFirst(minus.count).contains(where: { $0.isNumber && $0 != "0" }) {
      text.removeFirst(minus.count)
    }
    guard let unit, !unit.isEmpty else { return text }
    return text + " " + unit
  }
}
