# Handover — where the project stands

**Windows Debloat Studio 1.0.0** · commit `556aa06` · 26 August 2026
6 commits, 52 tracked files, working tree clean, **nothing released yet**.

The app is finished and tested. What is not done is everything that needs a
value only you have: the payment account, somewhere to host the download, and a
decision about code signing.

---

## Moving it to the new machine

**There is no git remote.** The repository is local only.

Either **copy the whole folder** including its `.git` directory — history comes
with it, nothing to set up — or **push to a remote first**, which you need anyway
(step 1 below), so cloning kills two birds. Nothing in the tree contains a
secret; that was checked before the first commit.

### Not in git, on purpose

| Path | Why |
|---|---|
| `dist/` | Build output. `csc` stamps a fresh module id into every compile, so identical source produces a different file each time. Rebuild it, don't copy it. |
| `assets/app.ico` | Drawn from code by `tools\New-AppIcon.ps1`, which the build runs. Reproducible from source. |

### State that will not travel, and shouldn't

| Location | Holds | On the new machine |
|---|---|---|
| `%ProgramData%\WindowsDebloatStudio` | journal, licence | Created fresh, and locked to administrators on the first elevated run. |
| `%LOCALAPPDATA%\WindowsDebloatStudio` | compiled assembly, logs, your presets | Created fresh. Copy `presets\` across if you want to keep any you saved. |

If you ever activate a licence on the old machine, press **Remove from this PC**
in the licence panel before wiping it — that releases the activation slot instead
of burning one.

### What the new machine needs

Almost nothing, which was deliberate. No SDK, no MSBuild, no package restore.

- **Windows 11** — the catalogue targets it; options that don't apply read as *Unknown*.
- **Windows PowerShell 5.1** and **.NET Framework 4.x** — both in the box. The build uses the C# compiler that ships with the Framework, the same one the app uses at runtime for its view-models.
- **Python 3** — only for `tools\Validate-Catalog.py`. Nothing else needs it.

---

## Done

**The application.** 355 options across 15 categories, 14 presets. Every option
has its own explanation, a risk label, the live state read from the machine, and
three choices — Enable, Disable, Revert. Nothing is selected when it opens and
nothing is applied until you confirm.

**The safety net.** Every action journals its prior state before changing
anything, so Revert goes back to the value the machine had before the app ever
ran, and Undo everything replays the journal backwards. Dry run walks the same
code path and writes nothing. None of it is ever gated — a test asserts that by
scanning the source for entitlement checks.

**Packaging.** One 241 KB executable. No installer: it unpacks to a temporary
folder, runs, and deletes it on exit. The manifest requests administrator so UAC
names the app rather than PowerShell, and it sets its own taskbar identity so the
button shows the app icon. Window up in about 2.6 seconds.

**Licensing and tiers.** Polar's licence-key API implemented end to end —
activate, validate, machine slots, deactivate — offline-first, with a 14-day
re-check and a 60-day grace period. Free, Pro and Technician are genuinely
separate, Technician a strict superset of Pro.

**Technician features.** Unattended apply from the command line with
`--dry-run`, a client hand-over report rendered from the journal, and three
deployment presets. The unattended path still journals everything, so it is
exactly as reversible as clicking Apply.

**Open source.** GPL-3.0, notices in all 18 source files, `SECURITY.md`,
`CONTRIBUTING.md`, and a CI workflow that builds and tests on a clean Windows
runner. The licence panel states the terms, as the GPL asks of an interactive
program.

**The website.** Published, with the app's option control rebuilt live in the
page, a replayable dry run, and a comparison table covering all three tiers. The
build writes the exe's SHA-256 into the page and fails if the two disagree.

### Test coverage

| Suite | Checks | Covers |
|---|---|---|
| `Test-License.ps1` | 64 | Entitlement, offline grace, revocation, tier separation, what must never be gated |
| `Test-Engine.ps1` | 46 | Capture → apply → revert → undo, for all seven action kinds |
| `Test-Package.ps1` | 40 | What is actually inside the exe, and that nothing from the build machine leaks |
| `Test-Tiers.ps1` | 33 | Pro/Technician separation, unattended apply, hand-over report |
| `Test-Ui.ps1` | — | Smoke: XAML parses, all 88 named elements resolve, filtering and presets work |
| `Validate-Catalog.py` | 0 errors | Catalogue structure, duplicate ids, unreadable enable/disable pairs |

---

## Waiting on you

Each of these is a field with no sensible default. The app behaves correctly
without them — it stays on Free and makes no network calls at all — so nothing is
broken, it just cannot be sold yet.

**Polar organisation id** — `data\licensing.json`
Polar dashboard → Settings → General. Not a secret; the validate endpoints are
public and it identifies which organisation a key belongs to. Until it is set the
app never contacts anything.

**Two checkout links** — `data\licensing.json`
`checkout.pro` and `checkout.technician`. Three buttons on the website currently
point at `#checkout`, which lands on the note explaining nothing is wired up.

