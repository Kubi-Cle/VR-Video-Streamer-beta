// Plays a video/music file into the stream with pause and seek, without ever interrupting the stream.
//
//   decoder ffmpeg  --raw frames + PCM (named pipes)-->  PipePlayer  --raw frames + PCM (named pipes)-->  stream ffmpeg
//   (restarted at -ss <pos> on every seek)               (paces 30 fps,                                   (started by
//                                                         repeats last frame + silence while paused)       Start-DesktopStream.ps1 -PipeInput)
//
// Every frame sent goes out together with exactly 1/fps seconds of audio, so the stream's sound and
// picture timestamps come from the same counter and can't drift apart.
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Threading;

public class PipePlayer
{
    // AudioFile: YouTube serves its better qualities as separate video and sound addresses; otherwise empty
    // (PowerShell passes $null to a string as "")
    // Options: what a site needs to hand the video over (some want a particular browser name or referring page)
    class Media { public string File, AudioFile, Options; public double Duration; public bool HasVideo, HasAudio; }

    readonly string ffmpeg, name;
    readonly int w, h, fps, frameBytes, audioBytes;
    Media media;                       // what's playing; replaced as a whole by Load
    public double Duration { get { lock (posLock) return media.Duration; } }

    public volatile bool Loop;
    volatile bool paused, ended, stopping;
    public bool Paused { get { return paused; } }
    public bool Ended { get { lock (posLock) return ended && !playOnLoad; } }   // not once the next file is on its way
    public bool Running { get { return !stopping; } }
    public volatile string LastError = "";
    public volatile int StarvedFrames;  // frames that had to repeat because the next hadn't arrived while playing

    public int Width { get { return w; } }
    public int Height { get { return h; } }
    // The screen shown instead of the last picture while paused or finished. Null = keep the last picture.
    public volatile byte[] Card;
    public bool ShowingCard { get { return Card != null && (paused || ended); } }

    public volatile bool EvenOutVolume;  // takes effect when the decoder next starts, so call Restart after changing it
    public volatile int AudioTrack;      // which of a file's sound tracks; takes effect the same way
    // Styled subtitles (.ass) that need their own fonts and positions, so libass draws them here rather than the
    // plain text of SubtitleOverlay. SubsTrack is which subtitle track of SubsFile, -1 if it's a subtitle file itself.
    // These take effect the same way too, and SubsDelay moves them later in seconds.
    public volatile string SubsFile;
    public volatile int SubsTrack = -1;
    public double SubsDelay;
    int gainPercent = 100;
    public int VolumePercent { get { return Volatile.Read(ref gainPercent); } set { Volatile.Write(ref gainPercent, value); } }

    // Start the decoder again from where it is, for the settings above. The stream itself doesn't notice.
    public void Restart() { if (!ended) Seek(Position); }

    readonly object posLock = new object();
    double pendingSeek = -1;           // >= 0 while a seek is waiting for the pump thread
    double segStart; long segFrames;   // position = segStart + segFrames / fps
    bool previewWanted;                // show one frame after seeking while paused
    bool playOnLoad;                   // a new file was loaded: start playing it even if paused or ended
    bool audioStopped;                 // the file's sound has stopped arriving while its picture continues
    int audioOwed;                     // frames sent with silence because their sound was late; that sound is dropped

    readonly object decLock = new object();
    Process decoder; int decIndex;
    NamedPipeServerStream decV, decA;
    BlockingCollection<byte[]> vq, aq;                     // decoded frames / audio chunks
    readonly BlockingCollection<byte[]> vOut = new BlockingCollection<byte[]>(8);
    readonly BlockingCollection<byte[]> aOut = new BlockingCollection<byte[]>(600);
    readonly ConcurrentBag<byte[]> pool = new ConcurrentBag<byte[]>();
    NamedPipeServerStream pubV, pubA;

    public PipePlayer(string ffmpeg, string file, string audioFile, string options, string name, int w, int h, int fps,
                      double duration, bool hasVideo, bool hasAudio)
    {
        this.ffmpeg = ffmpeg; this.name = name;
        this.w = w; this.h = h; this.fps = fps;
        media = new Media { File = file, AudioFile = audioFile, Options = options, Duration = duration, HasVideo = hasVideo, HasAudio = hasAudio };
        frameBytes = w * h * 3 / 2;          // yuv420p
        audioBytes = 48000 / fps * 4;        // s16le stereo, one frame's worth
    }

