# MyMole

MyMole is a macOS 26 application for storage analysis, file cleanup, application
removal and system monitoring. It uses Swift 6.2, SwiftUI and AppKit.

## Editions

- **App Store:** runs in the App Sandbox and accesses selected folders through
  security-scoped bookmarks. The privileged helper is excluded.
- **Direct:** includes system cleanup and maintenance through a helper launched
  for one request after macOS administrator authorization.

## Features

- Disk Map displays folder sizes as a sunburst, treemap and file list, with
  large-file filtering and comparisons between scans.
- Deep Clean lists application caches, logs, crash reports, package-manager
  caches and Mail attachments.
- Uninstall lists applications and associated files identified by bundle ID,
  application name or signed app groups.
- Projects measures build output, dependencies, caches and development files.
- Installers lists disk images, packages and archives.
- Live Status displays CPU, memory, disk, network and battery measurements.
- Optimize runs a fixed set of maintenance tasks in the direct edition.

Selected user files move to the Trash, with Undo. Keep lists and path checks
apply before each move. System cleanup uses permanent deletion through the
privileged helper after confirmation and administrator authorization.

## License

MyMole is source-available. Personal and other non-commercial use is free.
Business use requires a paid commercial license or an authorized store purchase.
See [LICENSE](LICENSE).
