# Contributing

The most valuable thing you can contribute is **catalogue accuracy**. The code is
the easy half; knowing that a particular registry value still does what it did
two Windows builds ago is the hard half, and it is exactly the kind of thing that
gets better with more machines and more eyes on it.

## The bar for a catalogue entry

Every option carries an explanation that a non-expert can act on, and that means
a few things are non-negotiable.

**It must actually do something on a current build.** Windows renames and retires
things constantly. `TabletInputService` was split into
`TextInputManagementService` in Windows 11, and an option that only touched the
old name silently did nothing while looking perfectly healthy on screen — which
is worse than not shipping it, because the user believes it worked. Run:

```powershell
powershell -ExecutionPolicy Bypass -File tools\Audit-Catalog.ps1
```

It checks every registry path, service name, task path and package against what
is really on the machine, and splits the results into found, absent-but-plausible,
and suspect. Run it elevated for the feature and capability checks too.

**Say what breaks.** Not "may affect some features". Which feature, and how the
person will notice. `impact` is what they lose; `explain` is the full picture
including when *not* to do it. If disabling something is a bad idea for most
people, the entry should say so even though the option exists.

**Enable and disable must differ.** An option whose `enable` and `disable` write
the same value has an unreadable state and will show as *Unknown* for ever. The
validator catches this.

**Risk must be honest.** `safe` means reversible with no functional loss.
`moderate` changes a real feature, and the card has to name it. `aggressive` can
break Windows Update, security or app installation. Do not label something safe
because it is popular.

**No commands where a supported mechanism exists.** Prefer `reg`, `service`,
`task`, `appx`, `feature` or `capability` over `command`. Those action kinds can
capture their prior state, which means Revert works. A shelled-out command
usually cannot be undone, and undo is the whole point of this tool.

## Before opening a pull request

```powershell
python tools\Validate-Catalog.py                                       # structure and duplicates
powershell -ExecutionPolicy Bypass      -File tools\Audit-Catalog.ps1  # identifiers vs this machine
powershell -STA -ExecutionPolicy Bypass -File tools\Test-Engine.ps1    # capture -> apply -> revert -> undo
powershell -STA -ExecutionPolicy Bypass -File tools\Test-Ui.ps1        # XAML, bindings, filtering, presets
powershell -STA -ExecutionPolicy Bypass -File tools\Test-License.ps1   # entitlement and gating
```

Say which Windows build you tested on — `winver` — because "works on 24H2" and
"works on 25H2" are genuinely different claims.

## Things that will be turned down

**Options that cannot be reversed, without saying so.** If a change is one-way,
the card has to admit it. If it is one-way *and* avoidable, it does not belong.

**Anything that gates the safety net.** The journal, Revert, Undo everything and
the dry run are free for everyone, for ever. `tools\Test-License.ps1` asserts this
structurally by scanning the source: `Journal.ps1`, the undo handler, the apply
loop, the catalogue loader and `Restore-ActionCapture` must contain no entitlement
check at all. A change that puts one there will fail the test, and the test is
there on purpose.

**Obfuscation.** This is plain-text PowerShell deliberately. For a tool that
rewrites people's registries, being readable is a feature, and a licence check
that can be edited out is an accepted cost of that — see the note at the top of
`src\Modules\License.ps1`.

**Performance claims without evidence.** Most of what this app removes is
advertising, telemetry and unwanted apps. The honest performance wins are few.
The app says which they are rather than promising percentages, and it should stay
that way.

## Code style

Match the file you are editing. Comments explain *why*, not what — and especially
why something is done the awkward way, because most of the awkward code here is
working around a real PowerShell 5.1 or WPF behaviour, and without the note the
next person will "simplify" it straight back into the bug.

## Licence

Contributions are accepted under the GPL-3.0, the same licence as the project.
