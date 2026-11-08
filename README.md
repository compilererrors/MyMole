# MyMole

MyMole is a macOS 26 application for storage analysis, file cleanup, application
removal and system monitoring. It is written in Swift 6.2 with SwiftUI and AppKit.

## Editions

- **App Store:** runs in the App Sandbox with access to selected folders through
  security-scoped bookmarks. It does not include the privileged helper.
- **Direct:** includes system cleanup and maintenance through a helper launched
  for one request after macOS administrator authorization.

## Storage analysis

Disk Map displays folder sizes as a sunburst, treemap and file list. It supports
large-file filtering, saved scans, exclusions and comparisons between scans.
Places lists mounted volumes and available space.

Projects measures build output, dependencies, caches and development files.
Project rules and keep lists control cleanup selection. History records size
changes between scans.

Duplicates compares file sizes, partial hashes and SHA-256 hashes. Similar Photos
compares image fingerprints. Both preserve at least one file in each group.
The Photos library is excluded.

## Cleanup and application removal

Deep Clean lists application caches, logs, crash reports, package-manager caches,
Mail attachments, simulator data and device backups. Installers lists disk
images, packages, archives and device software.

Uninstall lists applications and associated files identified by bundle ID,
application name or signed app groups. It supports batch removal, application
reset and review of files left by removed applications.
In Uninstall → Left by Removed Apps, search or filter leftovers from apps
deleted in Finder. Choose App in Trash uses the removed bundle's identities
for a more specific review while protecting files shared with installed apps.
An emptied Trash leaves the conservative name-based search available.

Uninstall → App Copies & Integrations compares copies by app ID, version,
build number and path, and marks possible test builds for review. Choose a
folder to include build outputs that the system index misses. Integrations
shows declared Services, document/URL handlers and bundled Finder extensions.
These declarations don't prove an integration is enabled or reproduce Siri's
app list. Recorded paths without an app are shown separately. Removal uses
the ordinary uninstall review, with shared data protected by discovered copies.

Tables support draggable column dividers, horizontal scrolling and full-text
hover tips. Right-click a header to fit visible contents or reset widths.

User-level cleanup moves selected files to the Trash and supports Undo. Keep
lists, path checks and running-application checks are applied before each move.
History records cleanup and restore operations. Emptying the Trash requires a
separate confirmation.

The direct edition also removes selected system caches and application leftovers
through the privileged helper. System deletion is permanent and requires
confirmation and administrator authorization.

## Monitoring and maintenance

Live Status displays CPU, memory, disk, network and battery measurements. The
direct edition also lists active processes. Startup Items lists launch jobs and
plug-ins.

The menu bar item provides status summaries and access to the app. Optional
scheduled scans and notifications report storage findings. Background scans do
not remove files.

Optimize runs a fixed set of system maintenance tasks in the direct edition.
The helper accepts only the operations defined by `PrivilegedRequest`.

## License

MyMole is source-available. Personal and other non-commercial use is free.
Business use requires a paid commercial license or an authorized store purchase.
See [LICENSE](LICENSE).
