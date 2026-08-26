# Security

This program runs with administrator rights and rewrites registry values, service
start types, scheduled tasks and installed packages. That is its purpose, and it
is also why the way it handles trust matters.

## Reporting something

Open a private security advisory through the repository's **Security → Report a
vulnerability** page, or email the address on the project page. Please do not
open a public issue for anything that could be used against people running the
tool before there is a fix.

Include what you did, what happened, and the Windows build you saw it on. A
session log from `%LOCALAPPDATA%\WindowsDebloatStudio\logs\` usually says more
than a description.

## What the design already assumes is hostile

**Nothing is applied without confirmation.** Nothing is selected when the window
opens, and no change is written until the review sheet is confirmed. Dry run
walks the same code path and writes nothing at all — it returns early into a
describe-only branch rather than skipping the write at the end, so a bug cannot
let a write slip through in dry-run mode.

**Presets cannot carry instructions.** A preset is only option ids and the words
Enable, Disable or Revert. It can never contain a registry path, a command or a
script, so importing a preset a stranger sent you cannot make the app do anything
that is not already in the catalogue and visible on screen. Anything unrecognised
is dropped on load.

**The journal is not writable by ordinary users.**
`%ProgramData%\WindowsDebloatStudio\` is locked to administrators and SYSTEM for
writing, readable by everyone. This matters because *Revert* replays captured
values back into the registry as administrator — a journal that any user could
edit would be a way to hand arbitrary writes to an elevated process. The folder
is hardened only from an elevated run, and a later elevated run repairs the
permissions if an earlier unelevated one created it with the defaults.

**Executable code is never cached anywhere shared.** The compiled view-model
assembly lives in `%LOCALAPPDATA%\WindowsDebloatStudio\bin\`, per user, precisely
because ProgramData is writable by any account by default and that assembly is
loaded into an elevated process.

**The packaged exe unpacks under the elevated user's own temp directory** and
refuses any payload entry whose path resolves outside that folder.

**A free install makes no network calls.** Not one. Licence validation only
happens after someone has pasted a key, and it sends the key and a short machine
label — the PC name plus eight characters of a hash — and nothing else.

## Known limitations, stated plainly

**The licence check is not copy protection.** This is GPL software; the check is
readable and removable, and no amount of obfuscation would change that. It is a
way to pay for the work, not a lock. The app says so in its own licence panel.

**Defender's Tamper Protection wins.** Changes to Defender settings are silently
rejected by Windows when Tamper Protection is on. The app reports these as
refused rather than claiming success, but it cannot work around them, and should
not try to.

**Some changes cannot be reversed** and each says so on its own card. Disk
cleanup deletes data. A removed app package can only be reinstalled locally while
its files are still on disk; after that it needs the Store.

**Unsigned builds.** Code signing is not in place yet and is not a solved
problem for this project, so SmartScreen will warn on first run. Verify the SHA-256 published with the release against the file you
downloaded before running it. If the two do not match, do not run it, and please
report it.
