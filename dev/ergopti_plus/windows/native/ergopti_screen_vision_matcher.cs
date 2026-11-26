// native/ergopti_screen_vision_matcher.cs

// ==============================================================================
// MODULE: Screen Vision Matcher (C# port)
// DESCRIPTION:
// C# port of _shared/shortcuts/engine/keep_awake/auto_click_matcher.lua for the Windows
// screen vision worker (vendor/ergopti_screen_vision_worker.ps1), built at
// build time into vendor/ergopti_screen_vision.dll by
// tools/build/build_windows_screen_vision.ps1, which the worker loads without
// compiling anything at run time. The AutoHotkey twin
// (modules/shortcuts/auto_click_matcher.ahk) is the reference the AHK suite
// replays; this port is the one fast enough for a 700 ms tick.
//
// FEATURES & RATIONALE:
// 1. Same arithmetic as the shared module: integer sums (long), one double
//    product of the two variances before the square root, the same rounding
//    of gray and of a 2 x 2 box average.
// 2. Same search: power-of-two scales, a coarse pass at every pixel phase,
//    the strongest coarse candidates (score, then y, then x) refined at full
//    size, ties kept in row-major order.
// 3. C# 5 only: the builder uses the .NET Framework compiler every Windows
//    has (the one Windows PowerShell 5.1 itself compiles with), which knows no
//    interpolation, tuples or expression-bodied members.
// 4. Pinned by _shared/tests/corpus/keep_awake/auto_click_match_vectors.json.
// ==============================================================================

using System;
using System.Collections.Generic;

namespace Ergopti.ScreenVision
{
	public sealed class GrayImage
	{
		public int Width;
		public int Height;
		public int[] Pixels;

		public GrayImage(int width, int height, int[] pixels)
		{
			Width = width;
			Height = height;
			Pixels = pixels;
		}
	}

	public sealed class MatchOptions
	{
		public double Threshold;
		public double[] Scales;
		public int CoarseMinPx;
		public double CoarseMargin;
		public int CoarseCandidates;
	}

	public sealed class Hit
	{
		public int X;
		public int Y;
		public int Width;
		public int Height;
		public double Score;
		public double Scale;
	}

	public static class Matcher
	{
		// ======================================
		// ======= 1/ Images ====================
		// ======================================

		public static int Gray(int r, int g, int b)
		{
			return (r * 299 + g * 587 + b * 114 + 500) / 1000;
		}

		public static GrayImage Halve(GrayImage image, int ox, int oy)
		{
			int w = (image.Width - ox) / 2;
			int h = (image.Height - oy) / 2;
			if (w < 1 || h < 1) return null;
			int sw = image.Width;
			int[] src = image.Pixels;
			int[] outPixels = new int[w * h];
			for (int y = 0; y < h; y++)
			{
				int rowA = (2 * y + oy) * sw + ox;
				int rowB = rowA + sw;
				for (int x = 0; x < w; x++)
				{
					int c = 2 * x;
					outPixels[y * w + x] = (src[rowA + c] + src[rowA + c + 1] + src[rowB + c] + src[rowB + c + 1] + 2) / 4;
				}
			}
			return new GrayImage(w, h, outPixels);
		}

		public static GrayImage Double(GrayImage image)
		{
			int w = image.Width * 2;
			int[] outPixels = new int[w * image.Height * 2];
			for (int y = 0; y < image.Height; y++)
			{
				for (int x = 0; x < image.Width; x++)
				{
					int value = image.Pixels[y * image.Width + x];
					int top = 2 * y * w + 2 * x;
					outPixels[top] = value;
					outPixels[top + 1] = value;
					outPixels[top + w] = value;
					outPixels[top + w + 1] = value;
				}
			}
			return new GrayImage(w, image.Height * 2, outPixels);
		}

		/// <summary>Resizes by a power-of-two factor; null for another factor or an image too small.</summary>
		public static GrayImage Scale(GrayImage image, double factor)
		{
			if (factor <= 0) return null;
			GrayImage result = image;
			double f = factor;
			while (f > 1)
			{
				result = Double(result);
				f /= 2;
			}
			while (f < 1)
			{
				result = Halve(result, 0, 0);
				if (result == null) return null;
				f *= 2;
			}
			return f == 1 ? result : null;
		}

