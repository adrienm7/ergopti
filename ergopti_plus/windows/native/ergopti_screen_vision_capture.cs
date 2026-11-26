// native/ergopti_screen_vision_capture.cs

// ==============================================================================
// MODULE: Screen Vision Capture (Windows)
// DESCRIPTION:
// Captures a window or a screen rectangle into the shared gray image, and
// decodes or writes library images, for the Windows screen vision worker
// (vendor/ergopti_screen_vision_worker.ps1), built with
// ergopti_screen_vision_matcher.cs into vendor/ergopti_screen_vision.dll by
// tools/build/build_windows_screen_vision.ps1.
//
// FEATURES & RATIONALE:
// 1. Physical pixels: the worker declares itself per-monitor DPI aware before
//    anything else, so a window on a 150 % screen is read at its real size and
//    the frame it reports is the one SetCursorPos uses.
// 2. A window's frame is its DWM extended frame bounds, without the invisible
//    resize border GetWindowRect includes on Windows 10 and 11.
// 3. Decoding goes through WIC (WPF's BitmapDecoder), so every codec Windows
//    has (PNG, JPEG, GIF's first frame, BMP, TIFF, and WebP or HEIC when their
//    store extensions are installed) imports a library image; any other file
//    throws and the worker answers "import_unsupported_format".
// 4. C# 5 only, as the matcher, for the .NET Framework compiler the builder
//    uses.
// ==============================================================================

using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Ergopti.ScreenVision
{
	public sealed class Frame
	{
		public int X;
		public int Y;
		public int Width;
		public int Height;
	}

	public static class Capture
	{
		[StructLayout(LayoutKind.Sequential)]
		private struct Rect
		{
			public int Left;
			public int Top;
			public int Right;
			public int Bottom;
		}

		private const int DwmExtendedFrameBounds = 9;
		private static readonly IntPtr PerMonitorAwareV2 = new IntPtr(-4);

		[DllImport("user32.dll")]
		private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

		[DllImport("user32.dll")]
		private static extern bool GetWindowRect(IntPtr window, out Rect rect);

		[DllImport("user32.dll")]
		private static extern bool IsWindow(IntPtr window);

		[DllImport("dwmapi.dll")]
		private static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out Rect rect, int size);

		/// <summary>Reads the screen in physical pixels from now on.</summary>
		public static bool DeclareDpiAware()
		{
			return SetProcessDpiAwarenessContext(PerMonitorAwareV2);
		}

		/// <summary>The on-screen frame of a window, or null when it is gone.</summary>
		public static Frame WindowFrame(long handle)
		{
			IntPtr window = new IntPtr(handle);
			if (!IsWindow(window)) return null;
			Rect rect;
			if (DwmGetWindowAttribute(window, DwmExtendedFrameBounds, out rect, Marshal.SizeOf(typeof(Rect))) != 0
				&& !GetWindowRect(window, out rect)) return null;
			Frame frame = new Frame();
			frame.X = rect.Left;
			frame.Y = rect.Top;
			frame.Width = rect.Right - rect.Left;
			frame.Height = rect.Bottom - rect.Top;
			return frame.Width > 0 && frame.Height > 0 ? frame : null;
		}

		/// <summary>Copies a screen rectangle into a bitmap.</summary>
		public static Bitmap Screen(Frame frame)
		{
			Bitmap bitmap = new Bitmap(frame.Width, frame.Height, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
			using (Graphics graphics = Graphics.FromImage(bitmap))
			{
				graphics.CopyFromScreen(frame.X, frame.Y, 0, 0, new System.Drawing.Size(frame.Width, frame.Height));
			}
			return bitmap;
		}

		/// <summary>The shared gray image of a bitmap.</summary>
		public static GrayImage ToGray(Bitmap bitmap)
		{
			int width = bitmap.Width;
			int height = bitmap.Height;
			BitmapData data = bitmap.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.ReadOnly,
				System.Drawing.Imaging.PixelFormat.Format32bppArgb);
			try
			{
				byte[] bgra = new byte[data.Stride * height];
				Marshal.Copy(data.Scan0, bgra, 0, bgra.Length);
				return FromBgra(bgra, width, height, data.Stride);
			}
			finally
			{
				bitmap.UnlockBits(data);
			}
		}

		private static GrayImage FromBgra(byte[] bgra, int width, int height, int stride)
		{
			int[] pixels = new int[width * height];
			for (int y = 0; y < height; y++)
			{
				int row = y * stride;
				for (int x = 0; x < width; x++)
				{
					int at = row + x * 4;
					pixels[y * width + x] = Matcher.Gray(bgra[at + 2], bgra[at + 1], bgra[at]);
				}
			}
			return new GrayImage(width, height, pixels);
		}

		/// <summary>Decodes the first frame of any image WIC can read.</summary>
		public static BitmapSource Decode(string path)
		{
			using (FileStream stream = File.OpenRead(path))
			{
				BitmapDecoder decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.PreservePixelFormat,
					BitmapCacheOption.OnLoad);
				BitmapSource frame = decoder.Frames[0];
				FormatConvertedBitmap converted = new FormatConvertedBitmap(frame, PixelFormats.Bgra32, null, 0);
				converted.Freeze();
				return converted;
			}
		}

		/// <summary>The shared gray image of a decoded file.</summary>
		public static GrayImage LoadGray(string path)
		{
			BitmapSource source = Decode(path);
			int stride = source.PixelWidth * 4;
			byte[] bgra = new byte[stride * source.PixelHeight];
			source.CopyPixels(bgra, stride, 0);
			return FromBgra(bgra, source.PixelWidth, source.PixelHeight, stride);
		}

		/// <summary>Writes a decoded image as PNG, the library's stored format.</summary>
		public static void WritePng(BitmapSource source, string path)
		{
			PngBitmapEncoder encoder = new PngBitmapEncoder();
			encoder.Frames.Add(BitmapFrame.Create(source));
			using (FileStream stream = File.Create(path))
			{
				encoder.Save(stream);
			}
		}

		/// <summary>Writes a captured bitmap as PNG.</summary>
		public static void WriteBitmapPng(Bitmap bitmap, string path)
		{
			bitmap.Save(path, ImageFormat.Png);
		}
	}
}
