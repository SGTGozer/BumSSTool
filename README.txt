BUMSSTOOL 1.4.2 - PURPLE EDITION
by SGTGozer
Minecraft screenshare toolkit for Windows 10 / Windows 11 x64

START
1. Extract the complete ZIP to a folder.
2. Double-click bumsstool.exe (the purple R34-style car icon).
3. Click a tool card. Missing tools download and extract automatically, then
   open. Downloaded tools are checked for missing prerequisites, then opened.
4. Right-click a card (or press Shift+Enter) for extra launch options. Close
   these controls with the X, Escape or a click outside the panel.

No Python, Visual Studio or extra PowerShell installation is needed for the
launcher. It uses the 64-bit Windows PowerShell included with Windows.
Missing .NET runtimes and imported Visual C++ libraries are detected before
launch. Their official, signature-checked Microsoft installers run automatically
when needed. Windows may ask for administrator approval (UAC). Java tools can
use a private Temurin Java runtime prepared by bumsstool. The Dependencies
category remains available for manual setup.

If the EXE cannot open, run Start-bumsstool.cmd. It opens the same application
with a console so startup errors remain visible. The complete folder is
required; do not move only bumsstool.exe away from the other files.
The launcher is unsigned.

WHAT IS INCLUDED
All 77 entry names from cheesecatlol/CheesySSTool are retained, plus P1AE
Javaw Scanner: 78 entries (75 tools and three dependency entries). This is an independently written launcher, with
its own interface, downloader and car icon. Third-party utilities are fetched
on demand from their author or publisher; their binaries are not bundled.

- Purple card layout with a custom title bar and an R34-style symbol car.
- Animated symbol car with gentle idle movement and pulsing purple headlights.
- Slim rounded purple scrollbars with hover and drag colors.
- Browse author tabs across the top or search tool names and descriptions.
- Search filters cached cards after a short typing delay; it does not read
  installation records or scan downloaded folders on each keystroke.
- Favorite frequently used entries; see downloaded tools in one view.
- Download Windows releases in the background, with progress and cancellation.
- Click several missing tools to queue installs. Cancel download also clears
  queued installs. Failed or cancelled downloads never automatically open.
- Run downloaded EXEs, PowerShell scripts, batch files, Java JARs and installers.
- Repair unsigned UTF-8 PowerShell files for Windows PowerShell 5.1, including
  previously cached downloads. Script modules and manifests are covered too.
- Prepare UTF-8 console input/output so Unicode tool banners stay readable.
- Parse PowerShell launch files before opening them; report any remaining
  syntax error with its filename and line number.
- Choose a launch file when a package contains multiple applications.
- Supply command-line arguments; keep CLI output in an open console.
- Tools that read protected live system records request administrator access
  automatically, using standard Windows UAC. The optional checkbox also allows
  you to request elevation for another tool.
- Open the author Source page, a tool folder or CMD in the install folder.
- Clear only tools downloaded by bumsstool; app files and logs are kept.
- Export the launcher session log as text. Actual startup state and child exit
  codes are tracked; GUI output and startup errors are written to launch logs.

A WEBSITE entry opens its publisher page; install the product from there.
Card clicks install and open tools automatically. Dependencies open their normal
installer UI; follow its prompts. In the optional right-click controls, Download
installs without opening and Run tool launches your selected file and arguments.
Use tools on computers whose owner has agreed to the screenshare.
Findings require manual review; bumsstool does not make an automatic ban decision.

SOURCE CORRECTIONS / AVAILABILITY
- MeowModAnalyzer: the author publishes UTF-8 without an encoding marker.
  Windows PowerShell 5.1 otherwise reads it as a legacy code page, corrupting
  Unicode box-drawing text and even terminating quoted strings incorrectly.
  The source audit reproduced 118 parse errors under Windows-1252 and zero
  under UTF-8. bumsstool adds a UTF-8 BOM without changing any source bytes
  after it. The same problem appeared in CommonDirectories, Services and
  DQRKIS-FUCKER. This repair applies to cached copies as well as new downloads.
- Javaw Scanner: added the P1AE Windows x64 application from p1aegg/javaw.
  It appears under Others; search javaw to find it. Minecraft should be
  running before scanning. Uses standard UAC for reading process memory.
  Audited release: v1.12, publisher SHA-256 verified without executing it.

The catalog was checked on 2026-10-09 against source commit:
0c42549922f827d22da5284fa169c34bbccf3040
https://github.com/cheesecatlol/CheesySSTool

- PSHunter, AltDetector and WeHateFakers: the original author repositories
  currently return HTTP 404. Their entries remain visible and are marked
  Check source. Download retries the original source if it is restored.
  These three utilities cannot currently be obtained from those sources.
- SignedScheduledTasks: corrected to the author's actual extensionless
  Signed-Scheduled-Tasks file; it is saved locally with a .ps1 extension.
- ComputerActivityView: the referenced NirSoft page provides LastActivityView.
  Download uses that page's verified lastactivityview.zip link.
- DIE-engine: download uses the Detect It Easy Windows application, which
  uses the DIE engine. It selects the x64 portable application release,
  rather than the separate signature-database releases.
