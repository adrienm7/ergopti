// tools/test/fixtures/source_boot_child.cs

// An input-free native child exercises source observer admission and cleanup.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

public static class SourceBootChild
{
    public static int Main(string[] arguments)
    {
        var root = Environment.GetEnvironmentVariable("ERGOPTI_STARTUP_SMOKE_DIR");
        var scenario = Environment.GetEnvironmentVariable("ERGOPTI_SOURCE_CHILD_SCENARIO");
        if (scenario == "early-exit") return 7;
        if (scenario == "reload-missing-receipt") {
            var start = new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName,
                "/restart /script \"" + arguments[arguments.Length - 1] + "\"");
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.EnvironmentVariables["ERGOPTI_SOURCE_CHILD_SCENARIO"] = "reload-child";
            using (var child = Process.Start(start)) { if (child == null) return 7; }
            return 0;
        }
        // Outlive the observer and survivor check so absence proves termination.
        if (scenario == "missing-receipt" || scenario == "reload-child") { Thread.Sleep(60000); return 7; }
        if (scenario == "delayed-hang") Thread.Sleep(500);
        var nonce = Environment.GetEnvironmentVariable("ERGOPTI_STARTUP_SMOKE_NONCE");
        if (scenario != "missing-logs") File.WriteAllText(Path.Combine(root, "startup.log"),
            scenario == "logged-error" ? "[ERROR] deliberate source startup failure\n" : "[INFO] ready\n");
        var receipt = new Dictionary<string, object> {
            { "schema_version", 1 },
            { "nonce", scenario == "foreign-nonce" ? new string('d', 32) : nonce },
            { "pid", Process.GetCurrentProcess().Id },
            { "executable", Process.GetCurrentProcess().MainModule.FileName },
            { "compiled", false },
            { "build_commit", new string('a', 40) },
            { "bundle_identity", "0.0.0-dev\n" + new string('a', 40) },
            { "phase", "ready" }, { "driver_ready", true },
            { "menu_ready", true }, { "logs_flushed", true }
        };
        if (scenario == "malformed-flags") receipt["driver_ready"] = "True";
        File.WriteAllText(Path.Combine(root, "ready.json"), new JavaScriptSerializer().Serialize(receipt), new UTF8Encoding(false));
        var wait = Stopwatch.StartNew();
        while (!File.Exists(Path.Combine(root, "ack.txt")) && wait.ElapsedMilliseconds < 10000) Thread.Sleep(10);
        if (scenario == "delayed-hang") { Thread.Sleep(60000); return 7; }
        return scenario == "receipt-then-error" ? 7 : 0;
    }
}