    public double Position
    {
        get
        {
            lock (posLock)
            {
                double p = pendingSeek >= 0 ? pendingSeek : segStart + (double)segFrames / fps;
                return media.Duration > 0 ? Math.Min(p, media.Duration) : p;
            }
        }
    }

    public void Play() { if (ended) Seek(0); paused = false; }
    public void Pause() { paused = true; }
    public void Seek(double seconds)
    {
        lock (posLock)
        {
            if (media.Duration > 0) seconds = Math.Min(seconds, Math.Max(0, media.Duration - 0.25));
            pendingSeek = Math.Max(0, seconds);
        }
        ended = false;
    }

    // Switch to another file from its start. Only the decoder restarts: the stream's frames keep flowing,
    // so viewers and every link stay connected.
    public void Load(string file, string audioFile, string options, double duration, bool hasVideo, bool hasAudio)
    {
        LastError = "";
        AudioTrack = 0;
        SubsFile = null;
        lock (posLock)
        {
            media = new Media { File = file, AudioFile = audioFile, Options = options, Duration = duration, HasVideo = hasVideo, HasAudio = hasAudio };
            playOnLoad = true;
            pendingSeek = 0;
        }
    }

    public void Start()
    {
        pubV = new NamedPipeServerStream(name + "-v", PipeDirection.Out, 1, PipeTransmissionMode.Byte, PipeOptions.None, 0, frameBytes * 2);
        pubA = new NamedPipeServerStream(name + "-a", PipeDirection.Out, 1, PipeTransmissionMode.Byte, PipeOptions.None, 0, 1 << 20);
        StartWriter(pubV, vOut, true);
        StartWriter(pubA, aOut, false);
        new Thread(Pump) { IsBackground = true, Name = "PipePlayer pump" }.Start();
    }

    public void Stop()
    {
        stopping = true;
        KillDecoder();
        vOut.CompleteAdding(); aOut.CompleteAdding();
        try { pubV.Dispose(); } catch { }
        try { pubA.Dispose(); } catch { }
    }

    byte[] Rent() { byte[] b; return pool.TryTake(out b) ? b : new byte[frameBytes]; }
    void Return(byte[] b) { if (b != null && b.Length == frameBytes && pool.Count < 24) pool.Add(b); }

    void Pump()
    {
        byte[] black = new byte[frameBytes];
        for (int i = 0; i < w * h; i++) black[i] = 16;            // Y = black
        for (int i = w * h; i < frameBytes; i++) black[i] = 128;  // U, V = no colour
        byte[] silence = new byte[audioBytes];
        byte[] last = black;
        try
        {
            StartDecoder(0);
            var clock = Stopwatch.StartNew();
            long tick = 0;
            while (!stopping)
            {
                double target;
                bool loaded;
                lock (posLock) { target = pendingSeek; loaded = playOnLoad; playOnLoad = false; }
                if (loaded) { paused = false; ended = false; }
                if (target >= 0) { StartDecoder(target); previewWanted = paused; audioStopped = false; }

                byte[] v = null, a = null;
                var q = vq; var qa = aq;
                if ((!paused || previewWanted) && q != null)
                {
                    if (q.TryTake(out v))
                    {
                        // Each frame is paired with its own slice of audio; wait for it rather than drift. But not
                        // every time: if a file's sound stops before its picture, this would crawl at a frame per wait.
                        // Slice N belongs to frame N. When a frame had to go out silent (an online video's sound
                        // connection stalled), its slice is thrown away when it turns up, or it would be paired with
                        // the next frame and every sound after it would stay late for the rest of the video.
                        int wait = audioStopped ? 0 : 3000;
                        byte[] stale;
                        while (audioOwed > 0 && qa.TryTake(out stale, wait)) audioOwed--;
                        bool gotAudio = audioOwed == 0 && qa.TryTake(out a, wait);
                        if (gotAudio) audioStopped = false;
                        else if (qa.IsCompleted) { Return(v); v = null; HandleEnd(); }
                        else { audioStopped = true; audioOwed++; }
                        if (v != null)
                        {
                            if (previewWanted) { a = null; previewWanted = false; }
                            double played, length; bool generated;
                            lock (posLock)
                            {
                                segFrames++;
                                played = segStart + (double)segFrames / fps;
                                length = media.Duration;
                                generated = !media.HasVideo || !media.HasAudio;
                            }
                            if (last != black) Return(last);
                            last = v;
                            // A made-up picture or silence never runs out by itself, so the clock has to end the file
                            if (generated && length > 0 && played >= length) HandleEnd();
                        }
                    }
                    else if (q.IsCompleted || (qa.IsCompleted && qa.Count == 0)) HandleEnd();
                    else { lock (posLock) if (segFrames > fps) StarvedFrames++; }   // a wait right after starting or seeking is normal
                }

                byte[] frame = Rent();
                byte[] card = Card;
                Buffer.BlockCopy(card != null && card.Length == frameBytes && (paused || ended) ? card : last, 0, frame, 0, frameBytes);
                vOut.Add(frame);
                bool hasSound = v != null && a != null;
                if (hasSound) ApplyVolume(a);
                aOut.Add(hasSound ? a : silence);

                // Real-time pacing; if we fall far behind (stalled output), start counting again from now
                tick++;
                long due = tick * 1000 / fps, now = clock.ElapsedMilliseconds;
                if (due > now) Thread.Sleep((int)(due - now));
                else if (now - due > 1000) { clock.Restart(); tick = 0; }
            }
        }
        catch (Exception e) { if (!stopping) LastError = e.Message; }
        finally { stopping = true; KillDecoder(); }
    }

