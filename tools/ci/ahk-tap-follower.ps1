# tools/ci/ahk-tap-follower.ps1

# The TAP writer remains authoritative. Each poll owns a separate shared read;
# decoder state alone spans polls so partial UTF-8 cannot become replacement text.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace ErgoptiCi {
    public sealed class AhkTapFollower {
        private readonly string path;
        private readonly Decoder decoder = new UTF8Encoding(false, true).GetDecoder();
        private readonly StringBuilder pending = new StringBuilder();
        private readonly byte[] bytes = new byte[65536];
        private readonly char[] chars = new char[65538];
        private long offset;
        private bool seen;
        private bool first = true;
        private bool finished;
        private bool failed;

        public AhkTapFollower(string path) {
            if (String.IsNullOrWhiteSpace(path)) throw new ArgumentException("TAP path is required.");
            this.path = Path.GetFullPath(path);
        }

        private void Append(int count, List<string> lines) {
            for (int i = 0; i < count; i++) {
                char value = chars[i];
                if (first) {
                    first = false;
                    if (value == '\uFEFF') continue;
                }
                if (value == '\n') {
                    int length = pending.Length;
                    if (length > 0 && pending[length - 1] == '\r') length--;
                    lines.Add(pending.ToString(0, length));
                    pending.Clear();
                } else pending.Append(value);
            }
        }

        private string[] Read(bool final) {
            if (failed) throw new InvalidOperationException("The TAP follower previously failed.");
            if (finished) return new string[0];
            var lines = new List<string>();
            try {
                FileStream stream;
                try {
                    stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                        FileShare.ReadWrite | FileShare.Delete);
                } catch (FileNotFoundException) {
                    if (!seen && !final) return new string[0];
                    throw;
                } catch (DirectoryNotFoundException) {
                    if (!seen && !final) return new string[0];
                    throw;
                }
                using (stream) {
                    seen = true;
                    long end = stream.Length;
                    if (end < offset) throw new IOException("The TAP transcript was truncated.");
                    stream.Position = offset;
                    while (offset < end) {
                        int count = stream.Read(bytes, 0, (int)Math.Min(bytes.Length, end - offset));
                        if (count == 0) throw new EndOfStreamException("The TAP transcript ended during a read.");
                        Append(decoder.GetChars(bytes, 0, count, chars, 0, false), lines);
                        offset += count;
                    }
                }
                if (final) {
                    Append(decoder.GetChars(bytes, 0, 0, chars, 0, true), lines);
                    if (pending.Length > 0) {
                        lines.Add(pending.ToString());
                        pending.Clear();
                    }
                    finished = true;
                }
                return lines.ToArray();
            } catch {
                failed = true;
                throw;
            }
        }

        public string[] Poll() { return Read(false); }
        public string[] Finish() { return Read(true); }
    }
}
'@

function New-AhkTapFollower {
    param([Parameter(Mandatory = $true)][string] $Path)
    return [ErgoptiCi.AhkTapFollower]::new($Path)
}
