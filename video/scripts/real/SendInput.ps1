# video/scripts/real/SendInput.ps1
#
# Keyboard injection for the real-capture scenarios. Text goes through
# KEYEVENTF_UNICODE packets, so it types the same characters whatever the
# active keyboard layout; named keys go through virtual-key codes. The driver
# sees these events like any other keyboard input, which is what the capture
# must prove.
#
# Windows only: the real capture records the Windows driver on the machine it
# is installed on. macOS and Linux captures would need their own injection
# (CGEventPost, uinput) and are not part of this scenario yet.

if (-not ('ErgoptiDemo.Keys' -as [type])) {
	Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace ErgoptiDemo {
	public static class Keys {
		[StructLayout(LayoutKind.Sequential)]
		struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
		[StructLayout(LayoutKind.Sequential)]
		struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
		[StructLayout(LayoutKind.Explicit)]
		struct UNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
		[StructLayout(LayoutKind.Sequential)]
		struct INPUT { public uint type; public UNION u; }

		[DllImport("user32.dll", SetLastError = true)]
		static extern uint SendInput(uint n, INPUT[] inputs, int size);
		[DllImport("user32.dll")]
		public static extern bool SetForegroundWindow(IntPtr hWnd);
		[DllImport("user32.dll")]
		public static extern bool ShowWindow(IntPtr hWnd, int cmd);
		[DllImport("user32.dll")]
		static extern IntPtr GetForegroundWindow();
		[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
		static extern uint RegisterWindowMessage(string name);
		[DllImport("user32.dll", SetLastError = true)]
		static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

		/// Asks the running Ergopti+ driver to insert the prediction it shows,
		/// through the message its LLM bridge listens for while active.
		public static void AcceptPrediction() {
			uint msg = RegisterWindowMessage("Ergopti.LLM.AcceptPrediction.v1");
			if (msg == 0) throw new InvalidOperationException("RegisterWindowMessage failed (error " + Marshal.GetLastWin32Error() + ")");
			if (!PostMessage(new IntPtr(0xFFFF), msg, IntPtr.Zero, IntPtr.Zero))
				throw new InvalidOperationException("PostMessage failed (error " + Marshal.GetLastWin32Error() + ")");
		}

		[DllImport("user32.dll", CharSet = CharSet.Unicode)]
		static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int max);
		[DllImport("user32.dll", CharSet = CharSet.Unicode)]
		static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder text, int max);

		static string Describe(IntPtr hWnd) {
			var title = new System.Text.StringBuilder(256);
			var cls = new System.Text.StringBuilder(256);
			GetWindowText(hWnd, title, 256);
			GetClassName(hWnd, cls, 256);
			return "0x" + hWnd.ToString("X") + " [" + cls + "] \"" + title + "\"";
		}

		/// The only window allowed to receive keys; set before typing.
		public static IntPtr Target = IntPtr.Zero;

		const uint KEYUP = 0x0002, UNICODE = 0x0004;

		static void Send(ushort vk, ushort scan, uint flags) {
			// Never type into whatever happens to have focus (a chat box, a terminal).
			if (Target == IntPtr.Zero) throw new InvalidOperationException("No target window set");
			IntPtr current = GetForegroundWindow();
			if (current != Target) throw new InvalidOperationException("Target window lost focus to " + Describe(current) + "; typing stopped");
			var input = new INPUT { type = 1 };
			input.u.ki = new KEYBDINPUT { wVk = vk, wScan = scan, dwFlags = flags };
			if (SendInput(1, new[] { input }, Marshal.SizeOf(typeof(INPUT))) != 1)
				throw new InvalidOperationException("SendInput was blocked (error " + Marshal.GetLastWin32Error() + ")");
		}

		/// Type text with a human rhythm: base delay plus seeded jitter.
		public static void Type(string text, int delayMs, int seed) {
			var rng = new Random(seed);
			foreach (char c in text) {
				if (c == '\n') { Key(0x0D); }
				else { Send(0, c, UNICODE); Send(0, c, UNICODE | KEYUP); }
				Thread.Sleep(delayMs / 2 + rng.Next(delayMs));
			}
		}

		/// Press and release a virtual key, optionally with modifiers held.
		public static void Key(ushort vk, params ushort[] modifiers) {
			foreach (var m in modifiers) Send(m, 0, 0);
			Send(vk, 0, 0);
			Send(vk, 0, KEYUP);
			for (int i = modifiers.Length - 1; i >= 0; i--) Send(modifiers[i], 0, KEYUP);
		}
	}
}
'@
}

$VK = @{ Tab = 0x09; Enter = 0x0D; Down = 0x28; Up = 0x26; Escape = 0x1B; Control = 0x11; A = 0x41; Back = 0x08 }

function Send-DemoText([string]$Text, [int]$DelayMs = 85, [int]$Seed = 7) { [ErgoptiDemo.Keys]::Type($Text, $DelayMs, $Seed) }
function Send-DemoAccept { [ErgoptiDemo.Keys]::AcceptPrediction() }
function Send-DemoKey([string]$Name, [string[]]$With = @()) {
	[ErgoptiDemo.Keys]::Key([uint16]$VK[$Name], [uint16[]]@($With | ForEach-Object { $VK[$_] }))
}