**Benefit ids, per tier** — `data\licensing.json`
This is how the app tells a Pro key from a Technician key.

> **The trap.** A tier with an empty `benefitIds` is the fallback for *any* valid
> key. Leave both empty and every key resolves to whichever tier comes first — so
> every Technician customer would silently be given Pro. Fill Technician's in at
> minimum. The file says so too.

**Public repository URL** — `src\Modules\Core.ps1`
`$script:SourceUrl`. The licence panel's *View the source* button reads it, and
says the link is not set rather than opening something wrong.

**A decision.** Same Polar organisation as SigForge, or a separate one? Asked
earlier and never settled. It changes nothing in the code — only which dashboard
the products live in.

---

## What to do next

Ordered because each one unblocks the next.

### 1. Push to a public repository

Open-sourcing was decided and the code is licensed for it, but nothing is
published. Three things already assume a public repo exists: the licence panel's
source link, `CONTRIBUTING.md`, and the CI workflow. It is also a precondition
for every free signing route.

### 2. Decide code signing

Still unsolved, and the single biggest barrier to anyone actually running the
download. Being GPL now opens the cheap routes.

| Route | Cost | Publisher shown | Catch |
|---|---|---|---|
| Certum open source | ~€25/yr | you | Requires open source — which you now are. Cheapest route that keeps your name. |
| Azure Trusted Signing | ~$10/mo | you | Needs a verified legal entity. |
| SignPath Foundation | free | **SignPath Foundation** | Needs an existing public release; excludes proprietary components, which a paid catalogue feed may count as. |
| OV certificate | ~£200/yr | you | SmartScreen reputation still builds slowly. |
| EV certificate | ~£300+/yr | you | Trusted by SmartScreen immediately. |

Whichever you pick, fill in `Invoke-SignExe` in `tools\Build-Exe.ps1` and pass
`-Sign`, or uncomment the CI step. Timestamping is not optional: without it every
signature stops validating the day the certificate expires, including on copies
already downloaded.

### 3. Host the exe and point the Download button at it

The build already writes the checksum into the download page and refuses to
finish if they disagree, so publishing is: build, upload, update the link. Keep
the SHA-256 visible — it is what technical buyers check, and the honest answer to
an unsigned binary.

### 4. Wire Polar and test one real key per tier

Activate, validate, deactivate, on both a Pro and a Technician key. Confirm a
Technician key actually reports the Technician tier rather than falling back to
Pro — that's the benefit-id trap above, and a real key is the only way to be sure.

### 5. Teach state detection what an absent policy key means

**135 of 355 options read *Unknown*** on an unelevated run. Most are policy values
that simply aren't set, where "not set" means the Windows default rather than
genuinely unknown. This is the largest remaining improvement to how the app
feels: the dashboard currently says it can't read a third of the catalogue.

### 6. Run the two elevation-gated suites

`Test-Engine.ps1` and `Audit-Catalog.ps1` both contain checks that only run with
administrator rights — the optional feature and capability queries in particular.
Those have never executed here. Run both from an elevated prompt.

### Considered and deliberately not done