		// ======================================
		// ======= 2/ Correlation ===============
		// ======================================

		private sealed class Integrals
		{
			public readonly int Stride;
			public readonly long[] Sum;
			public readonly long[] Squares;

			public Integrals(GrayImage image)
			{
				Stride = image.Width + 1;
				Sum = new long[Stride * (image.Height + 1)];
				Squares = new long[Sum.Length];
				for (int y = 1; y <= image.Height; y++)
				{
					long rowSum = 0;
					long rowSquares = 0;
					for (int x = 1; x <= image.Width; x++)
					{
						long v = image.Pixels[(y - 1) * image.Width + x - 1];
						rowSum += v;
						rowSquares += v * v;
						int at = y * Stride + x;
						Sum[at] = Sum[at - Stride] + rowSum;
						Squares[at] = Squares[at - Stride] + rowSquares;
					}
				}
			}

			public long Window(long[] table, int x, int y, int w, int h)
			{
				int top = y * Stride;
				int bottom = (y + h) * Stride;
				return table[bottom + x + w] - table[top + x + w] - table[bottom + x] + table[top + x];
			}
		}

		private sealed class Prepared
		{
			public GrayImage Image;
			public long N;
			public long Sum;
			public long Variance;
		}

		private static Prepared Prepare(GrayImage template)
		{
			long n = (long)template.Width * template.Height;
			long s = 0;
			long ss = 0;
			foreach (int v in template.Pixels)
			{
				s += v;
				ss += (long)v * v;
			}
			long variance = n * ss - s * s;
			if (variance <= 0) return null;
			Prepared prepared = new Prepared();
			prepared.Image = template;
			prepared.N = n;
			prepared.Sum = s;
			prepared.Variance = variance;
			return prepared;
		}

		private static double ScoreAt(GrayImage image, Integrals integrals, Prepared prepared, int x, int y)
		{
			GrayImage t = prepared.Image;
			int[] ip = image.Pixels;
			int[] tp = t.Pixels;
			long cross = 0;
			for (int row = 0; row < t.Height; row++)
			{
				int baseI = (y + row) * image.Width + x;
				int baseT = row * t.Width;
				for (int col = 0; col < t.Width; col++)
				{
					cross += (long)ip[baseI + col] * tp[baseT + col];
				}
			}
			long si = integrals.Window(integrals.Sum, x, y, t.Width, t.Height);
			long windowVariance = prepared.N * integrals.Window(integrals.Squares, x, y, t.Width, t.Height) - si * si;
			if (windowVariance <= 0) return 0;
			double numerator = prepared.N * cross - si * prepared.Sum;
			return numerator / Math.Sqrt((double)windowVariance * (double)prepared.Variance);
		}

		// ======================================
		// ======= 3/ Search ====================
		// ======================================

		private sealed class Candidate
		{
			public int X;
			public int Y;
			public double Score;

			public bool RanksBefore(Candidate other)
			{
				if (Score != other.Score) return Score > other.Score;
				if (Y != other.Y) return Y < other.Y;
				return X < other.X;
			}
		}

		private sealed class Variant
		{
			public GrayImage Image;
			public int Ox;
			public int Oy;
		}

		private static List<Variant> PhaseVariants(GrayImage image, int levels, int minW, int minH)
		{
			List<Variant> result = new List<Variant>();
			if (levels == 0)
			{
				Variant only = new Variant();
				only.Image = image;
				result.Add(only);
				return result;
			}
			for (int oy = 0; oy <= 1; oy++)
			{
				for (int ox = 0; ox <= 1; ox++)
				{
					if ((image.Width - ox) / 2 < minW || (image.Height - oy) / 2 < minH) continue;
					GrayImage half = Halve(image, ox, oy);
					if (half == null) continue;
					foreach (Variant v in PhaseVariants(half, levels - 1, minW, minH))
					{
						Variant moved = new Variant();
						moved.Image = v.Image;
						moved.Ox = ox + 2 * v.Ox;
						moved.Oy = oy + 2 * v.Oy;
						result.Add(moved);
					}
				}
			}
			return result;
		}

