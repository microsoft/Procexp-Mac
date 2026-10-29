# Manual Test Bugs and Parity Gaps

Record each bug reported during manual testing, feature-parity gap identified by
source comparison, and related code change here with a stable ID. Update the
relevant entry whenever code changes, including affected files and verification.
Keep confirmed findings, proposed work, implemented source changes, successful
builds, and manual retests distinct; a completed analysis is not an implemented
feature.

Classify missing cross-platform functionality separately from intentional
macOS-native adaptations and Windows-only features. Do not mark an intentional
platform difference as a bug or silently expand the implementation scope.

## Pull request status (2026-10-29)

- **Merged:** [#15](https://github.com/microsoft/Procexp-Mac/pull/15), "Fix process
  metrics, native UI behavior, and helper lifecycle bugs," merged into `main`
  on 2026-10-21 as `6845dcc`. That PR delivered the earlier bug-fix batch.
- **Open for review, not merged:** [#17](https://github.com/microsoft/Procexp-Mac/pull/17)
  contains the manual fixes MT-001 through MT-005 and the native parity
  implementation below, all made after #15. #15's merged state does not apply to
  these changes. Manual retest and signing/permission limitations remain separate
  from whether a PR is merged.
- **PR scope:** App fixes, selected native parity features, necessary packaging
  settings, this record, and the focused provider-error regression. The older
  coverage campaign, fixture/workload applications and broad test infrastructure
  remain local and are excluded. Their historical validation evidence below
  refers to the full local worktree, not test files shipped in this PR.
- **Curated PR verification:** The exact production-only snapshot built on
  2026-10-29, passed strict app signature verification and the committed
  provider-error regression, and retained `Sysinternals Process Explorer` as its
  bundle name. Packaging scripts passed shell syntax checks. The snapshot uses
  the existing production providers rather than importing the older test-only
  provider/clock infrastructure. No helper or login item was installed.

## MT-001: Path value is vertically misaligned in file descriptor details

**Reported:** 2026-10-27

**Status:** Fixed in source; development app built; awaiting manual retest.

**Reproduction:** Select `ProcexpTestApp`, open its Handles list, and double-click
file descriptor 1 (`/dev/null`).

**Observed:** The `/dev/null` value appears below the Path label, creating an
apparent gap. The path itself has no leading space.

**Expected:** The Path label and its value appear aligned on the same row.

**Cause:** Text-baseline alignment was applied to an embedded AppKit scrolling
field rather than ordinary SwiftUI text.

**Fix:** Vertically center rows containing a scrolling field while preserving
text-baseline alignment for ordinary text rows. Apply the same correction to the
equivalent module-detail rows.

**Files:** `App/LowerPane/HandleDetailWindow.swift`,
`App/LowerPane/ModuleDetailWindow.swift`.

**Verification:** Development Debug app built successfully on 2026-10-27. Manual
retest pending: check path alignment, text selection, horizontal scrolling, and the
equivalent module rows after quitting and reopening the app.

## MT-002: Helper registration failure hides the underlying error

**Reported:** 2026-10-27

**Status:** Missing-helper diagnostic manually verified on 2026-10-27. Helper
activation remains unavailable in the current plain development build.

**Reproduction:** Attempt to enable the privileged helper in the development app
built directly with Xcode.

**Observed:** The Could Not Enable Helper dialog shows
`ProcexpModel.ProviderError error 0` instead of the actual failure.

**Expected:** Explain the missing embedded helper in a plain Xcode build. For a
packaged build, preserve any actual registration error.

**Cause:** Plain Xcode builds omit the helper executable and launchd plist.
Registration was attempted anyway, and `ProviderError` did not implement
`LocalizedError`, hiding its associated failure message.

**Fix:** Check for the embedded launchd plist and executable before registration,
and provide localized descriptions for provider errors that preserve underlying
messages.

**Files:** `Sources/ProcexpModel/Providers.swift`,
`Sources/ProcexpPrivileged/PrivilegedDataProvider.swift`,
`Tests/ProcexpModelTests/ProcexpModelTests.swift`, `Helper/README.md`.

**Verification:** Development Debug app built successfully on 2026-10-27. The
regression test for Swift and NSError descriptions passed. The user's subsequent
screenshot confirms that the dialog explains the missing embedded helper instead
of displaying `ProviderError error 0`. No helper installation, registration, or
system configuration changes performed. Packaged-build registration errors and
actual helper activation remain unqualified; activation requires a properly
packaged and signed app plus separate macOS approval.

## MT-003: Find Window does not reliably reveal the selected process

**Reported:** 2026-10-27

**Status:** Fixed in source; native hosted regression passed. Main app rebuilt on
2026-10-28; awaiting manual retest.

**Reproduction:** Use Find Window's Process and click another app's window when
its process is off-screen, inside a collapsed branch, or hidden by a filter.
Repeat after scrolling away from the same selected process, including while
sampling is paused.

**Observed:** Picking a window does not reliably scroll the owning process into
view, even when it becomes the selected process.

**Expected:** Select the owning process, reveal its row, and show it in the main
Process Explorer window on every successful pick.

**Cause:** The picker only assigned the selection. Selection restoration scrolled
only when the selected process changed, and an active filter could still hide
the target.

**Fix:** Issue an explicit reveal request on each successful pick, clear the
process filter, expand collapsed ancestors, scroll both process-list panes, and
bring the main list forward with keyboard focus. Preserve ordinary refresh
behavior so scrolling away is not continually undone. The 2026-10-28 native-parity
pass also re-enables all-user visibility when the picked process belongs to
another user, so the new ownership filter cannot hide an explicit reveal.

**Files:** `App/AppModel.swift`, `App/MainWindow/MainWindowView.swift`,
`App/MainWindow/ProcessOutlineView.swift`,
`Tests/AppModelTests/OutlineCoverageTests.swift`.

**Verification:** Native hosted tests passed on 2026-10-27 for the shared reveal
action: filtered and collapsed targets, repeated selection while paused, both
panes' visible bounds, keyboard focus, and preserving scroll position on ordinary
updates. Existing window-hit-testing and native navigation regressions also
passed. The main development app was rebuilt and its code signature verified on
2026-10-28. An end-to-end manual picker retest remains pending after quitting and
reopening the app.

## MT-004: Show Process Tree appears inactive and has no visible on/off state

**Reported:** 2026-10-27

**Status:** Fixed in source; native hosted regression passed. Main app rebuilt on
2026-10-28; awaiting manual retest.

**Reproduction:** Choose View > Show Process Tree or click the tree toolbar button
when the hierarchy is already displayed.

**Observed:** Nothing visibly changes. The command only restored tree view and
could not switch it off; the toolbar could also remain highlighted while a column
sort displayed a flat list.

**Expected:** A checked Show Process Tree toggle switches between hierarchical and
flat views. The menu and toolbar agree with the displayed mode.

**Fix:** Use the same explicit mode setter for the menu and toolbar. Enabling tree
view clears column sorting. Sorting updates the displayed tree state, and
clearing the Process-column sort restores the mode that preceded sorting.

**Files:** `App/AppModel.swift`, `App/Menus/AppMenus.swift`,
`App/MainWindow/MainWindowView.swift`, `App/MainWindow/ProcessOutlineView.swift`,
`Tests/AppModelTests/OutlineCoverageTests.swift`.

**Verification:** Native hosted tests passed on 2026-10-27 for tree/flat
transitions, restoring the tree after sorting, and preserving the prior mode after
the Process-column sort cycle. The main development app was rebuilt and its code
signature verified on 2026-10-28. Manual menu, toolbar, and shortcut retests remain
pending after quitting and reopening the app.

## MT-005: Application menu name differs from the main window title

**Reported:** 2026-10-28

**Status:** Fixed in source; rebuilt app metadata verified. Awaiting manual retest.

**Reproduction:** Activate Process Explorer and compare its application menu name
with the main window title.

**Observed:** The menu is named `ProcexpMac`, while the window title is
`Sysinternals Process Explorer`.

**Expected:** Both are named `Sysinternals Process Explorer`.

**Cause:** The generated `CFBundleName` defaulted to the target name, and the
display name differed between build flavors.

**Fix:** Set the main product name (which generates `CFBundleName`) and
`CFBundleDisplayName` to the requested name for development and official builds.
Keep existing executable and module names, app filenames, and isolated bundle
identifiers unchanged. Packaging verifies both name fields.

**Files:** `project.yml`, `ProcexpMac.xcodeproj/project.pbxproj`,
`Scripts/build_release.sh`, `Scripts/dev_install_helper.sh`,
`Scripts/build-app.sh`, `docs/RELEASE.md`.

**Verification:** Development Debug app rebuilt successfully on 2026-10-28. Its
generated Info.plist has `Sysinternals Process Explorer` in both name fields,
matching the main scene title. Verified the unchanged development bundle ID and
executable name, code signature, and script syntax. Manual application menu retest
pending after quitting and reopening the rebuilt app.

## MT-006: Save and Save As parity is missing from the File menu

**Reported:** 2026-10-28

**Type:** Feature-parity gap (save workflow and report compatibility).

**Status:** Implemented on 2026-10-28; focused native hosted regressions passed
and development app rebuilt. Awaiting manual retest. See the implementation
record below.

**Reproduction:** Open File and use Export Process List repeatedly.

**Observed:** Only Export Process List is available. Every invocation prompts for
a destination, defaulting to `processes.csv`; there is no remembered save target
or separate Save As action. The exporter writes all snapshot records in numeric
PID order using six fixed CSV columns, regardless of the visible columns, filter,
tree order, or lower pane.

**Expected:** Save reuses the destination after the first successful selection;
Save As always prompts. Both use the same Windows-compatible text-report format,
not the current fixed-column CSV. The Windows report uses configured columns and
display order, tree indentation, and optionally the selected process's visible
lower-pane report. It includes offscreen rows of the current list, but excludes
filtered-out rows and collapsed descendants; it is not a loadable process
snapshot.

**Implementation:** Added Save and Save As backed by a shared text
report writer. Match tab separators, UTF-8 BOM, CRLF, configured column captions
and display strings, tree/list ordering, and the optional lower-pane section.
The last destination is remembered only after a successful write within the current
app session; Save As always prompts. Reports default to `.txt`. CSV remains a
separate File menu command.
Use honest macOS-native metric names and values rather than relabeling them as
non-equivalent Windows counters. Do not reproduce the Windows Threads-export bug.

**Report details:** Write configured header captions and formatted display values,
with a tab between cells and no trailing tab or CSV quoting. Preserve the current
sort/tree order and prefix the first cell with one ASCII space per tree level.
End each row with CRLF and always write a blank line after the process section.
When the lower pane is shown and a process is selected, append
`Process: <name> Pid: <decimal>`, another blank line, and the configured lower-pane
header and rows. There is no timestamp/application preamble, selected-row-only
export, or filename-extension-based switch to CSV. Native Mac metrics can match
this structure and displayed-data behavior without pretending to be identical
Windows counters.

**Files:** `App/Menus/AppMenus.swift`,
`App/MainWindow/MainWindowView.swift`, `App/MainWindow/ProcessOutlineView.swift`,
`App/LowerPane/LowerPaneView.swift`, `App/AppDependencies.swift`,
`Tests/UITests/WindowLayoutUITests.swift`.

**Verification:** Inspected the Mac command handlers, save panel, serializer, and
UTF-8 writer. Windows source at commit
`e15d7c9bb0d3a0cc3653b9739fcdfdfcb0aa9400`,
`/exe/PROCTHRD.CPP:19857-20029`, confirms both commands call `SaveList` with different
prompting flags and produce a text report, not a loadable process snapshot.
The Windows output uses a UTF-8 BOM, tabs, and CRLF, unlike the Mac CSV's UTF-8,
commas, and LF. The encoding definition is in the pinned Common dependency at
`a9ad41e79e42b0bfa1856e1e90b10dd1779418a3`, `SharedGlobals.h:251-266`.
The Windows dialog suggests `<selected process name>.txt` (or `Procexp.txt` for
synthetic names), and remembers the chosen path only within that app session.
Its lower-pane writer handles DLL and handle rows; the current Windows source
incorrectly selects DLL data when Threads mode is active. That Windows bug is
not a compatibility requirement.

## Windows menu-parity review (2026-10-28)

**Baseline:** Windows ProcExp `main` at
`e15d7c9bb0d3a0cc3653b9739fcdfdfcb0aa9400`, including runtime menu insertions,
compared with the current Mac worktree. This is a source review, not a Windows
binary UI test. Resource-only, removed, or broken menu entries are not treated as
proven working Windows features.

**Review status (before the implementation recorded below):** This review updated
the documentation only. The entries below
are confirmed gaps or explicitly qualified feature candidates, not implemented
features or blanket approval to add every Windows command. No application code,
build, helper installation, or system configuration changes were made for this
review. MT-006 separately tracks Save/Save As and report compatibility.

### Portable gaps and platform-gated feature candidates

Each row has a stable tracking ID. These rows describe the analysis baseline;
the implementation record below supersedes the status for selected entries.
None has been qualified by a manual retest.

| ID | Windows command or capability | Current Mac behavior and proposed scope | Classification |
|---|---|---|---|
| MT-007 | Options > Run At Logon | No equivalent option. Consider a consent-based macOS login item rather than copying Windows startup registration. | Portable feature gap |
| MT-008 | Options > Hide When Minimized | No corresponding preference. Define native window/menu-bar behavior before adding it. | Portable feature gap |
| MT-009 | Options > Allow Only One Instance | Standard macOS launches ordinarily reuse a running app, but there is no equivalent configurable instance policy. Assess whether an explicit policy is useful rather than claiming native launch reuse is absent. | Optional policy-control gap |
| MT-010 | Options > Record Activity History; View > Activity History | Live, bounded in-memory histories exist, but no recording/review workflow. Add real recording and review, not a menu-only placeholder. | Portable feature gap |
| MT-011 | Options > Tray Icons: I/O, Disk, Network, GPU, Commit, Physical Memory histories | Only the CPU menu-bar graph is selectable. Additional graphs need real available system metrics and honest macOS-native labels; Windows commit must not be relabeled as physical footprint. | Portable feature gap, metric availability gated |
| MT-012 | Options > Configure Symbols | No symbol-configuration UI. The external sample command can supply native symbolized text, but there is no equivalent interactive symbol/stack configuration workflow. | Platform-gated feature candidate |
| MT-013 | Options > Font | No user-selectable process-list font. Preserve dense-table geometry, readability, and accessibility if implemented. | Portable feature gap |
| MT-014 | View > Show Column Heatmaps | Usage heatmaps are drawn, but there is no on/off preference or menu control. | Portable control gap |
| MT-015 | View > Scroll to New Processes | Newly added processes can expand branches, but there is no optional automatic scroll-to-new-process behavior. Keep this distinct from explicit Find Window reveal. | Portable feature gap |
| MT-016 | View > Show Unnamed Handles and Mappings | No equivalent visibility toggle. Define which empty-name file descriptors and VM mappings the providers can actually enumerate. | Platform-gated control gap |
| MT-017 | View > Show Processes From All Users | The sampler enumerates accessible PIDs across users already; there is no current-user/all-users switch. A filter must not claim to grant extra permissions. | Optional portable filtering gap, not missing all-user enumeration |
| MT-018 | View > Opacity (10%-90%, Opaque) | No window-opacity control. Preserve accessibility and legibility if added. | Portable feature gap |
| MT-019 | Process > Window > Restore, Minimize, Maximize, Close | Bring to Front exists; the other target-window commands do not. Any native implementation must handle multiple windows, unavailable targets, and Accessibility permission explicitly. | Platform-gated feature gap |
| MT-020 | Process > Create Dump > Minidump / Full Dump | Sample Process saves a 10-second text stack sample, not a memory dump. Investigate an explicit, supported macOS core/diagnostic workflow rather than claiming dump compatibility. | Platform-gated feature gap |
| MT-021 | Process > Debug | No debugger-launch/attach command. A macOS-native debugger workflow requires capability, permission, and signing checks; the Windows AeDebug registration mechanism is not portable. | Platform-gated feature candidate |
| MT-022 | Dynamic DLL / Handle / Thread main menus | Image Properties, Search Online, and Check VirusTotal exist in the image context menu; descriptor details open on double-click. There are no matching lower-pane-specific main-menu groups. Exposing existing safe actions is separate from adding Windows-only control operations. | Menu-discoverability gap |
| MT-023 | Thread menu > Stack / Module and additional thread actions | Thread counters are displayed, but no interactive per-thread stack or module-navigation command is exposed. Assess supported inspection operations first; do not assume Windows thread-token editing or remote termination has a safe public macOS equivalent. | Platform-gated feature candidate |
| MT-024 | Help > Help | The Help menu is explicitly removed and no equivalent product-help command is provided. About and the Sysinternals website remain available; they are not a usage manual. | Portable help-content gap |
| MT-025 | Options > VirusTotal.com; process/image Check/Submit commands | Mac has per-process and per-image hash lookups, but no corresponding global options-level control or executable-upload workflow. Define background lookup, consent, API-key, and rate-limit behavior before adding a global control; evaluate upload separately. The Windows global Submit Unknown command has an unresolved source-ID mismatch, so working automatic submission is not established by this review. | Portable control gap; upload is a separate capability candidate |

**Mac implementation surfaces:** `App/Menus/AppMenus.swift`,
`App/ProcexpApp.swift`, `App/Settings/SettingsView.swift`,
`App/MenuBar/MenuBarController.swift`, `App/MainWindow/MainWindowView.swift`,
`App/MainWindow/ProcessOutlineView.swift`, `App/LowerPane/LowerPaneView.swift`,
`App/Properties/PropertiesTabs.swift`, `App/Actions/ProcessSampleAction.swift`,
`Sources/ProcexpSampling/LibprocDataProvider.swift`.

### Existing equivalents and relocated commands

| Windows menu branch | Mac equivalent or disposition |
|---|---|
| File > Run; Exit | Run is implemented; Quit is in the standard macOS application menu. |
| Options > Verify Image Signatures; Always On Top; Confirm Kill; Theme | Implemented as Verify Image Signatures, Always On Top, Confirm Force Quit, and Light/Dark/System theme choices. |
| Options > Configure Colors; Difference Highlight Duration | Implemented in Settings > Colors and Settings > General rather than the Options menu. |
| View > System Information; Show Process Tree; Show Lower Pane | Implemented. The tree command was changed to a checked tree/flat toggle under MT-004. |
| View > Lower Pane View > DLLs / Handles / Threads | Implemented as Mapped Images / Files, File Descriptors, and Threads. This is native resource terminology, not a missing menu branch. |
| View > Refresh Now; Update Speed | Implemented, including 0.5/1/2/5/10-second refresh choices and pause. |
| View > Select Columns; Save / Load / Organize Column Sets | Implemented for the Mac process list. Do not copy the current Windows dynamic Load Column Set submenu bug described below. |
| Process > Kill; Kill Tree; Restart; Suspend / Resume | Implemented as Force Quit Process, Force Quit Process Tree, Restart, Suspend/Resume. Permissions and process-lifetime checks still apply. |
| Process > Properties; Search Online; Check/Submit to VirusTotal | Properties, Search Online, and hash-based Check VirusTotal exist. Mac has no executable-upload workflow; a hash lookup is not full check/submit parity. See MT-025 and the separate caveat about Windows global Submit Unknown dispatch. |
| Find > Filter Processes; Find Handle or DLL | Implemented, with macOS-native mapped-file/file-descriptor wording. The window-owner picker also exists on the toolbar; it is not a Windows main-menu command. |
| Help > About | About is in the standard macOS application menu. |
| Windows has no main-menu Edit / Window groups | Mac provides native text-editing and app-window menus; these are intentional additions, not parity defects. |

### Windows-specific commands and non-equivalent adaptations

| Windows command | Mac assessment |
|---|---|
| File > Run as Limited User; Run as Administrator / legacy Runas | No direct launch-mode equivalent. macOS account authorization, sandboxing, and elevation differ; the helper does not implement arbitrary alternate-user launches. |
| File > Show Details for All Processes | Helper-backed access is the related Mac capability, configured from the app menu. It is not a literal administrator relaunch and remains unavailable in a plain helper-less development bundle. |
| File > Shutdown > Logoff / Shutdown / Hibernate / Stand By / Lock / Restart | macOS supplies system-session and power controls through its own UI, principally the Apple menu. Windows hibernation and standby states are not exact portable commands; duplicating this File submenu is not automatically required. |
| Options > Replace Task Manager | Windows shell integration; do not claim the helper is an Activity Monitor replacement or equivalent system interception. |
| Process > Set Priority (Windows classes) | Set Nice Value exists, but POSIX nice values are not Windows priority classes, real-time scheduling, QoS, I/O priority, or memory priority. Keep native names and describe the difference. |
| Process > Set Affinity; Efficiency Mode | No equivalent Mac menu. Windows processor affinity and efficiency-mode semantics do not map directly to public macOS per-process controls; avoid fake switches or relabeling nice as QoS/efficiency. |
| Process > Launch Depends | Conditional Windows Dependency Walker integration, not an available Mac menu or required dependency on that tool. A native Mach-O dependency viewer would be a separate feature. |
| Process > Create Dump > Live Kernel Dump (full memory / stacks) | Windows-specific kernel diagnostic API and privilege requirements. Do not expose this as a generic macOS feature. |
| Users > per-session Connect / Disconnect / Logoff / Remote Control / Send Message / Properties | Conditional Windows Terminal Services session-management menu. No like-for-like macOS/RDP session-management requirement. |
| Handle > Close Handle | No Mac command for safely closing arbitrary descriptors inside another process. Descriptor inspection is implemented; Windows remote-handle control is not a promise of portable functionality. |
| Thread > Security / Terminate / Suspend | No equivalent Mac control menus. Windows token/security and remote-thread controls must not be copied without a documented, safe public macOS capability. |

### Windows-source caveats (not parity targets)

- `Highlight Relocated DLLs` is explicitly removed at runtime. The `Temp`
  placeholder is removed, and Trim Working Set insertion is disabled with
  `#if 0`; none is an active feature gap.
- Threads mode currently selects DLL data in the Save writer because it treats
  a three-state lower-pane mode as a Boolean. Do not reproduce this bug.
- Dynamic Load Column Set population uses a submenu index that does not match
  the current menu resource. The handlers and keyboard commands exist, but that
  source path does not prove a populated, working submenu.
- Submit Unknown Executables has a resource/handler command-ID mismatch in the
  inspected source. The option is visible in the resource, but working dispatch
  is not established; do not present unknown-file upload as verified behavior.
- DLL Launch Depends insertion targets an absent resource anchor; only the
  conditional process-level Launch Depends path is established.
- The standalone Processor menu resource and old CPU-fraction/byte-format
  handlers are not additional main-menu commands. Runtime-gated tray, power,
  debugger, affinity, kernel-dump, and Users commands are conditional, not
  guaranteed visible on every Windows installation.

### Windows source references

- [Menu resources and conditional lower-pane menus](https://dev.azure.com/sysinternals/Tools/_git/ProcExp?path=/exe/procexp.rc&version=GCe15d7c9bb0d3a0cc3653b9739fcdfdfcb0aa9400&line=1785&lineEnd=2008&lineStyle=plain&_a=contents)
- [Runtime main-menu construction](https://dev.azure.com/sysinternals/Tools/_git/ProcExp?path=/exe/procexp.cpp&version=GCe15d7c9bb0d3a0cc3653b9739fcdfdfcb0aa9400&line=583&lineEnd=1076&lineStyle=plain&_a=contents)
- [Dynamic lower-pane menu behavior](https://dev.azure.com/sysinternals/Tools/_git/ProcExp?path=/exe/MainFrame.cpp&version=GCe15d7c9bb0d3a0cc3653b9739fcdfdfcb0aa9400&line=170&lineEnd=231&lineStyle=plain&_a=contents)
- [Save/Save As report writer](https://dev.azure.com/sysinternals/Tools/_git/ProcExp?path=/exe/PROCTHRD.CPP&version=GCe15d7c9bb0d3a0cc3653b9739fcdfdfcb0aa9400&line=19857&lineEnd=20030&lineStyle=plain&_a=contents)
- [Pinned Common UTF-8 BOM definition](https://dev.azure.com/sysinternals/Tools/_git/Common?path=/SharedGlobals.h&version=GCa9ad41e79e42b0bfa1856e1e90b10dd1779418a3&line=240&lineEnd=267&lineStyle=plain&_a=contents)
- [Pinned Common tree traversal and collapsed-row handling](https://dev.azure.com/sysinternals/Tools/_git/Common?path=/TreeList.cpp&version=GCa9ad41e79e42b0bfa1856e1e90b10dd1779418a3&line=80&lineEnd=144&lineStyle=plain&_a=contents)

## Native-parity implementation (2026-10-28)

**Scope:** Implement the practical native macOS set without adding Windows-only
or permission-sensitive process controls. The following entries are implemented;
the development app is built and focused native hosted regressions have passed.
Manual retests remain pending.

| Tracking ID | Change |
|---|---|
| MT-006 | File > Save and Save As plus the Save toolbar button share a displayed-report writer. It preserves actual column order, formatted cells, filtering, tree collapse/indentation, offscreen rows and the active lower pane. UTF-8 BOM, tabs, CRLF and section spacing match the Windows text structure. Threads correctly export thread rows. A report is frozen before the save dialog; writes are atomic and only successful writes remember the session destination. Cancellation/failure preserve the old target. Native overwrite confirmation remains enabled. CSV is a separately labeled action and retains its previous all-snapshot/raw-metric behavior. Loading, stale-process or denied lower-pane data produces an explicit error rather than a misleading report. |
| MT-007 | Options > Launch at Login uses `SMAppService.mainApp` with explicit user opt-in. The check state reflects macOS registration/approval state, refreshed on activation, rather than a persisted Boolean. Errors and pending approval are surfaced; no login item is registered merely by launching or testing. |
| MT-011 | Options > Menu Bar Graph and the graph's own menu select CPU, physical memory, I/O, disk, network or GPU history. One icon is displayed at a time; simultaneous independent Windows-style icons remain out of scope. Native sampled histories are reused, percentages use a 0-100 scale, throughput scales to recent values, and missing samples remain unavailable rather than becoming zero. No fake Windows commit metric is added. |
| MT-014 | Persistent Show Column Heatmaps toggle controls column-header and usage-cell shading independently of row-color rules. Default remains enabled. |
| MT-015 | Persistent Scroll to New Processes is off by default. When enabled it expands needed ancestors and reveals the first newly displayed process without selecting it or repeatedly scrolling to unchanged processes. Explicit Find Window reveal takes priority. Native regression exposed AppKit shifting the viewport when the document grows and an initial selection scrolling against a zero-height viewport. Resizing now preserves the viewport across pane extent changes; initial reveals wait for layout instead of scrolling against an unlaid-out view. |
| MT-017 | Persistent Show Processes From All Users defaults to enabled. Turning it off filters by the viewing user's UID, retains own-user children as roots when their parents are excluded, and clears an excluded selection. It does not change sampling privileges. Find Window re-enables all-user visibility when necessary to reveal its target. |
| MT-022 | A shared Lower Pane menu exposes Properties, Search Online, Check VirusTotal and Reveal in Finder for supported selected rows in the active main window. Image actions and descriptor Properties reuse existing behavior; unsupported thread/control commands remain disabled. This is native menu discoverability, not arbitrary descriptor/thread manipulation. |
| MT-024 | Restored Help with a bundled help window and selectable text describing process inspection, saves versus CSV, lower-pane actions, settings, metrics, login items and permission limitations. No network connection is required to read it. |

**Deferred:** Activity recording/review, font and opacity preferences,
hide-on-minimize and instance-policy preferences, unnamed-resource controls,
debugger/dump/symbol workflows, remote-window/thread operations, and global
VirusTotal/background upload policy. Their analysis entries remain open; they
are not advertised as implemented. Standard macOS Edit and Window menus remain.

**Files:** `App/Actions/ProcessReport.swift`, `App/Actions/LoginItemAction.swift`,
`App/AppModel.swift`, `App/AppDependencies.swift`,
`App/MainWindow/MainWindowView.swift`, `App/MainWindow/ProcessOutlineView.swift`,
`App/LowerPane/LowerPaneView.swift`, `App/Menus/AppMenus.swift`,
`App/Menus/LowerPaneMenuActions.swift`, `App/MenuBar/MenuBarMetric.swift`,
`App/MenuBar/MenuBarController.swift`, `App/MenuBar/AppDelegate.swift`,
`App/Settings/SettingsStore.swift`, `App/Help/ProcessExplorerHelpView.swift`,
`App/ProcexpApp.swift`, `ProcexpMac.xcodeproj/project.pbxproj`,
`TestHost/TestHostComposition.swift`, `Tests/AppModelTests/NativeParityTests.swift`,
and the directly affected menu/CSV expectations in `Tests/UITests/`.
The validation scope is also recorded in `docs/TESTING.md`.

**Verification:** On 2026-10-28, 16 native-parity/process-outline tests and 15
related lower-pane/model regressions passed, with zero failures and zero skips.
They cover exact report bytes (including Unicode and embedded delimiters),
frozen capture, Save/Save As destination reuse/cancellation/write failure,
configured native column order and cells for all three lower-pane modes,
stale-lifetime/denied/empty data, filtering/tree collapse, ancestor reveal,
scroll preservation, rendered heatmap changes, persisted preferences,
injected login registration/approval/failure states, native menu captions,
help content and resource-graph scaling/readouts. Existing CSV serialization,
lower-pane details, resource highlighting and process-view regressions passed.

The main development app rebuilt successfully; its strict code-signature check
passed and `CFBundleName` remains `Sysinternals Process Explorer`. Logs:
`build/native-parity-tests-qualified.log`,
`build/native-parity-related-tests.log`,
`build/native-parity-app-qualified.log`. Earlier unsuccessful focused attempts are
retained separately and are not represented as passing runs.

Native UI automation expectations were updated for the new menu captions and
the now-separate CSV action, but the broad UI/coverage campaign was not restarted.
Manual retests should cover the real Save/Save As panels and overwrite/cancel
flows, lower-pane menu actions after changing selection/window focus, view
toggles, each graph choice, and Help. Real launch-at-login activation requires an
installed appropriately signed app plus any macOS approval; only injected
lifecycle behavior was exercised. No real login registration, helper
installation, permission change, external reputation request or process-control
action was performed for this work.
