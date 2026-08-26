// Windows Debloat Studio - review, apply and reverse what Windows 11 ships with.
// Copyright (C) 2026 WndTech
//
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later
// version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
// FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along with
// this program. If not, see <https://www.gnu.org/licenses/>.

// =====================================================================
//  Bootstrap.cs - the single executable the user downloads.
//
//  Windows Debloat Studio is PowerShell and XAML. That is a deliberate
//  choice: everything it does to your machine is readable text rather
//  than a compiled black box. But nobody sensibly double-clicks a .ps1
//  from a stranger, so the download is one signed-shaped executable
//  that carries the app inside it.
//
//  What this program does, in full:
//    1. unpacks its embedded payload into a private temporary folder
//    2. runs Debloat.ps1 there with Windows PowerShell, no console
//    3. waits, and if it failed, shows why
//    4. deletes the folder again
//
//  It installs nothing. Nothing is left on disk afterwards except the
//  app's own state folder, which holds the journal and is what makes
//  changes reversible.
//
//  Built by tools\Build-Exe.ps1 with the C# compiler already present in
//  Windows, so producing it needs no SDK and no NuGet.
// =====================================================================

using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;

[assembly: AssemblyTitle("Windows Debloat Studio")]
[assembly: AssemblyDescription("Review, apply and reverse what Windows 11 ships with.")]
[assembly: AssemblyProduct("Windows Debloat Studio")]
[assembly: AssemblyCompany("WndTech")]
[assembly: AssemblyCopyright("Copyright © WndTech")]

namespace WindowsDebloatStudio
{
    internal static class Program
    {
        private const string PayloadResource = "payload.bin";
        private const string AppName = "Windows Debloat Studio";

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

        private const uint MB_ICONERROR = 0x10;
        private const uint MB_ICONWARNING = 0x30;

        [STAThread]
        private static int Main(string[] args)
        {
            string work = null;
            try
            {
                string ps = FindPowerShell();
                if (ps == null)
                {
                    Warn("Windows PowerShell 5.1 could not be found on this PC.\n\n"
                       + "It ships with Windows 11 and this app needs it. If it has been "
                       + "removed or disabled by policy, the app cannot run.");
                    return 2;
                }

                // Started from a prompt with -apply, -validate or -report, this
                // behaves like a console program: it writes to the console that
                // launched it and reports through the exit code, rather than
                // showing a dialog nobody is watching.
                bool console = WantsConsole(args);
                if (console) { try { AttachConsole(ATTACH_PARENT_PROCESS); } catch { } }

                work = Path.Combine(Path.GetTempPath(),
                    "WindowsDebloatStudio-" + Guid.NewGuid().ToString("N").Substring(0, 12));
                Directory.CreateDirectory(work);

                Unpack(work);

                string script = Path.Combine(work, "Debloat.ps1");
                if (!File.Exists(script))
                {
                    Fail("The copy of the app inside this download is incomplete.\n\n"
                       + "Download it again. If it keeps happening the file was damaged "
                       + "in transit, and the checksum on the download page will confirm it.");
                    return 3;
                }

                string forwarded = Forward(args);
                if (RejectedValue != null)
                {
                    string msg = "-" + RejectedValue + " needs a file path, and the one "
                               + "given cannot be used. Nothing was changed."
                               + "\n\nA path containing ; | & ` or a quote is refused "
                               + "rather than passed on to PowerShell.";
                    if (console) { Console.Error.WriteLine("  " + msg.Replace("\n\n", " ")); }
                    else { Fail(msg); }
                    return 3;
                }

                return Run(ps, script, work, forwarded, console);
            }
            catch (Exception ex)
            {
                Fail("The app could not be started.\n\n" + Describe(ex));
                return 1;
            }
            finally
            {
                Cleanup(work);
            }
        }