- NET 9.0 / NET 10.0: replaced expired hard-coded installer addresses with
  Microsoft's current release metadata. NET 9 provides the SDK; NET 10
  provides the Desktop Runtime (including the .NET runtime).
- Velociraptor: downloads the portable Windows executable in .exe.gz form,
  rather than selecting the endpoint-service MSI installer. The default gui
  argument opens its local browser interface; the console remains open.
- Luyten: selects the official JAR and runs it with Java, avoiding an old EXE
  wrapper that can fail to find Java. Existing EXE-only downloads are refreshed.
- BAM-parser, JournalTrace, Espouken Tool and NTFS Parser: select their normal
  application binaries rather than debug or alternate utility variants.
- Runtime checks use the actual executable architecture and runtimeconfig,
  including embedded configuration in framework-dependent single-file apps.
  Unsupported ARM downloads and corrupt EXEs are rejected with a clear error.

THIRD-PARTY TOOLS
Author-maintained utilities have their own licenses, prerequisites and
behavior. bumsstool downloads their published files; it does not reproduce
or own those utilities. Source buttons link to their publishers.
The launcher has no reporting server, webhook or automatic upload of findings.
Utilities you run can have their own networking and data-access behavior.
Session-log export records launcher actions and error/log locations. GUI tool
output is captured in launch logs; interactive console output stays in its
visible console window.

LOCAL FILES
Downloaded tools, favorites and launcher logs are stored under:
%LOCALAPPDATA%\bumsstool
A new download is committed only after a complete transfer and extraction.
Failed downloads preserve the previous tool record. SHA-256 is recorded for
each download. Published GitHub SHA-256 / Microsoft SHA-512 hashes are checked
when available; a locally calculated hash alone is not proof of publisher trust.
The tool folder keeps previous version folders until Clear downloads is used.
PowerShell preparation adds only a UTF-8 BOM to valid unsigned UTF-8 scripts;
UTF-16/UTF-32, legacy ANSI and signed files are preserved. The recorded download
hash identifies the original publisher asset, before encoding preparation.

EDIT / REBUILD
The full source is included:
- tools.json                 Tool catalog and verified source links
- bumsstool.ps1              WPF interface and application events
- src\Core.ps1              Download, extraction, filtering and launch logic
- src\ViewModel.ps1         Cached card data and install queue
- src\Launch.ps1            PE metadata, launch profiles and command planning
- src\Prerequisites.ps1     Automatic runtime checks and publisher setup
- src\Run-Tool.ps1          Process supervisor, startup state and error logs
- src\Main.xaml             Interface layout
- src\Launcher.cs           Windows EXE launcher source
- assets\car.txt            Editable car artwork made from text symbols
- assets\car.png/.ico       App icon, including multiple Windows icon sizes

Edit tools.json to add a catalog entry with a unique ID. Kind must be one of:
GitHub, Direct, Script, Website, DotNet. Use HTTPS source URLs. Press Refresh
catalog after saving. JSON names and descriptions can be edited without
rebuilding the EXE.

Build-launcher.cmd recompiles the launcher using the .NET Framework compiler
provided with standard Windows installations. It is optional: the compiled
bumsstool.exe is already included. Close the app before rebuilding.

UPDATING / TROUBLESHOOTING
Extract the complete new ZIP into a new folder and launch its bumsstool.exe.
Your downloaded tools and favorites are reused from %LOCALAPPDATA%\bumsstool.
Close an old failing tool console, then click its card in the new launcher.
Cached script encoding repairs automatically. You do not need to clear all
downloads or manually edit MeowModAnalyzer. Click a card to repair missing runtimes
or stale launch files. Standard UAC prompts still apply to system setup and
protected tools. Cancelling during a system installer waits for that installer
to finish, then prevents the tool from opening.

If a utility still fails, the main status and session log show its exit code
and log path. Open install folder, then launch-logs, for the corresponding
.txt file. A command-line utility may need a file path or flags: right-click
its card and enter them. Its console stays open to show usage and errors.
A zero exit code only means the process exited normally; it does not establish
that a tool produced useful findings. Upstream program bugs and offline
publisher sources are not repaired by this launcher.

VERIFICATION
The launcher compiled as a Windows x64 GUI executable with embedded car icon.
Automated core and application checks cover catalog completeness, release selection, search,
favorites, ZIP traversal rejection, GZip extraction, cancellation, console
recognition, atomic state writes and failed-download rollback. Application
fixtures also check direct installation, queue order, duplicate clicks, cached
search without disk reads, captured launch targets and cancellation behavior.
Launch fixtures verify PE architecture/imports, .NET requirements, stale
install repair, Java selection, argument quoting, and prerequisite preparation
for both cached and new downloads. The actual supervisor was executed against
our own probe, with success and failure exit codes plus simultaneous stdout
and stderr. No downloaded publisher utility was executed.
The included Check-bumsstool.cmd also instantiates the WPF layout and loads the
icon on Windows without executing any downloaded third-party utility.
All seven currently available publisher scripts were audited and parsed after
encoding preparation, without executing them. Script tests reproduce the
Windows-1252 failure and check fresh downloads, cached repair, original bytes,
signatures, legacy encodings and cancellation.
Native Windows GUI and third-party program execution were not tested in the
Linux build environment. This package does not claim every upstream utility
was executed or every external provider will remain online.
