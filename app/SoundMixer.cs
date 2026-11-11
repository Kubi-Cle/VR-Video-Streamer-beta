// Mixes the chosen sound sources into one pipe the stream ffmpeg reads for the whole stream, so sources can be
// added and removed while it runs. ffmpeg can't gain or lose an input once started, and a video player can't
// gain a sound track partway through, so the pipe always runs, as silence if nothing is chosen.
//
//   ProcessAudioCapture / DeviceAudioCapture  --s16le pipes-->  SoundMixer  --f32le pipe, real-time-->  stream ffmpeg
//
// The sources to use are read from a text file the window rewrites: one "app:<process id>" or "dev:<device name>"
// per line, with a tab and "quiet" after a program to silence on this PC (SessionQuiet.cs), and a tab and "vol=0.5"
// for its own volume. A "delay=<ms>" line holds all the sound back by that much more, for when it's ahead of the
// picture. Sound stays as floats until ffmpeg's limiter, so a loud mix isn't clipped here.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Threading;

public class SoundMixer
{
    const int Rate = 48000, Channels = 2;
    const int BlockFrames = Rate / 10;
    const float FadeStep = 1f / (Rate / 100);   // 10 ms fade in and out, so changing sources doesn't click
    const int MaxDelayFrames = Rate;             // the delay setting goes up to 1 s

    class Source
    {
        public string Key;
        public Action Stop;
        public Func<string> Error;
        public string Reported = "";
        public readonly object Lock = new object();
        public float[] Ring;         // interleaved left, right
        public int Start, Count;     // in frames
        public bool Playing;
        public float Gain, Target = 1f;
        public bool Wanted = true;   // still ticked; at volume 0 it's wanted but silent, so it mustn't be closed
        public float Volume = 1f;
        public volatile bool Closed;
        public int FrameBytes = 4;   // devices send 16-bit, programs send floats
        public volatile bool Quiet;
        public int ProcessId;
        public volatile float DeviceGain = 1f;   // makes up for the device it plays on (SessionQuiet.DeviceGain)
        public bool GainKnown;
    }

    readonly string ffmpeg, pipeName, controlFile, quietFile;
    readonly int holdFrames, maxFrames;
    readonly Dictionary<string, Source> sources = new Dictionary<string, Source>();
    NamedPipeServerStream pipe;
    string lastControl;
    int pipeCount;
    volatile bool stopping;
    volatile int delayFrames;
    readonly float[] delayRing = new float[(MaxDelayFrames + BlockFrames + 16) * Channels];
    int delayStart, delayCount;

    // holdMs is how long sound is held back: it keeps sound in step with the picture and covers uneven delivery
    public SoundMixer(string ffmpeg, string pipeName, string controlFile, string quietFile, int holdMs)
    {
        this.ffmpeg = ffmpeg; this.pipeName = pipeName; this.controlFile = controlFile; this.quietFile = quietFile;
        holdFrames = Rate * holdMs / 1000;
        maxFrames = holdFrames + Rate / 10;
    }

    public void Start(string[] initial)
    {
        pipe = new NamedPipeServerStream(pipeName, PipeDirection.Out, 1, PipeTransmissionMode.Byte, PipeOptions.None, 0, 1 << 20);
        Apply(initial);
        ReadControl();
        new Thread(MixLoop) { IsBackground = true, Name = "SoundMixer" }.Start();
        new Thread(QuietLoop) { IsBackground = true, Name = "SoundMixer quiet" }.Start();
    }

    public void Stop()
    {
        stopping = true;
        lock (sources) { foreach (var s in sources.Values) { s.Closed = true; try { s.Stop(); } catch { } } }
        try { pipe.Dispose(); } catch { }
    }

    // Separate from the mixing, so asking Windows about programs can never hold up the sound
    void QuietLoop()
    {
        string lastProblem = "";
        SessionQuiet quiet = null;
        int round = 0;
        while (!stopping)
        {
            try
            {
                var ids = new List<int>();
                var programs = new List<Source>();
                lock (sources)
                {
                    foreach (var s in sources.Values)
                    {
                        if (s.ProcessId == 0) continue;
                        programs.Add(s);
                        if (s.Quiet && s.Wanted) ids.Add(s.ProcessId);
                    }
                }
                // A program can move to another device at any time, so this keeps being checked, though not as often
                round++;
                foreach (var s in programs)
                {
                    if (s.GainKnown && round % 4 != 0) continue;
                    float gain = SessionQuiet.DeviceGain(s.ProcessId);
                    if (gain > 0f) { s.DeviceGain = gain; s.GainKnown = true; }
                }
                if (!string.IsNullOrEmpty(quietFile))
                {
                    if (quiet == null) quiet = new SessionQuiet(quietFile);
                    quiet.Update(ids.ToArray());
                }
                lastProblem = "";
            }
            catch (Exception e)
            {
                if (e.Message != lastProblem) { lastProblem = e.Message; Report("mute", e.Message); }
            }
            Thread.Sleep(250);
        }
    }

