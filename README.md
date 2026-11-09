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
Browse can sort by name, size, date, kind or file count. Choose All Contents
includes hidden and small files in the open folder while leaving the folder
itself in place. Opening the removal review stops an active scan and preserves
the choice; files move only after the checks finish and you confirm.

Projects measures build output, dependencies, caches and development files.
Project rules and keep lists control cleanup selection. History records size
changes between scans.

Duplicates compares file sizes, partial hashes and SHA-256 hashes. Similar Photos
compares image fingerprints. Both preserve at least one file in each group.
The Photos library is excluded.
Smart Scan includes identical-file detection after the cleanup scans. Opening
Duplicates starts its first search automatically. Verified groups appear while
the search runs; choosing copies is available after completion. Stop keeps the
previous completed result. Requested folders remain available when access is
granted after launch, and excluded or unreadable locations are reported.

## Cleanup and application removal

Deep Clean lists application caches, logs, crash reports, package-manager caches,
Mail attachments, simulator data and device backups. Installers lists disk
images, packages, archives and device software.

Uninstall lists applications and associated files identified by bundle ID,
application name or signed app groups. It supports batch removal, application
reset and review of files left by removed applications.
Only identity-linked caches and logs start selected. Website data, cookies,
saved state, scripts, launch configuration and permanent system items need
an explicit choice. Every review also searches hidden settings and deeper name
matches and, in the direct edition, exact app IDs in per-user cache and temporary
folders; these results start unselected. Unverified matches remain visible.
Select a row to inspect its full path and matching information. Eligible
unverified files can be chosen individually; none start selected. Removing them
always asks for a caution confirmation and uses the Trash. Known competing owners, Keep
rules, protected locations and changed files remain blocked; manual matches
cannot be combined with permanent system deletion. Reviews disclose search
limits and unreadable locations.

App Management is separate from Full Disk Access and administrator approval.
The App Store edition also asks you to select the exact app in a file dialog
after confirming an uninstall. Cancel or another app stops the operation.
The review links to its setup and identifies the running copy. If macOS denies
moving an app, Show App in Finder offers a manual route. When that same app is
found in the home folder's Trash, its review switches to leftovers with all
choices cleared. Granting access or moving the app never starts cleanup.

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
File and folder menus offer Show in Finder, path and absolute-path copying,
plus name, shell-quoted path and file URL formats. Inspection-only findings
also support these browsing actions.

User-level cleanup moves selected files to the Trash and supports Undo. Keep
lists, path checks and running-application checks are applied before each move.
History records cleanup and restore operations. Emptying the Trash requires a
separate confirmation.

The direct edition also removes selected system caches and application leftovers
through the privileged helper. System deletion is permanent and requires
confirmation and administrator authorization.

## Monitoring and maintenance

Live Status displays CPU, memory, disk, network and battery measurements. The
overview uses compact cards with stable geometry, small history graphs and
Details for secondary readings. Card size, order and visibility are configurable;
network details let you choose the named interface shown in the overview. The
direct edition also lists active processes. Startup Items lists launch jobs and
plug-ins.

The menu bar item provides status summaries and access to the app. Optional
scheduled scans and notifications report storage findings. Background scans do
not remove files.

Optimize runs a fixed set of system maintenance tasks in the direct edition.

The interface is in English. Numbers, sizes and dates follow the system locale.

## Keyboard navigation

Use Tab and Shift-Tab to move between controls, and arrow keys in lists, trees
and the application grid. Enable Keyboard navigation in macOS Settings to
include ordinary buttons in the Tab order. Return opens the selected row;
Space previews files. Control-Return or Shift-F10 opens a file row's menu,
and Option-Command-C copies its absolute path.

Escape or Command-W closes the frontmost dialog. A confirmation cancels first,
leaving its review open. Reviews stay open while a removal is running.
Command-K opens the command palette; Command-F focuses the current search.

## License

MyMole is source-available. Personal and other non-commercial use is free.
Business use requires a paid commercial license or an authorized store purchase.
See [LICENSE](LICENSE).
