# Windows Debloat Studio

A Windows 11 desktop app for reviewing, applying and **reversing** the telemetry,
advertising, preinstalled apps, services, scheduled tasks and shell behaviour that
ship with Windows.

**[User guide](https://windowsdebloat.wndtech.tips/guide.html)** &middot;
**[Download](https://github.com/WnDTech/Windows-Debloat-Studio/releases/tag/v1.0.0)** &middot;
**[Website](https://windowsdebloat.wndtech.tips)**

355 options across 16 categories. Every option has its own explanation, a risk
label, the live state read from your machine, and three choices: **Enable**,
**Disable**, **Revert**. Nothing is selected when the app opens, and nothing is
applied until you press *Review & apply* and confirm.

Free software under the **GPL-3.0**. That is not incidental to what this is: a
tool that rewrites your registry, disables services and removes packages while
running as administrator should be one you can read before you trust it. The
whole thing is PowerShell and XAML — no compiled logic, nothing obfuscated.

---

## Running it

**As a user:** double-click **`WindowsDebloatStudio.exe`**.

That exe is the whole download, around 210 KB. It carries the app's PowerShell,
XAML and catalogue as one compressed resource, unpacks them into a temporary
folder, runs them, and deletes the folder when you close the window. Nothing is
installed. Its manifest requests administrator, so the elevation prompt names
*Windows Debloat Studio* rather than asking you to approve *Windows PowerShell*.

The exe is not code-signed yet, so SmartScreen will show *"Windows protected your
PC"* on first run. The download page carries a SHA-256 to check against before
clicking through it.

**As a developer:** double-click **`Windows Debloat Studio.cmd`**, which starts
Windows PowerShell in a single-threaded apartment (required by WPF) and lets
`Debloat.ps1` ask for elevation itself.

By hand:

```powershell
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "Debloat.ps1"
```

Useful switches:

| Switch | What it does | Tier |
|---|---|---|
| `--help` | Print the switches and exit. | free |
| `--validate` | Print the catalogue and preset summary and exit. No window, no changes. | free |
| `--noelevate` | Skip the elevation prompt. Per-user options still work. | free |
| `--apply <preset.json>` | Apply a preset with no window, then exit. | Technician |
| `--dry-run` | With `--apply`: walk the preset and report, changing nothing. | Technician |
| `--report <out.html>` | Write a hand-over report of every change made to this PC. | Technician |

Exit codes: `0` done, `2` not licensed for that, `3` bad input, `4` something failed.

### Scripting the unattended mode

The exe is a **windowed** program, so a shell does not wait for it and will not
hand back its exit code. That is a property of the Windows subsystem field, not
something the app can decide — a single executable is either console or windowed,
and a console one would flash a black window at every GUI user. So wait for it
explicitly:

```powershell
$p = Start-Process .\WindowsDebloatStudio.exe -Wait -PassThru -NoNewWindow `
        -ArgumentList '--apply', 'build.json'
$p.ExitCode
```

Add `-RedirectStandardOutput log.txt` to capture what it did. From `cmd`:

```
start /wait "" WindowsDebloatStudio.exe --apply build.json
```

Two things worth knowing. **Run it from an already-elevated context** — a
deployment script, or SYSTEM during imaging. The manifest requests administrator,
so from an unelevated prompt it raises a UAC dialog, which is not what you want
on thirty machines. And **`--dry-run` first**: it resolves the preset, walks every
action and reports exactly what a real run would do, without writing anything or
journalling anything.

A path containing `;` `|` `&` `` ` `` or a quote is refused rather than passed
through, and refusing exits `3` without launching anything — an earlier version
dropped the bad value instead, which meant the app quietly opened a window and a
deployment script reported success having applied nothing.

**Requirements:** Windows 11 (the catalogue targets it; options that do not apply
show as *Unknown*), Windows PowerShell 5.1, and .NET Framework 4.x — all present
on a stock install. Nothing is downloaded and nothing is installed. On first run
the app compiles `src/Interop/Interop.cs` into
`%LOCALAPPDATA%\WindowsDebloatStudio\bin\DebloatInterop.dll`, which takes a
second or two; later runs reuse it.

### Where it keeps things

Nothing is written into the app folder, because in the packaged build that folder
is a temporary directory that only exists while the app is running. State is
split by what each part needs:

| Location | Holds | Why there |
|---|---|---|
| `%ProgramData%\WindowsDebloatStudio\` | `journal.jsonl`, `license.json` | Machine-wide. The app always runs elevated, and if the signed-in user is not an administrator, elevation switches profile — a per-user journal would land under whichever admin approved the prompt, and a later unelevated run would report nothing to undo while the changes were still in force. Locked to administrators for writing, readable by everyone. |
| `%LOCALAPPDATA%\WindowsDebloatStudio\` | `bin\`, `logs\`, `presets\` | Per-user, and writable without elevation. Presets live here, not with the machine state: a folder hardened against non-admin writes would make saving a preset require elevation, which is absurd for something the user typed, and there is nothing to protect — a preset can only hold option ids and the words Enable, Disable or Revert. The compiled assembly especially: it is loaded into an elevated process, and ProgramData is writable by any ordinary user by default, so caching executable code there would let a standard user hand code to an administrator. |

A pre-1.0 install that kept state inside the app folder is migrated on first run,
copying before it moves anything aside.

---

## The Start here dashboard

The first page is a dashboard rather than prose, because the app is sitting on
data worth showing: how big the catalogue is, how it splits by risk, how much of
your machine is already switched off, and how much this app has touched.

Three forms, each with one job:

- **A stat-tile row** for the headline numbers. A single number is a stat tile,
  not a one-bar chart, and exactly one of them is a hero figure.
- **One stacked bar** for the risk mix. Risk is an ordered *status* scale, so it
  wears reserved status steps and never series colours, every segment is
  labelled, and a 2px gap in the surface colour separates the segments instead of
  a border.
- **One bar per category** for how much of it is already off. These are nominal
  categories and the bar length already encodes the value, so every bar takes the
  *same* hue rather than being coloured by its own value. One series, so no
  legend — the panel title names it. Click any row to jump to that category.

Bars are built as two star-width grid columns, so they stay true at any window
size without a line of layout code.

### The colours were computed, not chosen

Risk colours are the one place this app uses colour to carry meaning, so they
were measured rather than eyeballed. The originals were bright and looked fine —
but under simulated protanopia the safe/moderate pair separated by only
**ΔE 7.1**, inside the band where a red-green colourblind reader struggles. The
reserved status steps now in use measure **ΔE 11.3** on the same surface, with
every other check passing:

| | contrast on the card surface |
|---|---|
| series blue (category bars) | 4.82:1 |
| status good / warning / critical | 5.23 / 9.56 / 3.65:1 |
| bar track | 2.17:1 (carries no value; only needs to read as an empty channel) |

Risk is never colour alone anywhere in the app — every chip, stripe and segment
carries its label too.

### Two things that got cut or fixed by looking at the render

- A coverage meter under each rail category **was built and then removed.** At
  3px in a narrow nav list, blue-on-blue read as an underline rather than a
  proportion — it added ink that looked like a border. The dashboard chart does
  that job properly, so the rail went back to one compact row.
- The expand animation originally rested at `Opacity="0"` and animated *to* 1. If
  the storyboard never ran, the panel was invisible. It now animates **from**
  transparent, so the resting state is visible content and a missed animation
  costs nothing.

---

## How the three choices work

The buttons describe **the Windows feature**, not the tweak. This matters,
because it means the same word always points the same way.

| | |
|---|---|
| **Enable** | The feature is on. For most options this is the state Windows ships in. |
| **Disable** | The feature is off. For most options this is the debloating direction — but not all: a handful of options are things Windows ships *turned off* that you may well want on (End Task on the taskbar, long path support, LSA protection, Windows Sandbox), and those cards say so explicitly. |
| **Revert** | Put the option back to the exact value it had **before this app first changed it**, read from the journal. If the app has never touched that option, Revert is skipped rather than guessing at a default. |

Each card carries three colour-coded panels spelling out what Enable, Disable and
Revert will each do to that specific option, plus a *Technical detail* block
listing the exact registry values, services, packages or tasks involved.

### Risk labels

| Label | Meaning |
|---|---|
| **Safe** | Reversible, no functional loss for most people. |
| **Moderate** | A real feature changes or disappears. The card names it. |
| **Aggressive** | Can break Windows Update, security, or app installation. The card explains the specific danger. |

The toolbar filters by risk, so you can hide everything aggressive while you work.

---

## The safety net

This is the part worth understanding before you change anything.

**The journal.** Before each individual action, the app captures the current
state — the registry value and its type, the service start type and running
state, which app packages are installed and where their payload lives, whether a
scheduled task is enabled — and appends it as one line to
`%ProgramData%\WindowsDebloatStudio\journal.jsonl`. That single file backs both *Revert* on one option and
*Undo all changes* in the footer.

**Revert** uses the **oldest** capture recorded for an option, not the most
recent. So if you disable something, later re-enable it, then Revert, you land
back on the value the machine had before this app ever ran.

**Undo everything** replays the whole journal, restoring each option's earliest
recorded state, then archives the journal alongside it as
`journal-undone-<timestamp>.jsonl`. It survives closing the app, so you can
undo tomorrow, or after a reboot.

**System Restore** is offered on the confirmation screen and from the sidebar at
any time. It needs System Protection turned on for the system drive; if it is
off, the app tells you rather than failing quietly.

**Dry run.** The confirmation screen has a *Dry run* box. Ticked, the app walks
your whole selection and writes the complete log of what it *would* do —
including which profiles each per-user value would land in — while touching
nothing. No registry value, service, app, task or journal entry. It is a separate
describe-only code path rather than the real apply with writes skipped, so there
is no conditional anywhere that could be got wrong and let a change through. Your
selections stay staged afterwards, so you can read the log and then apply for
real.

**Stopping part way.** Apply and undo both have a *Stop* button. It takes effect
between options, never part way through one, so the journal never ends up
describing a half-applied change and *Undo everything* still puts back whatever
did get applied. Options that were never started stay staged. A stopped undo
keeps its journal whole rather than trimming it, so pressing *Undo everything*
again simply finishes the job.

**What cannot be undone.** Two things, and both say so on the card:

- The cleanup options in *Advanced & Housekeeping* delete data — temp files,
  `Windows.old`, event logs, the component store's superseded versions. Gone is
  gone.
- Removing an app package can only be undone locally while its payload is still
  in `WindowsApps`. Where it is not, the log tells you which apps to reinstall
  from the Microsoft Store.

---

## Applying to every account

`HKCU` options only ever affect the account running the app, which is why a
debloated machine can look untouched to the next person who signs in. Tick
**Apply per-user options to all accounts** on the confirmation screen and the app
also writes them into:

- every real user profile on the PC, by loading its `NTUSER.DAT`
- the **default profile**, so accounts created later inherit the settings

Hives are mounted once at the start of an apply and unmounted at the end, rather
than per option. Each profile is captured **separately**, so *Undo everything*
puts them back one at a time — and because each capture records the profile's SID
and the path to its `NTUSER.DAT`, an undo can find that profile again later, even
after a reboot when nothing is mounted.

Needs administrator rights. The checkbox explains itself and disables when there
is nothing to do: not elevated, no other profiles, or no per-user options staged.
Machine-wide `HKLM` options are unaffected — they already cover everybody.

The refresh button in the title bar re-reads the live state of every option from
the machine, discarding everything cached. Use it if you changed something in
Settings while the app was open. Staged selections are kept.

---

## Reinstalling apps that were removed

Removing an app package can normally only be undone while its payload is still in
`WindowsApps`. Once Windows has cleaned that up, the Store is the only way back,
and the app can drive it with winget.

The order tried, on both *Enable* and *Revert*:

1. re-register from the exact folder recorded in the capture
2. re-register from whatever matching payload is still in `WindowsApps`
3. install from the Store with winget
4. failing all that, log a clickable `ms-windows-store://` link

Step 3 is where care was needed. A Store product id is just data in the
catalogue, and a wrong one would install **the wrong application**. So nothing is
ever installed on the strength of an id alone: winget is asked to *describe* the
package first, and the install only proceeds if the name it reports back matches
what the catalogue expected. A bad id therefore produces a clear refusal naming
what it actually found, rather than a silent mis-install. An id with no expected
name recorded is refused outright.

36 packages currently carry a verified Store id. The rest fall through to the
Store link, which is honest about what it can and cannot do.

---

## Presets

A preset is a named set of choices. **Staging a preset ticks Enable, Disable or
Revert on the options it covers and leaves everything else untouched.** It never
applies anything on its own — you then walk the categories, change your mind on
anything you disagree with, and only then press *Review & apply*.

Fourteen presets ship with the app:

| Preset | Risk | What it is for |
|---|---|---|
| **Privacy Essentials** | Safe | Data collection and advertising surfaces off, nothing else touched. Start here. |
| **Windows 10 Feel** | Safe | Interface only — classic context menu, left taskbar, file extensions, This PC. |
| **Put Everything Back** | Safe | Stages Revert on all 355 options — the reviewable alternative to the Undo button. |
| **Recommended Desktop** | Moderate | The full sensible pass for a personal desktop. |
| **Gaming Rig** | Moderate | Latency and frame-pacing work for a desktop. Keeps the Xbox sign-in broker and anti-cheat requirements intact. |
| **Laptop & Battery** | Safe | Privacy pass with the power-hungry tweaks deliberately left out. |
| **Security Hardening** | Moderate | Mostly uses **Enable**. Closes legacy protocols, turns on protections Windows leaves off. |
| **Developer Workstation** | Moderate | Long paths, dev mode, Sandbox, WSL on; keeps Terminal, Store and WebView2. |
| **Shared or Family PC** | Safe | Marketing and remote-access tools gone, every protection left on. |
| **Quiet Machine** | Safe | Every prompt, banner, tip and nag removed. Everything stays functional. |
| **Maximum Debloat** | Aggressive | Everything safe and moderate. Carries a warning listing what stops working. |
| **Corporate Build** | Technician | Locked-down corporate desktop. Telemetry off, consumer features off, Defender and update ON. |
| **Kiosk & Shared Terminal** | Technician | Aggressive lockdown for shared machines. All preinstalled apps removed, personalisation closed. |
| **Client Hand-off** | Technician | Prepares a machine before giving it to a client. Clean slate, no leftover settings. |

### Sharing presets

*Save as preset…* writes a `.json` file into `presets/`. Send that file to
someone; they use *Import a preset file…* and get exactly your choices.

A preset contains **only option ids and the word Enable, Disable or Revert**:

```json
{
  "schema": "debloat-preset/1",
  "name": "My office build",
  "selections": {
    "ads.cdm.master": "Disable",
    "priv.diagtrack": "Disable",
    "ui.taskbar.endtask": "Enable"
  }
}
```

It cannot carry a registry path, a command, or anything else executable. Importing
a preset a stranger sent you can only ever set choices you could have set by hand,
and you still see the full list on the confirmation screen before anything runs.

The built-in presets may additionally use **rules** (`categories`, `risk`, `tags`,
`excludeIds`) so they stay complete as the catalogue grows. Presets you save are
always an explicit list.

---

## The categories

| Category | Options | What is in it |
|---|---|---|
| Privacy & Telemetry | 28 | Diagnostic data, DiagTrack, advertising ID, activity history, location, error reporting, CEIP, Edge and Office telemetry |
| Ads, Tips & Suggestions | 19 | Content Delivery Manager, Spotlight, Start recommendations, search highlights, Explorer ad banner, SCOOBE |
| Copilot, Recall & AI | 13 | Copilot, Recall, Click to Do, AI in Paint / Notepad / Photos, Cortana, voice activation |
| Preinstalled Apps | 51 | Every removable Store app, plus OEM and sponsored bundles, codec extensions and Edge itself |
| Taskbar, Start & Explorer | 34 | Alignment, Widgets, Chat, classic context menu, file extensions, animations, snap, AutoPlay |
| Background Services | 44 | SysMain, Search, Spooler, Xbox, Delivery Optimization, Bluetooth, discovery, WinRM, SNMP, smart card, legacy protocols |
| Scheduled Tasks | 22 | Compatibility Appraiser, CEIP, error reporting, Office, Xbox, vendor updaters, update orchestrator, diagnostics |
| Windows Update & Store | 15 | Deferrals, driver updates, restart behaviour, active hours, reserved storage |
| Performance & Gaming | 22 | Game DVR, HAGS, power plan, Nagle, core parking, VBS, CPU mitigations |
| Security & Defender | 25 | SMBv1, LLMNR, PowerShell 2.0, SmartScreen, UAC, LSA protection, ASR rules, RDP, TLS |
| Network & Sharing | 16 | DoH, Teredo, discovery, SMB server, hotspot, WPAD, IPv6 |
| Microsoft Edge | 16 | New tab feed, sidebar, sync, startup boost, background mode, tracking prevention, IE mode |
| Windows Features | 25 | Optional features and on-demand capabilities via DISM |
| OneDrive & Cloud Sync | 8 | Known-folder redirection, Files On-Demand, uninstall — in the order that avoids losing files |
| Advanced & Housekeeping | 6 | Component store, boot menu, crash dumps, start-up entries |
| Cleanup & Disk Space | 11 | Temporary files, old updates, caches, event logs, hibernation — permanently deletes data that Revert cannot undo |

The **OneDrive** category is deliberately ordered. Windows silently redirects
Desktop, Documents and Pictures into OneDrive during setup, which is why removing
the client can look like it deleted someone's files. Work down that category in
order and read the first card before the last.

---

## Project layout

```
Debloat.ps1                     entry point: elevation, STA, module loading
Windows Debloat Studio.cmd      launcher, for running from source
src/
  Bootstrap/Bootstrap.cs        the downloadable exe: unpacks payload, runs, cleans up
  Bootstrap/app.manifest        requests administrator so UAC names the app
  Gui/Theme.xaml                design system: palette, type, control styles
  Gui/MainWindow.xaml           window, item templates, overlays
  Interop/Interop.cs            view-models (INotifyPropertyChanged) + converters
  Modules/Core.ps1              paths, logging, elevation, restore points
  Modules/Engine.ps1            read / apply / capture / restore for all 7 action kinds
  Modules/Journal.ps1           the undo journal
  Modules/Catalog.ps1           loads data/catalog/*.json into view-models
  Modules/Presets.ps1           built-in and user presets
  Modules/License.ps1           Polar licence keys, offline-first entitlement
  Modules/Ui.ps1               wiring, filtering, apply and undo flows
data/
  catalog/*.json                the 355 options, one file per category
  presets.json                  the 11 built-in presets
assets/app.ico                  app icon, drawn by tools/New-AppIcon.ps1
dist/                           built exe and its .sha256 (generated)
tools/                          validation, audit, tests, icon and exe build
site/                           the marketing page
```

State lives outside the tree — see *Where it keeps things* above.

### Action kinds

The engine is data-driven. A catalogue entry lists actions, and each action is one
of seven kinds — all seven implement read-state, capture, apply and restore:

`reg` · `service` · `appx` · `task` · `feature` · `capability` · `command`

The current catalogue uses 426 registry values, 82 service changes, 51 app package
groups, 26 probed commands, 23 task groups, 19 optional features and 13
capabilities.

### Adding an option

Add an entry to the relevant file in `data/catalog/`, then run the validator:

```bash
python3 tools/Validate-Catalog.py
```

It checks ids are unique, every required field is present, hives and value types
are valid, task paths are absolute, and — importantly — that no action has the
same value for `enable` and `disable`, which would make its state unreadable. It
also warns when two options write the same registry value, which is sometimes
deliberate (a master switch plus a granular one) and sometimes a mistake.

---

## Tests

```powershell
powershell -STA -ExecutionPolicy Bypass -File tools\Test-Ui.ps1        # XAML, bindings, filtering, presets
powershell      -ExecutionPolicy Bypass -File tools\Test-Engine.ps1    # capture -> apply -> revert -> undo
powershell      -ExecutionPolicy Bypass -File tools\Test-License.ps1   # entitlement, offline grace, gating
powershell      -ExecutionPolicy Bypass -File tools\Audit-Catalog.ps1  # every identifier vs this machine
powershell -STA -ExecutionPolicy Bypass -File tools\Test-Package.ps1   # what is actually inside the exe
powershell -STA -ExecutionPolicy Bypass -File tools\Test-Tiers.ps1     # tier separation, unattended apply, report
powershell      -ExecutionPolicy Bypass -File tools\Diagnose.ps1       # when it will not start: says why
powershell -STA -ExecutionPolicy Bypass -File tools\Export-Screens.ps1 # renders every screen to tools\screens\
python3 tools\Validate-Catalog.py                                      # catalogue integrity
```

## Building the download

```powershell
powershell -ExecutionPolicy Bypass -File tools\Build-Exe.ps1           # -> dist\WindowsDebloatStudio.exe
powershell -ExecutionPolicy Bypass -File tools\Build-Exe.ps1 -Sign     # once a certificate exists
```

The build needs nothing installed. It uses the C# compiler that ships with the
.NET Framework already in Windows (`csc.exe`) — the same compiler the app uses at
runtime for its view-models — so a stock Windows 11 box can produce the release
with no SDK, no MSBuild and no package restore.

The payload list in `Build-Exe.ps1` is written out explicitly rather than swept
from the folder, so a stray file in the working tree cannot end up in a
customer's download. `tools\New-AppIcon.ps1` draws `assets\app.ico` from code
(the same mark as the site's logo) so the icon is reproducible from source.

`Test-Package.ps1` is the interesting half. It reads the payload back out of the
built exe and checks the *negative* cases, which running the app cannot reveal:
that no `tools\`, `site\`, `logs\` or compiled binary is inside; that this
machine's user name and build path appear nowhere in it; that the shipped licence
config carries no key or activation; and that file timestamps survived — without
which the app would recompile its view-models on every single launch.

### Signing

There is no free code-signing certificate that Windows trusts. A self-signed one
does nothing for SmartScreen; it only helps if every user installs the root,
which nobody should do.

Going open source opens the free route, but it is **not** a solved problem for
this project. [SignPath Foundation's conditions](https://signpath.org/terms.html)
say, verbatim:

- *"The project must use an OSI-approved Open Source license without commercial
  dual-licensing for all components."*
- *"The project may not contain any proprietary, non open-source component."*
- *"The project must already be released in the form that should be signed."*
- *"The project must not contain malware or potentially unwanted programs."*
- *"The code signing certificate is issued to SignPath Foundation. This means
  that SignPath Foundation is the publisher of the OSS project."*

Four consequences worth being clear-eyed about:

1. **A public release has to exist first.** This is not something to apply for
   before shipping.
2. **The publisher shown to users would be SignPath Foundation, not WndTech.**
   For a product with a brand attached, that is a genuine cost.
3. **A paid, server-delivered catalogue may disqualify the project**, because it
   is arguably the "proprietary, non open-source component" that clause excludes.
   The open-source route and the sell-the-catalogue model may not be compatible;
   selling convenience features inside the GPL code is the safer reading.
4. **A debloater invites scrutiny under the PUP clause**, since the catalogue can
   disable SmartScreen and Defender. It is a human review, not a checkbox.

The paid alternatives, for comparison:

| Route | Cost | Publisher shown | Catch |
|---|---|---|---|
| SignPath Foundation | free | SignPath Foundation | conditions above; needs an existing release |
| Certum open source | ~€25/year | you | open source only |
| Azure Trusted Signing | ~$10/month | you | needs a verified legal entity |
| OV certificate | ~£200/year | you | SmartScreen reputation still builds slowly |
| EV certificate | ~£300+/year | you | trusted by SmartScreen immediately |

Whichever is used, fill in `Invoke-SignExe` in `Build-Exe.ps1` and pass `-Sign`,
or wire the CI step. Timestamping is not optional: without it every signature
stops validating the day the certificate expires, including on copies already
downloaded.

Worth knowing regardless of signing: a PowerShell payload inside an exe that then
rewrites the registry and stops services is, to a heuristic scanner, the profile
of a dropper. That is why the payload is compressed but never packed or
obfuscated, and why it unpacks to a named folder rather than hiding in Temp.

`Audit-Catalog.ps1` catches the one failure mode a schema check cannot see: an
identifier that is simply **spelled wrong**. A misspelled service, task, feature
or registry path makes an option quietly do nothing for ever, and on screen it is
indistinguishable from an option that legitimately does not apply to this PC.

It cross-checks all 425 registry paths, 83 service names, 89 task paths, every app
package and — when elevated — every optional feature and capability against what
is actually on the machine, then splits the findings three ways:

- **OK** — found
- **ABSENT** — not found, but expected: group policy keys do not exist until they
  are set, and a long list of services and tasks have been removed from current
  Windows 11 builds while remaining correct for Windows 10
- **SUSPECT** — not found where it really should be

Every expected case is baselined in the script with a reason, so the suspect list
stays near-empty and a real mistake stands out immediately. It currently reports
**no suspects**. Re-run it after adding options.

Three genuine catalogue bugs came out of writing it:

| Found | Fix |
|---|---|
| `TabletInputService` does not exist on Windows 11 — it was renamed | Also sets `TextInputManagementService`, so the option works on both |
| `InstallService\SmartRetry` was replaced by `RestoreDevice` | Added, so the option covers current builds |
| One AI option targeted an `en-US`-only registry path | Dropped; the remaining actions cover the feature in any language |

`Test-Engine.ps1` is the important one (40 checks). It exercises the full round trip against
harmless per-user registry options in an **isolated journal**, and asserts that
Revert uses the oldest capture, that the journal survives being reloaded from
disk, and that every value is restored exactly. It also captures and
JSON-round-trips all 573 actions in the catalogue to prove none of them can throw
mid-apply.

It also proves the dry run is inert: it runs every action in the catalogue in
both directions — 1,652 described changes — and asserts the registry is untouched
and no journal entry was written. It checks the Store reinstall guard accepts a
matching id, refuses a real id with the wrong expected name, refuses an unknown
id, and refuses to install blind when no expected name is recorded. And it exercises the multi-profile write path
end to end against a second, genuinely separate hive, checking the value lands in
both and that an undo rebuilt from JSON, with the session torn down, restores
both exactly. `reg.exe load` itself only runs when the test is elevated; without
elevation that one step reports as skipped.

`Export-Screens.ps1` shows the window off-screen and renders it with
`RenderTargetBitmap`, so it produces real screenshots of every view and dialog
without needing an interactive desktop.

---

## Licensing

Licensing runs against [Polar](https://polar.sh)'s license-key API. Two values
in `data/licensing.json` make it live:

```json
{ "organizationId": "<Polar > Settings > General > Organization ID>",
  "checkout": { "pro": "<checkout link>", "technician": "<checkout link>" } }
```

Optionally map each product's *License Keys* benefit id onto a tier so the app
can tell a Pro key from a Technician one. Leave `benefitIds` empty and any valid
key for the organisation grants Pro.

**Until `organizationId` is set the app stays on Free and makes no network call
at all** — which is also true of every free install, permanently.

### The three tiers

| | Free | Pro | Technician |
|---|---|---|---|
| All 355 options, all 15 categories | yes | yes | yes |
| Journal, Revert, Undo everything, dry run, restore point | yes | yes | yes |
| Starter presets | 3 | 3 | 3 |
| The 8 advanced curated presets | &mdash; | yes | yes |
| Save / export / import your own presets | &mdash; | yes | yes |
| Apply per-user options to every account | &mdash; | yes | yes |
| Reinstall removed Store apps through winget | &mdash; | yes | yes |
| Unattended apply from the command line | &mdash; | &mdash; | yes |
| Client hand-over report | &mdash; | &mdash; | yes |
| The 3 deployment presets | &mdash; | &mdash; | yes |
| Machines per licence | no licence | 3 | unlimited |
| Commercial use | &mdash; | &mdash; | yes |

Pro is for your own machines; Technician is for machines that are not yours. The
tiers are defined in `data\licensing.json`, and Technician's feature list is a
strict superset of Pro's &mdash; `tools\Test-Tiers.ps1` asserts that, because for
a while both tiers granted exactly the same four features and a Technician key
unlocked nothing a Pro key did not.

### What is gated, and what can never be

Exactly four features are paid:

| Feature id | What it unlocks |
|---|---|
| `presets.advanced` | The eight advanced curated presets |
| `presets.save` | Saving, exporting and importing your own presets |
| `allusers` | Applying per-user options to every account on the PC |
| `winget` | Reinstalling removed Store apps through winget |

Everything else is free forever: all 355 options in all 15 categories, the
journal, per-option Revert, Undo everything, dry run, restore points — and the
Aggressive options, because selling the dangerous ones as an upgrade would mean
profiting from risk.

That is not just a promise in prose. `tools/Test-License.ps1` reads the source
and asserts that `Journal.ps1`, the undo handler, the apply loop, the catalogue
loader and `Restore-ActionCapture` contain **no entitlement check at all**. If
someone ever puts one there, the test fails.

### Behaviour that matters

- **A free install never makes a network call.** Validation only runs when a key
  is stored.
- **Losing internet access never takes away what was paid for.** Re-checked
  every 14 days, but an activated PC keeps Pro for 60 days without a successful
  check, and the panel says when the last one was. Only a definite answer from
  Polar — revoked, refunded, expired — downgrades.
- **Three PCs, movable.** Activation sends the key and a machine label (PC name
  plus an eight-character hash of the machine GUID) and nothing else. *Remove
  from this PC* calls Polar's deactivate endpoint so the slot frees up.
- **No nagging.** The tier is a quiet chip in the title bar. A gated feature
  explains itself once, when you reach for it, and names what you reached for.
- **A locked preset keeps its full description**, so you can read exactly what
  you would be buying.

### The honest limitation

This app is plain-text PowerShell. Anyone can open `License.ps1` and make
`Test-Feature` return `$true`. Obfuscating a `.ps1` would make the code worse and
stop nobody, so it is deliberately written to be read. This is a way to pay for
the work, not copy protection — and the licence panel in the app says exactly
that, including a line telling anyone for whom money is the obstacle to use the
free version with a clear conscience.

### Endpoints used

All three are public and need no API token:

```
POST https://api.polar.sh/v1/customer-portal/license-keys/activate
POST https://api.polar.sh/v1/customer-portal/license-keys/validate
POST https://api.polar.sh/v1/customer-portal/license-keys/deactivate
```

`Test-License.ps1` makes two live unauthenticated calls to confirm they still
behave as assumed: an unknown key must come back as a definite rejection rather
than a network error, or the offline grace logic would hand out Pro to a bad key.

---

## Accessibility

Driving the running window with UI Automation turned up two things no test or
screenshot could have shown, both now fixed:

- **Every list row announced as `Debloat.CategoryVM`.** WPF's automation peer
  falls back to an item's string form, and the view-models had no `ToString()`.
  A screen reader read the class name fifteen times over. Rows now announce
  properly: *"Privacy & Telemetry, 28 options"*, and an option card reads
  *"Diagnostic data sent to Microsoft, Safe risk, currently Enabled, set to
  Disable"* - name, risk, live state and staged action in one phrase.
- **Buttons whose content is an icon-plus-text panel had no accessible name at
  all.** Close, Apply, Undo, Stage preset, the card clear and expand buttons -
  none of them were identifiable. 43 elements now carry an explicit
  `AutomationProperties.Name`.

Risk is never conveyed by colour alone anywhere: every chip, stripe and chart
segment carries its label, and the risk colours were chosen by measurement so
the safe/moderate pair stays distinguishable under red-green colour blindness.

---

## Known limits

- **Defender.** Tamper Protection, on by default, silently rejects registry
  changes to Defender. Those options will appear to apply and then do nothing.
  The cards say so.
- **Protected services.** A few services refuse changes even from an elevated
  session. The engine falls back to writing the start value directly and tells
  you a restart is needed; where even that is denied it logs `ACCESS DENIED`
  rather than pretending to have succeeded.
- **Per-user scope.** `HKCU` options apply to the account running the app unless
  you tick *Apply per-user options to all accounts*. Machine-wide policies in
  `HKLM` cover every account regardless, which is why many options set both.
- **Loaded hives.** A profile whose registry is currently loaded — someone else
  signed in, or switched user — is written in place rather than mounted. A
  profile that cannot be reached at all is logged and skipped, not failed.
- **Feature updates.** A Windows version upgrade can reinstate removed apps and
  reset some policies. Re-stage your preset afterwards.
- **Newest builds.** Microsoft has begun ignoring the classic context-menu key on
  some builds. That option will report as applied without changing the menu.

---

## Licence

Copyright (C) 2026 WndTech.

Windows Debloat Studio is free software: you can redistribute it and/or modify it
under the terms of the **GNU General Public License version 3** as published by
the Free Software Foundation, either version 3 of the licence, or (at your option)
any later version. It is distributed in the hope that it will be useful, but
**without any warranty** — without even the implied warranty of merchantability
or fitness for a particular purpose. See [LICENSE](LICENSE) for the full text.

### Why GPL, for a paid product

The two are not in conflict, and pretending otherwise would be dishonest given
what the app already tells its users.

The licence check in this app is three lines of readable PowerShell. Anyone who
wants to remove it can, and no amount of obfuscation would change that — it would
only make the code worse and the antivirus false-positives more frequent. So the
check has always been a way to pay for the work rather than a lock, and the app
says so in its own licence panel.

Given that, closed source bought nothing and cost a great deal:

- **It cost the trust argument.** "Read what it does before you run it as
  administrator" is the strongest thing this tool can say for itself.
- **It opened a route to a signature** — though not a clear one, see below.
- **It cost the contributions.** Catalogue accuracy is the hard part of this
  project and it improves with more machines and more Windows builds looking at
  it. See [CONTRIBUTING.md](CONTRIBUTING.md).

What is sold is not access to the code. It is the four convenience features
listed under *Licensing* above, a commercial-use licence, and curated catalogue
updates as Windows changes. Copying the client is free and always was; the app
being honest about that is the point.

### Still to fill in

| Where | What |
|---|---|
| `.github\workflows\build.yml` | the Certum signing step, once the certificate is obtained |
| `tools\Build-Exe.ps1` | `Invoke-SignExe`, if signing locally rather than in CI |