    void ReadControl()
    {
        if (string.IsNullOrEmpty(controlFile)) return;
        try
        {
            string text = File.ReadAllText(controlFile);
            if (text == lastControl) return;
            lastControl = text;
            Apply(text.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries));
        }
        catch (IOException) { }                  // being replaced this moment, or not there: look again shortly
        catch (UnauthorizedAccessException) { }
    }

    void Apply(string[] wanted)
    {
        var keep = new HashSet<string>();
        var quiet = new HashSet<string>();
        var volumes = new Dictionary<string, float>();
        int delay = 0;
        foreach (string line in wanted)
        {
            if (line.StartsWith("delay="))
            {
                int ms;
                if (int.TryParse(line.Substring(6), out ms)) delay = Math.Max(0, Math.Min(MaxDelayFrames, ms * (Rate / 1000)));
                continue;
            }
            string[] parts = line.Split('\t');
            keep.Add(parts[0]);
            for (int i = 1; i < parts.Length; i++)
            {
                float v;
                if (parts[i] == "quiet") quiet.Add(parts[0]);
                else if (parts[i].StartsWith("vol=") && float.TryParse(parts[i].Substring(4), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out v))
                    volumes[parts[0]] = Math.Max(0f, Math.Min(4f, v));
            }
        }
        delayFrames = delay;
        lock (sources)
        {
            foreach (string key in keep)
            {
                if (sources.ContainsKey(key)) continue;
                var s = Open(key);
                if (s != null) sources[key] = s;
            }
            foreach (var s in sources.Values)
            {
                float v;
                s.Wanted = keep.Contains(s.Key);
                s.Volume = volumes.TryGetValue(s.Key, out v) ? v : 1f;
                s.Target = s.Wanted ? s.Volume : 0f;
                s.Quiet = quiet.Contains(s.Key);
            }
        }
    }

    Source Open(string key)
    {
        string name = pipeName + "-" + (pipeCount++);
        var s = new Source { Key = key, Ring = new float[(maxFrames + BlockFrames) * Channels] };
        try
        {
            int id;
            if (key.StartsWith("app:") && int.TryParse(key.Substring(4), out id))
            {
                var capture = new ProcessAudioCapture(id, name);
                s.Stop = capture.Stop;
                s.Error = () => capture.LastError;
                s.FrameBytes = 8;
                s.ProcessId = id;
                capture.Start();
            }
            else if (key.StartsWith("dev:"))
            {
                var capture = new DeviceAudioCapture(ffmpeg, key.Substring(4), name);
                s.Stop = capture.Stop;
                s.Error = () => capture.LastError;
                capture.Start();
            }
            else return null;
            var reader = new Thread(() => ReadSource(s, name)) { IsBackground = true, Name = "SoundMixer reader" };
            reader.SetApartmentState(ApartmentState.MTA);
            reader.Start();
            return s;
        }
        catch (Exception e) { Report(key, e.Message); return null; }
    }

    void ReadSource(Source s, string name)
    {
        try
        {
            using (var input = new NamedPipeClientStream(".", name, PipeDirection.In))
            {
                input.Connect(5000);
                byte[] bytes = new byte[9600];
                int held = 0;   // bytes of an unfinished sample frame kept at the start of the buffer
                bool floats = s.FrameBytes == 8;
                float[] samples = new float[bytes.Length / 2];
                while (!s.Closed && !stopping)
                {
                    int n = input.Read(bytes, held, bytes.Length - held);
                    if (n <= 0) break;
                    n += held;
                    int frames = n / s.FrameBytes;
                    for (int i = 0; i < frames * 2; i++)
                        samples[i] = floats ? BitConverter.ToSingle(bytes, i * 4) : BitConverter.ToInt16(bytes, i * 2) / 32768f;
                    float gain = (s.Quiet ? QuietGain(samples, frames * 2) : 1f) * s.DeviceGain;
                    lock (s.Lock)
                    {
                        for (int i = 0; i < frames; i++)
                        {
                            if (s.Count == maxFrames)   // running late: drop back to the normal hold, not one frame at a time
                            {
                                int drop = s.Count - holdFrames;
                                s.Start = (s.Start + drop) % maxFrames;
                                s.Count = holdFrames;
                            }
                            int at = (s.Start + s.Count) % maxFrames;
                            s.Ring[at * 2] = samples[i * 2] * gain;
                            s.Ring[at * 2 + 1] = samples[i * 2 + 1] * gain;
                            s.Count++;
                        }
                    }
                    held = n - frames * s.FrameBytes;
                    if (held > 0) Buffer.BlockCopy(bytes, frames * s.FrameBytes, bytes, 0, held);
                }
            }
        }
        catch (Exception e) { if (!s.Closed && !stopping) Report(s.Key, e.Message); }
    }

    // A program that really is turned down gets boosted back. One that isn't yet, or was turned up again (just
    // ticked, a new sound starting, someone moving Windows' slider) mustn't be, or viewers would get it 10,000
    // times too loud. Sound that would go well past full scale can only be that, so it's passed on as it is.
    static float QuietGain(float[] samples, int count)
    {
        float peak = 0f;
        for (int i = 0; i < count; i++)
        {
            float v = Math.Abs(samples[i]);
            if (v > peak) peak = v;
        }
        return peak * SessionQuiet.Boost > 1.5f ? 1f : SessionQuiet.Boost;
    }

    void MixLoop()
    {
        try
        {
            pipe.WaitForConnection();   // the stream ffmpeg opened the pipe: sound time 0 starts now
            var clock = Stopwatch.StartNew();
            long written = 0;
            int ticks = 0;
            float[] mix = new float[BlockFrames * Channels];
            byte[] output = new byte[mix.Length * 4];
            while (!stopping)
            {
                if (++ticks % 25 == 0) { ReadControl(); CheckSources(); }
                long due = clock.ElapsedTicks * Rate / Stopwatch.Frequency - written;
                while (due > 0)
                {
                    int frames = (int)Math.Min(due, BlockFrames);
                    Array.Clear(mix, 0, frames * Channels);
                    lock (sources) { foreach (var s in sources.Values) AddTo(mix, frames, s); }
                    Delay(mix, frames);
                    Buffer.BlockCopy(mix, 0, output, 0, frames * Channels * 4);
                    pipe.Write(output, 0, frames * Channels * 4);
                    written += frames;
                    due -= frames;
                }
                Thread.Sleep(10);
            }
        }
        catch (Exception) { }   // ffmpeg closed: the stream is over
    }

    void AddTo(float[] mix, int frames, Source s)
    {
        lock (s.Lock)
        {
            if (!s.Playing && s.Count >= holdFrames) s.Playing = true;   // also after running out: hold back again
            if (!s.Playing)
            {
                if (!s.Wanted) s.Gain = 0f;
                return;
            }
            int n = Math.Min(frames, s.Count);
            for (int i = 0; i < n; i++)
            {
                if (s.Gain < s.Target) s.Gain = Math.Min(s.Target, s.Gain + FadeStep);
                else if (s.Gain > s.Target) s.Gain = Math.Max(s.Target, s.Gain - FadeStep);
                int at = (s.Start + i) % maxFrames;
                mix[i * 2] += s.Ring[at * 2] * s.Gain;
                mix[i * 2 + 1] += s.Ring[at * 2 + 1] * s.Gain;
            }
            s.Start = (s.Start + n) % maxFrames;
            s.Count -= n;
            if (s.Count == 0) s.Playing = false;
            // A program's sound clock never quite matches this one, so its queue creeps up. Trimming it back once
            // it's 40 ms over keeps the delay steady, instead of drifting up to 100 ms late and then jumping back.
            if (s.Count > holdFrames + Rate / 25)
            {
                s.Start = (s.Start + s.Count - holdFrames) % maxFrames;
                s.Count = holdFrames;
            }
        }
    }

    // Holds the mix back by the delay setting. When it's raised, silence fills the gap; when lowered, the extra is
    // dropped. Either is a short jump, heard only while someone is moving the slider.
    void Delay(float[] mix, int frames)
    {
        int target = delayFrames;
        if (target == 0 && delayCount == 0) return;
        int capacity = delayRing.Length / Channels;
        if (delayCount > target) { delayStart = (delayStart + delayCount - target) % capacity; delayCount = target; }
        for (int i = 0; i < frames; i++)
        {
            int at = (delayStart + delayCount + i) % capacity;
            delayRing[at * 2] = mix[i * 2];
            delayRing[at * 2 + 1] = mix[i * 2 + 1];
        }
        delayCount += frames;
        int pad = Math.Min(frames, Math.Max(0, target + frames - delayCount));
        Array.Clear(mix, 0, pad * Channels);
        for (int i = pad; i < frames; i++)
        {
            mix[i * 2] = delayRing[delayStart * 2];
            mix[i * 2 + 1] = delayRing[delayStart * 2 + 1];
            delayStart = (delayStart + 1) % capacity;
            delayCount--;
        }
    }

    // Close sources that have faded out, and say so once if one has a problem
    void CheckSources()
    {
        List<Source> finished = null;
        lock (sources)
        {
            foreach (var s in sources.Values)
            {
                string error = s.Error();
                if (s.Wanted && !string.IsNullOrEmpty(error) && error != s.Reported) { s.Reported = error; Report(s.Key, error); }
                if (!s.Wanted && s.Gain == 0f) { if (finished == null) finished = new List<Source>(); finished.Add(s); }
            }
            if (finished != null) foreach (var s in finished) sources.Remove(s.Key);
        }
        if (finished != null) foreach (var s in finished)
        {
            s.Closed = true;
            try { s.Stop(); } catch { }
        }
    }

    static void Report(string key, string message)
    {
        try { Console.Out.WriteLine("Sound problem [" + key + "]: " + message); Console.Out.Flush(); } catch { }
    }
}
