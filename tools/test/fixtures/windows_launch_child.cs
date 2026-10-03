// tools/test/fixtures/windows_launch_child.cs

// Native process fixture with no driver, tray or keyboard hooks. Its deliberate
// failures exercise the actual packaged-launch observer and evidence admission.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

public static class WindowsLaunchChild
{
    public static int Main()
    {
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
            { "executable", Process.GetCurrentProcess().MainModule.FileName },
            { "compiled", true },
            { "build_commit", commit },
            { "bundle_identity", "0.0.0-dev\n" + commit },
            { "phase", "ready" },
            { "driver_ready", true },
            { "menu_ready", true },
            { "logs_flushed", true }
        };
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
