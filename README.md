<!--
Keep this document short & concise,
linking to external resources instead of including content in-line.
See 'release/text/readme.html' for the end user read-me.
-->

Satsuma 3D
==========

Satsuma 3D is an iPad app built on Blender's source: Blender's engine under a native touch
interface written in SwiftUI. It is early work and is not in the App Store.

Satsuma 3D is an independent project. It is not affiliated with or endorsed by the Blender
Foundation.

- **Where the work is:** the branch `ipad/main`. The iPad interface is in
  `source/blender/windowmanager/apple_ios` (Swift and Objective-C) and in the native interface
  bridge beside it; packaging, the app's icon and its privacy manifest are in `release/ios`.
- **Credits:** Blender and its contributors (https://www.blender.org), whose source this is.
  William Reynish's native iPadOS interface branch of Blender, which this builds on.
- **Licence:** the GNU General Public License, as Blender's (see `COPYING` and
  `doc/license`).
- **Building:** see `release/ios/README.md`. The app needs Blender's iOS libraries and Xcode on a
  Mac, and runs on an iPad.
- **Large files:** this repository's large files (`.blend` files, images, fonts and the like) are
  stored with Git LFS on projects.blender.org, named in `.lfsconfig`. Install Git LFS before
  cloning, or run `git lfs pull` afterwards.

Blender's own read-me follows.

Blender
=======

Blender is the free and open source 3D creation suite.
It supports the entirety of the 3D pipeline—modeling, rigging, animation, simulation, rendering, compositing,
motion tracking and video editing.

![Blender screenshot](https://code.blender.org/wp-content/uploads/2018/12/springrg.jpg "Blender screenshot")

Project Pages
-------------

- [Main Website](http://www.blender.org)
- [Reference Manual](https://docs.blender.org/manual/en/latest/index.html)
- [User Community](https://www.blender.org/community/)

Development
-----------

- [Build Instructions](https://developer.blender.org/docs/handbook/building_blender/)
- [Code Review & Bug Tracker](https://projects.blender.org)
- [Developer Forum](https://devtalk.blender.org)
- [Developer Documentation](https://developer.blender.org/docs/)


License
-------

Blender as a whole is licensed under the GNU General Public License, Version 3.
Individual files may have a different but compatible license.

See [blender.org/about/license](https://www.blender.org/about/license) for details.