        // ------------------------------------------------------------ payload
        //
        // The payload is a flat list of files, deflate-compressed as a whole.
        // Deliberately a format written by hand rather than a zip: it needs no
        // reference beyond System.dll, so the build has nothing to resolve.
        //
        //   int32   file count
        //   per file:
        //     int32   length of the relative path in UTF-8 bytes
        //     bytes   the relative path
        //     int64   last-write time, UTC ticks
        //     int32   length of the contents
        //     bytes   the contents
        //
        // The original write times are carried across because the app compares
        // Interop.cs against its compiled assembly to decide whether to rebuild
        // it. Unpacking with fresh timestamps would make it rebuild every launch.
        private static void Unpack(string dest)
        {
            string root = Path.GetFullPath(dest);
            if (!root.EndsWith(Path.DirectorySeparatorChar.ToString(), StringComparison.Ordinal))
            {
                root += Path.DirectorySeparatorChar;
            }

            using (Stream res = Assembly.GetExecutingAssembly()
                       .GetManifestResourceStream(PayloadResource))
            {
                if (res == null) throw new InvalidOperationException("The embedded payload is missing.");

                using (var inflate = new DeflateStream(res, CompressionMode.Decompress))
                using (var buffer = new MemoryStream())
                {
                    Copy(inflate, buffer);
                    buffer.Position = 0;

                    using (var r = new BinaryReader(buffer, new UTF8Encoding(false)))
                    {
                        int count = r.ReadInt32();
                        for (int i = 0; i < count; i++)
                        {
                            string rel = new UTF8Encoding(false).GetString(r.ReadBytes(r.ReadInt32()));
                            long ticks = r.ReadInt64();
                            byte[] data = r.ReadBytes(r.ReadInt32());

                            string full = Path.GetFullPath(Path.Combine(dest, rel));
                            if (!full.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                            {
                                // Cannot happen with a payload this build produced, but a
                                // path that escapes the folder is never written regardless.
                                throw new InvalidOperationException("Refusing to unpack outside the working folder: " + rel);
                            }

                            Directory.CreateDirectory(Path.GetDirectoryName(full));
                            File.WriteAllBytes(full, data);
                            try { File.SetLastWriteTimeUtc(full, new DateTime(ticks, DateTimeKind.Utc)); }
                            catch { /* a wrong timestamp only costs a recompile */ }
                        }
                    }
                }
            }
        }

        // Stream.CopyTo exists from .NET 4, but this build targets the compiler
        // in the box and stays away from anything version-dependent.
        private static void Copy(Stream from, Stream to)
        {
            byte[] buf = new byte[81920];
            int n;
            while ((n = from.Read(buf, 0, buf.Length)) > 0) to.Write(buf, 0, n);
        }

        // ------------------------------------------------------------ launch
        private static int Run(string powershell, string script, string work, string forwarded, bool console)
        {
            var psi = new ProcessStartInfo(powershell);
            psi.Arguments = "-STA -NoProfile -ExecutionPolicy Bypass -File \"" + script + "\""
                          + forwarded;
            psi.WorkingDirectory = work;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            // Always redirected. In console mode each line is echoed straight to
            // our own stdout as it arrives, which is what makes "> log.txt" and
            // piping work. Letting the child inherit the handles instead looked
            // simpler and produced no output at all: AttachConsole attaches the
            // process to a console but does not rebind its standard handles, so
            // the child was writing into nothing.
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;

            var log = new StringBuilder();
            using (Process p = new Process())
            {
                p.StartInfo = psi;
                p.OutputDataReceived += (s, e) =>
                {
                    if (e.Data == null) return;
                    if (console) { Console.Out.WriteLine(e.Data); }
                    else { lock (log) log.AppendLine(e.Data); }
                };
                p.ErrorDataReceived += (s, e) =>
                {
                    if (e.Data == null) return;
                    if (console) { Console.Error.WriteLine(e.Data); }
                    else { lock (log) log.AppendLine(e.Data); }
                };
                p.Start();
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
                p.WaitForExit();
                if (console) { try { Console.Out.Flush(); } catch { } }

                if (p.ExitCode != 0 && !console)
                {
                    string tail;
                    lock (log) tail = Tail(log.ToString(), 18);
                    Fail("The app closed with an error.\n\n" + tail
                       + "\n\nThe full log is in:\n" + StateFolder());
                }
                return p.ExitCode;
            }
        }

        // The switches the app understands, and whether each takes a value.
        // An allow-list rather than a pattern: everything reaching this point is
        // being pasted into a PowerShell command line, so the safe design is to
        // know every switch by name and refuse the rest outright.
        private static readonly string[] FlagSwitches =
            { "noelevate", "validate", "silent", "help", "dryrun" };
        private static readonly string[] ValueSwitches = { "apply", "report" };

        // Set by Forward when a switch that needs a path was given something
        // unusable, and checked before anything is launched.
        private static string RejectedValue;

        private static string Forward(string[] args)
        {
            if (args == null || args.Length == 0) return string.Empty;
            var sb = new StringBuilder();

            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i];
                if (a == null || a.Length < 2) continue;
                if (a[0] != '-' && a[0] != '/') continue;

                string name = a.TrimStart('-', '/').ToLowerInvariant().Replace("-", string.Empty);
                if (!IsWordy(name)) continue;

                if (Contains(FlagSwitches, name))
                {
                    sb.Append(" -").Append(name);
                    continue;
                }

                // -apply and -report take a path. It is quoted, and any quote
                // characters inside it are dropped rather than escaped, so a
                // value can never close the quoting and append a command.
                if (Contains(ValueSwitches, name))
                {
                    string val = (i + 1 < args.Length) ? args[++i] : null;
                    bool usable = !string.IsNullOrEmpty(val)
                        && val.IndexOf(';') < 0 && val.IndexOf('|') < 0
                        && val.IndexOf('&') < 0 && val.IndexOf('`') < 0
                        && val.IndexOf('\"') < 0;

                    if (!usable)
                    {
                        // Refused rather than dropped. Dropping it meant the
                        // app fell through to opening a window, so a
                        // deployment script would report success having
                        // applied nothing at all.
                        RejectedValue = name;
                        return string.Empty;
                    }
                    sb.Append(" -").Append(name).Append(" \"").Append(val).Append('\"');
                }
            }
            return sb.ToString();
        }

