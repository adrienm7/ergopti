// tools/test/fixtures/windows_launch_child.cs

// Native process fixture with no driver, tray or keyboard hooks. Its deliberate
// failures exercise the actual packaged-launch observer and evidence admission.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

public static class WindowsLaunchChild
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetLongPathNameW(string path, StringBuilder result, uint capacity);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetShortPathNameW(string path, StringBuilder result, uint capacity);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share,
        IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileIdentity identity);

    [StructLayout(LayoutKind.Sequential)]
    public struct FileIdentity
    {
        public uint Attributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }

    // AHK normalizes its own module before publishing A_ScriptFullPath. Match
    // that producer contract without consulting the observer's expected path.
    private static string CanonicalExistingFile(string path)
    {
        if (String.IsNullOrEmpty(path) || !Path.IsPathRooted(path)
            || Path.GetPathRoot(path).Length < 3
            || !File.Exists(path) || Directory.Exists(path))
            throw new InvalidOperationException("The native module must be an existing absolute regular file.");
        // GetFullPath expands 8.3 names on .NET Framework. Input spelling is
        // not canonical authority; dot components remain inadmissible aliases.
        foreach (var piece in path.Split(new char[] { '\\', '/' })) {
            if (piece == "." || piece == "..")
                throw new InvalidOperationException("Native module dot components are refused.");
        }
        var result = new StringBuilder(32768);
        uint size = GetLongPathNameW(path, result, (uint)result.Capacity);
        if (size == 0 || size >= result.Capacity || size != result.Length)
            throw new InvalidOperationException("The native module canonicalization was incomplete.");
        var canonical = result.ToString();
        if (!File.Exists(canonical) || Directory.Exists(canonical)
            || !String.Equals(Path.GetFullPath(canonical), canonical, StringComparison.OrdinalIgnoreCase)
            || !String.Equals(Path.GetFullPath(path), canonical, StringComparison.OrdinalIgnoreCase)
            || !SamePhysicalFile(path, canonical))
            throw new InvalidOperationException("The canonical native module is not an absolute regular file.");
        return canonical;
    }

    private static bool SamePhysicalFile(string left, string right)
    {
        using (var first = CreateFileW(left, 0, 7, IntPtr.Zero, 3, 0, IntPtr.Zero))
        using (var second = CreateFileW(right, 0, 7, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
            FileIdentity a, b;
            if (first.IsInvalid || second.IsInvalid
                || !GetFileInformationByHandle(first, out a)
                || !GetFileInformationByHandle(second, out b))
                throw new InvalidOperationException("Native file identity could not be observed.");
            return a.Volume == b.Volume && a.IndexHigh == b.IndexHigh && a.IndexLow == b.IndexLow;
        }
    }

    private static string OwnExecutable()
    {
        return CanonicalExistingFile(Process.GetCurrentProcess().MainModule.FileName);
    }

    private static void Require(bool condition, string failure)
    {
        if (!condition) throw new InvalidOperationException(failure);
    }

    private static int IdentityControls(string[] args)
    {
        if (args.Length == 1 && args[0] == "--own-image") {
            var module = Process.GetCurrentProcess().MainModule.FileName;
            var canonical = OwnExecutable();
            Require(SamePhysicalFile(module, canonical), "Own module canonicalization changed physical identity.");
            Console.Write(new JavaScriptSerializer().Serialize(new Dictionary<string, object> {
                { "canonical", canonical }, { "same_file", true },
                { "alias_observed", !String.Equals(module, canonical, StringComparison.OrdinalIgnoreCase) }
            }));
            return 0;
        }
        if (args.Length != 2 || (args[0] != "--identity-controls"
            && args[0] != "--identity-controls-no-short-alias")) {
            Console.Error.WriteLine("Unknown native identity control mode.");
            return 9;
        }
        var root = CanonicalExistingFile(OwnExecutable());
        var directory = Path.GetFullPath(args[1]);
        Directory.CreateDirectory(directory);
        var expected = Path.Combine(directory, "independent long module name", "ErgoptiPlus.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(expected));
        File.Copy(root, expected);
        // Resolve the caller's long root first; the child itself still derives
        // its own canonical module from the operating system, never this value.
        expected = CanonicalExistingFile(expected);
        var shortBuffer = new StringBuilder(32768);
        uint shortSize = GetShortPathNameW(expected, shortBuffer, (uint)shortBuffer.Capacity);
        Require(shortSize > 0 && shortSize < shortBuffer.Capacity && shortSize == shortBuffer.Length,
            "The controlled native short alias is unavailable.");
        var alias = shortBuffer.ToString();
        Require(SamePhysicalFile(alias, expected), "The native short alias identifies another file.");
        Require(String.Equals(CanonicalExistingFile(alias), expected, StringComparison.OrdinalIgnoreCase),
            "The native alias does not resolve to the exact controlled module.");
        var foreign = Path.Combine(directory, "foreign sibling", "ErgoptiPlus.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(foreign));
        File.Copy(root, foreign);
        Require(!SamePhysicalFile(expected, foreign), "The foreign sibling must be physically independent.");
        foreach (var invalid in new string[] { "relative.exe", directory, Path.Combine(directory, "missing.exe"), "" }) {
            bool refused = false;
            try { CanonicalExistingFile(invalid); } catch (InvalidOperationException) { refused = true; }
            Require(refused, "An invalid native module path was admitted.");
        }
        // These malformed spellings identify the actual copied file; refusal
        // cannot pass merely because a synthetic negative happens not to exist.
        var priorDirectory = Environment.CurrentDirectory;
        try {
            Environment.CurrentDirectory = Path.GetDirectoryName(expected);
            var driveRelative = expected.Substring(0, 2) + Path.GetFileName(expected);
            var rootRelative = expected.Substring(2);
            var dotted = Path.Combine(Path.GetDirectoryName(expected), ".", Path.GetFileName(expected));
            var parentDotted = Path.Combine(Path.GetDirectoryName(expected), "..",
                Path.GetFileName(Path.GetDirectoryName(expected)), Path.GetFileName(expected));
            foreach (var invalid in new string[] { driveRelative, rootRelative, dotted, parentDotted }) {
                Require(SamePhysicalFile(invalid, expected), "An invalid-spelling control must identify the actual copied file.");
                bool refused = false;
                try { CanonicalExistingFile(invalid); } catch (InvalidOperationException) { refused = true; }
                Require(refused, "An existing malformed native module spelling was admitted.");
            }
        } finally {
            Environment.CurrentDirectory = priorDirectory;
        }
        // A successful native API may return its input when no distinct 8.3 alias exists.
        // Keep real image identity/receipt controls mandatory on that valid capability.
        var forceNoShortAlias = args[0] == "--identity-controls-no-short-alias";
        var launchPath = forceNoShortAlias ? expected : alias;
        var aliasObserved = !String.Equals(launchPath, expected, StringComparison.OrdinalIgnoreCase);
        var start = new ProcessStartInfo(launchPath, "--own-image") {
            UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true
        };
        using (var child = Process.Start(start)) {
            try {
                var handle = child.Handle;
                Require(handle != IntPtr.Zero, "The native alias child handle is unavailable.");
                Require(child.WaitForExit(10000), "The owned native alias child did not retire within its bound.");
                var output = child.StandardOutput.ReadToEnd();
                var error = child.StandardError.ReadToEnd();
                Require(child.ExitCode == 0 && error.Length == 0, "The owned native alias child failed.");
                var receipt = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(output);
                Require(receipt.Count == 3 && receipt.ContainsKey("canonical") && receipt.ContainsKey("same_file")
                    && receipt.ContainsKey("alias_observed"),
                    "The native alias child receipt is malformed.");
                Require((bool)receipt["same_file"] && (bool)receipt["alias_observed"] == aliasObserved
                    && String.Equals((string)receipt["canonical"], expected, StringComparison.OrdinalIgnoreCase),
                    "The actual native alias child did not publish its exact owned long module.");
            } finally {
                if (!child.HasExited) {
                    child.Kill();
                    Require(child.WaitForExit(5000), "The owned native alias child cleanup did not acknowledge exit.");
                }
            }
        }
        var capability = aliasObserved ? "observed" : "unavailable";
        if (forceNoShortAlias) capability += " (forced control)";
        Console.WriteLine("[OK] Native own-module identity and exact long-path receipt; foreign and invalid paths are refused. Short alias capability: "
            + capability + ".");
        return 0;
    }

    public static int Main(string[] args)
    {
        // The real observer supplies /ErrorStdOut. The original no-argument
        // entry point ignored those ordinary launch arguments; preserve that
        // behavior and reserve only -- modes for private native controls.
        if (args.Length != 0 && args[0].StartsWith("--", StringComparison.Ordinal))
            return IdentityControls(args);
        var scenario = Environment.GetEnvironmentVariable("ERGOPTI_LAUNCH_CHILD_SCENARIO");
        if (scenario == "early-exit") return 7;
        var root = Environment.GetEnvironmentVariable("ERGOPTI_STARTUP_SMOKE_DIR");
        var nonce = Environment.GetEnvironmentVariable("ERGOPTI_STARTUP_SMOKE_NONCE");
        var commit = Environment.GetEnvironmentVariable("GITHUB_SHA");
        var bundle = Path.Combine(Environment.GetEnvironmentVariable("LOCALAPPDATA"), "Ergopti", "bundle");
        Directory.CreateDirectory(bundle);
        File.WriteAllText(Path.Combine(bundle, ".bundle-version"), "0.0.0-dev\n" + commit);
        if (scenario == "marker-only") {
            // Outlive the observer's two-second test bound, but remain disposable
            // even when an assertion interrupts the parent's cleanup path.
            Thread.Sleep(15000);
            return 7;
        }
        var receipt = new Dictionary<string, object> {
            { "schema_version", 1 },
            { "nonce", scenario == "foreign-nonce" ? new string('d', 32) : nonce },
            { "pid", Process.GetCurrentProcess().Id },
            { "executable", OwnExecutable() },
            { "compiled", true },
            { "build_commit", commit },
            { "bundle_identity", "0.0.0-dev\n" + commit },
            { "phase", "ready" },
            { "driver_ready", true },
            { "menu_ready", true },
            { "logs_flushed", true }
        };
        if (scenario == "foreign-executable") {
            var foreign = Path.Combine(root, "foreign sibling", "ErgoptiPlus.exe");
            Directory.CreateDirectory(Path.GetDirectoryName(foreign));
            File.Copy(OwnExecutable(), foreign);
            Require(!SamePhysicalFile(OwnExecutable(), foreign), "The foreign receipt must identify another physical file.");
            receipt["executable"] = CanonicalExistingFile(foreign);
        }
        File.WriteAllText(Path.Combine(root, "ready.json"), new JavaScriptSerializer().Serialize(receipt), new UTF8Encoding(false));
        if (scenario != "missing-logs") {
            var logs = Path.Combine(root, "ergopti_plus", "logs");
            Directory.CreateDirectory(logs);
            File.WriteAllText(Path.Combine(logs, "startup.log"),
                scenario == "logged-error" ? "[ERROR] deliberate startup failure\n" : "[INFO] ready\n");
        }
        return scenario == "receipt-then-error-exit" ? 7 : 0;
    }
}
