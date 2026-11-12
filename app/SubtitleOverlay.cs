// Shows an .srt file on the stream, for every kind of source (file, YouTube, monitor, program window).
//
//   SubtitleOverlay  --current line, in a small text file-->  drawtext in the stream's ffmpeg (reload=1)
//
// VR video players have no subtitle track, so the words have to be drawn into the picture. Doing that
// in the stream's ffmpeg rather than the decoder means subtitles can be added, changed and re-timed at any
// moment without touching the video. The clock is the player's position for files and YouTube; a capture has
// no position, so it gets a plain clock that can be paused and restarted to line up with what's on screen.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public class SubtitleOverlay
{
    class Cue { public double Start, End; public string Text; }

    // ffmpeg re-reads the file on every frame and stops with an error if it can't, so the file is never
    // replaced or shortened: same size, written in place, with NULs after the text (where drawtext stops reading)
    const int FileBytes = 1024;
    const int MaxLineChars = 48;
    const int MaxLines = 4;

    readonly string textFile;
    readonly object gate = new object();
    List<Cue> cues = new List<Cue>();
    double offset;
    readonly Stopwatch clock = new Stopwatch();
    double clockBase;
    string written;
    int checks;
    volatile bool stopping;

    public volatile PipePlayer Player;   // null = use the plain clock

    public SubtitleOverlay(string textFile) { this.textFile = textFile; }

    public int Count { get { lock (gate) return cues.Count; } }
    public double Offset { get { lock (gate) return offset; } set { lock (gate) offset = value; } }
    public bool ClockPaused { get { lock (gate) return !clock.IsRunning; } }
    public double ClockPosition { get { lock (gate) return clockBase + clock.Elapsed.TotalSeconds; } }

    public void Start()
    {
        WriteText("");   // ffmpeg needs the file to exist from the moment it starts
        new Thread(Run) { IsBackground = true, Name = "SubtitleOverlay" }.Start();
    }

    public void Stop()
    {
        stopping = true;
        try { File.Delete(textFile); } catch { }
    }

    // Throws if the file holds no subtitles. Nothing changes in that case.
    public void Load(string srtFile)
    {
        var parsed = Parse(ReadText(srtFile));
        if (parsed.Count == 0) throw new InvalidDataException("No subtitles found in that file.");
        lock (gate) { cues = parsed; offset = 0; }
        RestartClock();
    }

    public void Clear() { lock (gate) { cues = new List<Cue>(); offset = 0; } }

    // For a file that's still being written: new lines appear, and the timing and clock stay as they are
    public void Update(string srtFile)
    {
        var parsed = Parse(ReadText(srtFile));
        lock (gate) cues = parsed;
    }

    // Where the subtitles so far run up to, in seconds
    public double LastCueEnd { get { lock (gate) return cues.Count > 0 ? cues[cues.Count - 1].End : 0; } }

    // OpenSubtitles' fingerprint of a video file, for finding subtitles made for exactly this copy: its size
    // plus the 64-bit sum of its first and last 64 KB
    public static string FileHash(string file)
    {
        const int Part = 65536;
        using (var f = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            unchecked
            {
                ulong sum = (ulong)f.Length;
                foreach (long start in new[] { 0L, Math.Max(0, f.Length - Part) })
                {
                    f.Position = start;
                    var bytes = new byte[Part];
                    int got = 0, n;
                    while (got < Part && (n = f.Read(bytes, got, Part - got)) > 0) got += n;
                    for (int i = 0; i + 8 <= got; i += 8) sum += BitConverter.ToUInt64(bytes, i);
                }
                return sum.ToString("x16");
            }
        }
    }

    public void RestartClock() { lock (gate) { clockBase = 0; clock.Restart(); } }
    public void PauseClock() { lock (gate) clock.Stop(); }
    public void ResumeClock() { lock (gate) clock.Start(); }

    void Run()
    {
        while (!stopping)
        {
            try
            {
                string text = CurrentText();
                // A failed write tries again next time round; a file something deleted is written again, since
                // the stream's ffmpeg rereads it and can't carry on without it
                if (text != written || ++checks % 25 == 0 && !File.Exists(textFile)) WriteText(text);
            }
            catch (Exception) { }                       // an error on this thread would close the whole program
            Thread.Sleep(40);
        }
    }

    string CurrentText()
    {
        var player = Player;
        if (player != null && player.ShowingCard) return "";   // no words over the intermission screen
        double position = player != null ? player.Position : ClockPosition;
        lock (gate)
        {
            double at = position - offset;
            string text = "";
            foreach (var cue in cues)
            {
                if (cue.Start > at) break;   // sorted by start time
                if (at < cue.End) text = text.Length == 0 ? cue.Text : text + "\n" + cue.Text;
            }
            return text;
        }
    }

    void WriteText(string text)
    {
        var bytes = new byte[FileBytes];
        // Only several overlapping lines could ever be this long
        string fits = Encoding.UTF8.GetByteCount(text) < FileBytes ? text : text.Substring(0, FileBytes / 4);
        Encoding.UTF8.GetBytes(fits, 0, fits.Length, bytes, 0);
        try
        {
            using (var f = new FileStream(textFile, FileMode.OpenOrCreate, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
                f.Write(bytes, 0, bytes.Length);
            written = text;
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    static readonly Regex Promotion = new Regex(@"opensubtitles\.(org|com)|osdb\.link|become vip|remove all ads|www\.\S+|https?://", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    // OpenSubtitles adds a few promotional entries to its free files, and some uploaders add their own web addresses.
    // This takes those out and saves the file as UTF-8. A film's line that really says a web address goes too, which is
    // rare. Only short entries count, in case a file with no gaps between entries reads as one long one.
    // Returns how many were removed.
    public static int RemoveAds(string srtFile)
    {
        string[] entries = Regex.Split(ReadText(srtFile).Replace("\r\n", "\n").Replace('\r', '\n'), @"\n[ \t]*\n");
        var kept = new List<string>();
        int removed = 0;
        foreach (string entry in entries)
        {
            if (Promotion.IsMatch(entry) && entry.Split('\n').Length <= 6) removed++;
            else if (entry.Trim().Length > 0) kept.Add(entry.Trim());
        }
        File.WriteAllText(srtFile, string.Join("\n\n", kept.ToArray()) + "\n", new UTF8Encoding(false));
        return removed;
    }

    // Subtitle files are often not UTF-8: use the marked encoding, then UTF-8 if it's valid, then the PC's own
    static string ReadText(string file)
    {
        byte[] b;
        using (var f = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))   // may still be being written
        {
            b = new byte[f.Length];
            int got = 0, n;
            while (got < b.Length && (n = f.Read(b, got, b.Length - got)) > 0) got += n;
        }
        if (b.Length >= 2 && b[0] == 0xFF && b[1] == 0xFE) return Encoding.Unicode.GetString(b, 2, b.Length - 2);
        if (b.Length >= 2 && b[0] == 0xFE && b[1] == 0xFF) return Encoding.BigEndianUnicode.GetString(b, 2, b.Length - 2);
        if (b.Length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) return Encoding.UTF8.GetString(b, 3, b.Length - 3);
        try { return new UTF8Encoding(false, true).GetString(b); }
        catch (ArgumentException) { return Encoding.Default.GetString(b); }
    }

    static readonly Regex Timing = new Regex(@"(\d+):(\d\d):(\d\d)[,.](\d{1,3})\s*-->\s*(\d+):(\d\d):(\d\d)[,.](\d{1,3})", RegexOptions.Compiled);

    static double Seconds(Match m, int first)
    {
        var ms = m.Groups[first + 3].Value.PadRight(3, '0');
        return int.Parse(m.Groups[first].Value, CultureInfo.InvariantCulture) * 3600
             + int.Parse(m.Groups[first + 1].Value, CultureInfo.InvariantCulture) * 60
             + int.Parse(m.Groups[first + 2].Value, CultureInfo.InvariantCulture)
             + int.Parse(ms, CultureInfo.InvariantCulture) / 1000.0;
    }

    static List<Cue> Parse(string srt)
    {
        var parsed = new List<Cue>();
        string[] lines = srt.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        for (int i = 0; i < lines.Length; i++)
        {
            Match m = Timing.Match(lines[i]);
            if (!m.Success) continue;
            var text = new List<string>();
            for (i++; i < lines.Length && lines[i].Trim().Length > 0; i++)
            {
                if (Timing.IsMatch(lines[i])) { i--; break; }   // a file with no blank line between entries
                text.Add(lines[i].Trim());
            }
            // Without a blank line, the next entry's number ends up here too
            if (i + 1 < lines.Length && text.Count > 1 && Regex.IsMatch(text[text.Count - 1], @"^\d+$") && Timing.IsMatch(lines[i + 1]))
                text.RemoveAt(text.Count - 1);
            string clean = Clean(text);
            if (clean.Length > 0) parsed.Add(new Cue { Start = Seconds(m, 1), End = Seconds(m, 5), Text = clean });
        }
        parsed.Sort((a, b) => a.Start.CompareTo(b.Start));
        // Lines that overlap by a blink (AI-made ones do) would flash up together
        for (int i = 0; i + 1 < parsed.Count; i++)
            if (parsed[i].End > parsed[i + 1].Start && parsed[i].End - parsed[i + 1].Start < 0.2) parsed[i].End = parsed[i + 1].Start;
        return parsed;
    }

    // No styling tags, and lines short enough to fit, because drawtext shows them literally and never wraps
    static string Clean(List<string> lines)
    {
        var fitted = new List<string>();
        foreach (string raw in lines)
        {
            string line = Regex.Replace(raw, @"<[^>]*>|\{[^}]*\}", "");
            line = WebUtility.HtmlDecode(line).Replace("\\N", " ").Trim();
            while (line.Length > MaxLineChars)
            {
                int cut = line.LastIndexOf(' ', MaxLineChars);
                if (cut <= 0) cut = MaxLineChars;
                fitted.Add(line.Substring(0, cut).TrimEnd());
                line = line.Substring(cut).TrimStart();
            }
            if (line.Length > 0) fitted.Add(line);
        }
        if (fitted.Count > MaxLines) fitted.RemoveRange(MaxLines, fitted.Count - MaxLines);
        return string.Join("\n", fitted.ToArray());
    }
}
