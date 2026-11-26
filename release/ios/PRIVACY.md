# Satsuma 3D: privacy

Last updated: 2026-11-26. Applies to Satsuma 3D version 0.1.0 and the test builds before a public release.

## In short

Satsuma 3D does not collect your data. It does not track you. It does not send anything to the
developer or to anyone else. Your files stay on your iPad, or wherever you save them.

## What the app collects

Nothing. The app's privacy manifest (the file Apple requires, shipped inside the app) says:
no tracking, no tracking domains, and no data collected.

## What the app does on your device

- **Your documents.** It reads and writes the files you open and save, in the places you choose,
  including iCloud Drive if you pick it. It does not upload them.
- **Its own files.** Settings, automatic saves, templates and temporary files are kept in the
  app's own storage on your iPad.
- **Free space.** Before it saves, it checks how much space is left on the drive it is saving to,
  and warns you if it is low. The figure stays on the iPad.
- **The camera.** Only if you turn on Face Control or AR Preview. Face Control uses the front
  camera's face tracking to set a brush from your expression. The app says nothing is recorded.
  AR Preview shows the scene in the room through the camera. The app asks you for permission
  first.
- **Photos.** Only when you choose Save to Photos in a share sheet, the app adds that render or
  image to your photo library. iPadOS asks you for permission first. The app never reads your
  photo library.
- **Online access is switched off.** The app never goes online. Blender's own online features
  (downloading extensions, checking for updates) are forced off and cannot be switched on. When
  you tap a link, for example to the source code or the Blender website, iPadOS opens it in your
  browser; that connection is your browser's, not the app's.

## The session log

The app keeps a log of the session to help find faults. It lists the commands you ran with their
settings, the messages the app showed, when documents opened and saved, which interface showed,
window and viewport sizes, layout checks, the steps of developer checks, the gestures on the
navigation gizmo, when side panels opened and closed, input that arrived while a sheet was open,
and a mark at most once a minute while the app is in use. It can include the names of your files
and objects. It stays on your iPad unless you choose Settings > About > Share Session Log and
send it.

## TestFlight

Test builds are handed out through Apple's TestFlight. TestFlight is Apple's service, not ours,
and it collects its own information when you use it, for example crash information and feedback.
What it collects, and for how long, is described by Apple:
https://www.apple.com/legal/privacy/data/en/test-flight/

If you send feedback through TestFlight, or write to us, we receive what you send, such as your
email address and screenshots. We use it only to fix the app.

## The source

The source code is public, and so is every test build's commit:
https://github.com/NeroSiegfried/satsuma3d. You can check what the app does.

## Independence

Satsuma 3D is built on Blender's source code. It is independent of the Blender Foundation, which
does not endorse it.

## Contact

`<your feedback address>`