        private static bool Contains(string[] set, string value)
        {
            foreach (string s in set) if (s == value) return true;
            return false;
        }

        private static bool IsWordy(string s)
        {
            foreach (char c in s) if (!char.IsLetter(c)) return false;
            return s.Length > 0;
        }

        // An unattended run has no window to report into, so its output has to
        // reach the console that launched it. Attaching to the parent's console
        // makes a windowed executable behave like a console one when, and only
        // when, it was started from a prompt.
        [DllImport("kernel32.dll")]
        private static extern bool AttachConsole(int processId);
        private const int ATTACH_PARENT_PROCESS = -1;

        private static bool WantsConsole(string[] args)
        {
            if (args == null) return false;
            foreach (string a in args)
            {
                if (a == null) continue;
                string n = a.TrimStart('-', '/').ToLowerInvariant();
                n = n.Replace("-", string.Empty);
                if (n == "apply" || n == "validate" || n == "report" || n == "help") return true;
            }
            return false;
        }

        // ------------------------------------------------------------ helpers
        //
        // A 32-bit process on 64-bit Windows sees System32 redirected to
        // SysWOW64, and the 32-bit PowerShell there reads a different view of
        // the registry - which would quietly give wrong answers about the
        // machine. Sysnative reaches the real System32 in that case.
        private static string FindPowerShell()
        {
            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string tail = @"WindowsPowerShell\v1.0\powershell.exe";

            if (!Environment.Is64BitProcess && Environment.Is64BitOperatingSystem)
            {
                string native = Path.Combine(windows, Path.Combine("Sysnative", tail));
                if (File.Exists(native)) return native;
            }

            string system = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), tail);
            if (File.Exists(system)) return system;

            string fallback = Path.Combine(windows, Path.Combine("System32", tail));
            return File.Exists(fallback) ? fallback : null;
        }

        private static string StateFolder()
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                Path.Combine("WindowsDebloatStudio", "logs"));
        }

        private static void Cleanup(string dir)
        {
            if (dir == null || !Directory.Exists(dir)) return;
            try { Directory.Delete(dir, true); }
            catch
            {
                // Something in the folder is still open. It is under the
                // user's temp folder, so Windows will clear it eventually.
            }
        }

        private static string Tail(string text, int lines)
        {
            if (string.IsNullOrEmpty(text)) return "(the app produced no output)";
            string[] all = text.Replace("\r\n", "\n").TrimEnd('\n').Split('\n');
            int from = Math.Max(0, all.Length - lines);
            return string.Join(Environment.NewLine, all, from, all.Length - from);
        }

        private static string Describe(Exception ex)
        {
            var sb = new StringBuilder();
            for (Exception e = ex; e != null; e = e.InnerException)
            {
                if (sb.Length > 0) sb.AppendLine();
                sb.Append(e.Message);
            }
            return sb.ToString();
        }

        private static void Fail(string message) { MessageBoxW(IntPtr.Zero, message, AppName, MB_ICONERROR); }
        private static void Warn(string message) { MessageBoxW(IntPtr.Zero, message, AppName, MB_ICONWARNING); }
    }
}