- **"Catalogue updates as Windows changes"** was removed from the Technician card. It doesn't exist, and the other three Technician features are real. Worth building — Windows renames things constantly — but it needs hosting, and it may conflict with the free signing route's no-proprietary-components clause.
- **Obfuscating the payload.** Rejected on the evidence: it attacks the readable-source trust argument the product is built on, and an encrypted blob that spawns PowerShell to edit the registry is the textbook profile of a dropper — which makes the antivirus problem worse on an already-unsigned binary.
- **A self-extracting installer.** The single exe already needs no installer, and one would contradict what the site promises.

---

## Proving it works on the new machine

Run these first. If all pass you have a good clone and a working toolchain.

```powershell
# build the download, which also regenerates the icon
powershell -ExecutionPolicy Bypass -File tools\Build-Exe.ps1
#   -> built WindowsDebloatStudio.exe  (241 KB)
#   -> updated the checksum and size on the download page

python tools\Validate-Catalog.py                                       # 0 errors
powershell -STA -ExecutionPolicy Bypass -File tools\Test-Package.ps1   # PASSED (40)
powershell -STA -ExecutionPolicy Bypass -File tools\Test-Tiers.ps1     # PASSED (33)
powershell -STA -ExecutionPolicy Bypass -File tools\Test-License.ps1   # PASSED (64)
powershell -STA -ExecutionPolicy Bypass -File tools\Test-Engine.ps1    # PASSED (46)
powershell -STA -ExecutionPolicy Bypass -File tools\Test-Ui.ps1        # SMOKE TEST PASSED

# and if the app will not start, this says why rather than guessing
powershell -ExecutionPolicy Bypass -File tools\Diagnose.ps1
```

The first launch on a new machine recompiles the view-models, so it takes a few
seconds longer than usual. Later launches reuse the cached assembly.

---

## Sharp edges worth not rediscovering

Every one of these cost real time and is invisible in the code once fixed. The
comments in the source explain the awkward-looking parts for the same reason —
without the note, the next person simplifies them straight back into the bug.

**PowerShell unrolls returned arrays.** `return $bytes` hands back the elements
one at a time and the caller collects them into an `object[]`. Its `.Length` is
still correct, so a file header built from it looks right while no data at all is
written. Use `return , $bytes`. This produced a valid-looking icon containing no
pixels.

**`@()` over a generic List throws.** On this PowerShell build, `@()` over a
`List[object]` raises "Argument types do not match". Collections are
`ObservableCollection` throughout for this reason. The mirror image also bites:
returning `, $list` where the caller does `@()` gives one collection instead of
its items, which once made a multi-profile registry write hit only the first
profile.

**CSS `display` beats the `hidden` attribute.** A component with `display: grid`
ignores `hidden`, because the attribute's `display: none` comes from the
lower-priority user-agent sheet. Needs an explicit
`[hidden] { display: none !important }`.

**A windowed exe is not waited on.** A shell doesn't wait for a GUI-subsystem
program, so `$LASTEXITCODE` comes back empty and output isn't capturable. That's
the PE subsystem field, not something the app can decide — a console-subsystem
build would flash a black window at every GUI user. Script it with
`Start-Process -Wait`; `--help` and the README both say so.

**`AttachConsole` does not rebind handles.** Attaching to the parent's console
doesn't change the process's standard handles, so a child inheriting them writes
into nothing. Redirect and echo each line instead, which also makes `> log.txt`
and piping work.

**ACL ordering, twice.** Hardening a folder before creating its children locks
the process out of its own subfolders and the app dies at startup. And hardening
while *unelevated* lets a user restrict a folder they own and then be unable to
write to it, with no way back without elevation. It now only hardens when
actually elevated, after the folders exist.

**The catalogue's `core` tag means first-party.** Not "keep this". The apps tagged
`core` are News, Weather, Copilot, Clipchamp, Teams, Solitaire — first-party
bloat. Excluding that tag from a preset excludes exactly what you meant to
remove.

**Identical source, different binary.** `csc` stamps a fresh module version id
into every compile, so the SHA-256 changes on every build even with no source
change. A hand-typed checksum on the download page is wrong the moment you
rebuild — which teaches people to ignore checksums. The build writes it into the
page and fails if they disagree.

**`Measure-Object -Property` takes no script block.** On PowerShell 5.1 it wants
a property name, not `{ $_.Bytes.Length }`. Total it with a loop.