		/// <summary>Whether a template can match at all: a flat image matches anywhere.</summary>
		public static bool IsUniform(GrayImage template)
		{
			return Prepare(template) == null;
		}

		/// <summary>The best match across scales, or null; uniform tells a flat template.</summary>
		public static Hit Find(GrayImage image, GrayImage template, MatchOptions options, out bool uniform)
		{
			Integrals integrals = new Integrals(image);
			Dictionary<string, List<Variant>> cache = new Dictionary<string, List<Variant>>();
			Hit best = null;
			bool sawUniform = false;
			foreach (double factor in options.Scales)
			{
				GrayImage scaled = Scale(template, factor);
				if (scaled == null || scaled.Width > image.Width || scaled.Height > image.Height) continue;
				Prepared prepared = Prepare(scaled);
				if (prepared == null)
				{
					sawUniform = true;
					continue;
				}
				Hit hit = FindAtScale(image, integrals, prepared, options, cache);
				if (hit != null && (best == null || hit.Score > best.Score))
				{
					hit.Scale = factor;
					best = hit;
				}
			}
			uniform = best == null && sawUniform;
			return best;
		}

		private static Hit FindAtScale(GrayImage image, Integrals integrals, Prepared prepared, MatchOptions options,
			Dictionary<string, List<Variant>> cache)
		{
			GrayImage t = prepared.Image;
			int levels = 0;
			int factor = 1;
			GrayImage small = t;
			while (Math.Min(small.Width, small.Height) / 2 >= options.CoarseMinPx)
			{
				GrayImage half = Halve(small, 0, 0);
				if (half == null) break;
				small = half;
				levels++;
				factor *= 2;
			}
			int maxX = image.Width - t.Width;
			int maxY = image.Height - t.Height;
			List<int[]> boxes = new List<int[]>();
			if (levels == 0)
			{
				boxes.Add(new int[] { 0, 0, maxX, maxY });
			}
			else
			{
				Prepared coarse = Prepare(small);
				if (coarse == null) return null;
				string key = levels + ":" + small.Width + ":" + small.Height;
				List<Variant> variants;
				if (!cache.TryGetValue(key, out variants))
				{
					variants = PhaseVariants(image, levels, small.Width, small.Height);
					cache[key] = variants;
				}
				double floor = options.Threshold - options.CoarseMargin;
				List<Candidate> kept = new List<Candidate>();
				foreach (Variant v in variants)
				{
					if (v.Image.Width < small.Width || v.Image.Height < small.Height) continue;
					Integrals vi = new Integrals(v.Image);
					for (int y = 0; y <= v.Image.Height - small.Height; y++)
					{
						for (int x = 0; x <= v.Image.Width - small.Width; x++)
						{
							double s = ScoreAt(v.Image, vi, coarse, x, y);
							if (s < floor) continue;
							Candidate candidate = new Candidate();
							candidate.X = v.Ox + x * factor;
							candidate.Y = v.Oy + y * factor;
							candidate.Score = s;
							int index = kept.Count;
							while (index > 0 && candidate.RanksBefore(kept[index - 1])) index--;
							if (index < options.CoarseCandidates)
							{
								kept.Insert(index, candidate);
								if (kept.Count > options.CoarseCandidates) kept.RemoveAt(kept.Count - 1);
							}
						}
					}
				}
				foreach (Candidate c in kept) boxes.Add(new int[] { c.X - 1, c.Y - 1, c.X + 1, c.Y + 1 });
			}
			Hit best = null;
			foreach (int[] box in boxes)
			{
				for (int y = Math.Max(0, box[1]); y <= Math.Min(maxY, box[3]); y++)
				{
					for (int x = Math.Max(0, box[0]); x <= Math.Min(maxX, box[2]); x++)
					{
						double s = ScoreAt(image, integrals, prepared, x, y);
						if (s < options.Threshold) continue;
						if (best != null && !(s > best.Score
							|| (s == best.Score && (y < best.Y || (y == best.Y && x < best.X))))) continue;
						best = new Hit();
						best.X = x;
						best.Y = y;
						best.Width = t.Width;
						best.Height = t.Height;
						best.Score = s;
						best.Scale = 1;
					}
				}
			}
			return best;
		}
	}
}