    // Done here rather than in the decoder, so the slider acts at once and never restarts anything
    void ApplyVolume(byte[] pcm)
    {
        int gain = VolumePercent;
        if (gain == 100) return;
        for (int i = 0; i + 1 < pcm.Length; i += 2)
        {
            int sample = (short)(pcm[i] | (pcm[i + 1] << 8)) * gain / 100;
            if (sample > short.MaxValue) sample = short.MaxValue; else if (sample < short.MinValue) sample = short.MinValue;
            pcm[i] = (byte)sample;
            pcm[i + 1] = (byte)(sample >> 8);
        }
    }

    void HandleEnd()
    {
        if (Loop) { Seek(0); return; }
        KillDecoder();
        ended = true; paused = true;
    }

    void StartDecoder(double pos)
    {
        lock (decLock)
        {
            KillDecoderLocked();
            // Taken together, so a Load or Seek arriving after this point is picked up on the next tick
            Media m;
            lock (posLock) { m = media; segStart = pos; segFrames = 0; pendingSeek = -1; }
            audioOwed = 0;
            decIndex++;
            string dv = name + "-d" + decIndex + "-v", da = name + "-d" + decIndex + "-a";
            decV = new NamedPipeServerStream(dv, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.None, frameBytes * 2, 0);
            decA = new NamedPipeServerStream(da, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.None, 4 << 20, 0);
            vq = new BlockingCollection<byte[]>(8);
            aq = new BlockingCollection<byte[]>(600);
            StartReader(decV, frameBytes, vq, true);
            StartReader(decA, audioBytes, aq, false);

            string ss = pos.ToString("0.###", CultureInfo.InvariantCulture);
            if (m.Duration <= 0) ss = null;   // a live video has nowhere to seek to, and trying only stalls it
            string inputs = InputArgs(ss, m.Options, m.File);
            string vmap = "0:v:0", amap = "0:a:" + AudioTrack;
            int next = 1;
            if (!string.IsNullOrEmpty(m.AudioFile)) { inputs += " " + InputArgs(ss, m.Options, m.AudioFile); amap = (next++) + ":a:0"; }
            if (!m.HasVideo) { inputs += " -f lavfi -i color=c=black:s=" + w + "x" + h + ":r=" + fps; vmap = (next++) + ":v"; }
            if (!m.HasAudio) { inputs += " -f lavfi -i anullsrc=r=48000:cl=stereo"; amap = (next++) + ":a"; }
            // fps start_time=0 and aresample first_pts=0 both start at the seek point, so frame N and
            // audio chunk N always cover the same moment. The picture is fitted into the stream's fixed
            // size (black bars if the shape differs), so any file can follow any other.
            string subsFile = SubsFile, subsFolder;
            string subsFilter = SubsFilter(subsFile, SubsTrack, pos, out subsFolder);
            string args = "-nostdin -hide_banner -loglevel error " + inputs +
                " -map " + vmap + " -vf \"fps=" + fps + ":start_time=0,scale=" + w + ":" + h +
                ":force_original_aspect_ratio=decrease:force_divisible_by=2" + subsFilter + ",pad=" + w + ":" + h +
                ":(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p\"" +
                " -f rawvideo -y \\\\.\\pipe\\" + dv +
                // dynaudnorm's settings keep how far it looks ahead to about half a second, so a video still starts promptly
                " -map " + amap + " -af \"" + (EvenOutVolume ? "dynaudnorm=f=150:g=7:p=0.9:m=8," : "") + "aresample=48000:async=1:first_pts=0\" -ac 2 -f s16le -y \\\\.\\pipe\\" + da;

            var psi = new ProcessStartInfo(ffmpeg, args)
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true
            };
            if (subsFolder != null) psi.WorkingDirectory = subsFolder;
            var p = new Process { StartInfo = psi };
            p.ErrorDataReceived += (s, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) LastError = e.Data; };
            p.Start();
            p.BeginErrorReadLine();
            decoder = p;
        }
    }

    // The filter drawing styled subtitles, after scaling so positions match the picture and before the black bars.
    // Seeking restarts the picture's time at 0, so it's moved back to the film's time just for this filter. Given
    // a video, the filter also loads the fonts embedded in it. The file is named relative to its folder, so a
    // drive's colon never has to survive the filter's rules.
    string SubsFilter(string file, int track, double pos, out string folder)
    {
        folder = null;
        if (string.IsNullOrEmpty(file)) return "";
        folder = Path.GetDirectoryName(file);
        string options = "filename=" + FilterValue(Path.GetFileName(file));
        if (track >= 0) options += ":si=" + track;
        if (Directory.Exists(Path.Combine(folder, "fonts"))) options += ":fontsdir=fonts";
        string at = (pos - SubsDelay).ToString("0.###", CultureInfo.InvariantCulture);
        return ",setpts=PTS+(" + at + ")/TB,subtitles=" + options + ",setpts=PTS-(" + at + ")/TB";
    }

    // A name has to survive two rounds of ffmpeg's escaping: one for the filter's option, one for the filter graph
    static string FilterValue(string s)
    {
        s = s.Replace("\\", "\\\\").Replace("'", "\\'").Replace(":", "\\:");
        return s.Replace("\\", "\\\\").Replace("'", "\\'").Replace("[", "\\[").Replace("]", "\\]").Replace(",", "\\,").Replace(";", "\\;");
    }

    // Addresses on the internet get to reconnect after a dropped connection instead of ending the video early
    static string InputArgs(string ss, string options, string file)
    {
        bool online = file.StartsWith("http", StringComparison.OrdinalIgnoreCase);
        string net = online ? " -reconnect 1 -reconnect_streamed 1 -reconnect_on_network_error 1 -reconnect_delay_max 5" : "";
        // Full path, since the decoder's own folder can be the subtitles' rather than this program's
        if (!online) file = Path.GetFullPath(file);
        return (ss != null ? "-ss " + ss : "") + net + (string.IsNullOrEmpty(options) ? "" : " " + options) + " -i \"" + file + "\"";
    }

    void KillDecoder() { lock (decLock) KillDecoderLocked(); }

    void KillDecoderLocked()
    {
        if (decoder != null) { try { if (!decoder.HasExited) decoder.Kill(); } catch { } decoder.Dispose(); decoder = null; }
        foreach (var q in new[] { vq, aq })
            if (q != null) { try { q.CompleteAdding(); } catch { } byte[] b; while (q.TryTake(out b)) Return(b); }
        try { if (decV != null) decV.Dispose(); } catch { }
        try { if (decA != null) decA.Dispose(); } catch { }
        decV = decA = null;
    }

    void StartReader(NamedPipeServerStream s, int chunk, BlockingCollection<byte[]> q, bool pooled)
    {
        new Thread(() =>
        {
            try
            {
                s.WaitForConnection();
                while (true)
                {
                    byte[] buf = pooled ? Rent() : new byte[chunk];
                    int got = 0;
                    while (got < chunk) { int n = s.Read(buf, got, chunk - got); if (n <= 0) break; got += n; }
                    if (got < chunk) { if (pooled) Return(buf); break; }
                    q.Add(buf);
                }
            }
            catch { }
            finally { try { q.CompleteAdding(); } catch { } }
        }) { IsBackground = true, Name = "PipePlayer reader" }.Start();
    }

    void StartWriter(NamedPipeServerStream s, BlockingCollection<byte[]> q, bool pooled)
    {
        new Thread(() =>
        {
            try
            {
                s.WaitForConnection();
                foreach (var b in q.GetConsumingEnumerable())
                {
                    s.Write(b, 0, b.Length);
                    if (pooled) Return(b);
                }
            }
            catch (Exception e)
            {
                if (!stopping) { LastError = "Stream stopped reading: " + e.Message; Stop(); }
            }
        }) { IsBackground = true, Name = "PipePlayer writer" }.Start();
    }
}
