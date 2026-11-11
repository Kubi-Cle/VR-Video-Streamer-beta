// Keeps a live capture streaming at a steady frame rate even when the source stops producing pictures.
//
//   capture ffmpeg (gfxcapture of a window)  --raw frames-->  FrameRelay  --raw frames, exactly fps per second-->  stream ffmpeg
//
// Windows Graphics Capture delivers nothing while a window is minimized, which used to stall the whole
// stream (video players then drop it). The relay sends the newest picture on every tick and repeats
// the last one when nothing new has arrived, so viewers see a frozen picture instead of a dead stream.
using System;
using System.Diagnostics;
using System.IO.Pipes;
using System.Threading;

public class FrameRelay
{
    readonly string ffmpeg, captureInput, name;
    readonly int w, h, fps, frameBytes;
    readonly object frameLock = new object();
    byte[] latest;                    // newest complete frame from the capture
    long framesCaptured;
    volatile bool stopping;
    Process capture;
    NamedPipeServerStream capPipe, pubPipe;
    public volatile string LastError = "";

    // Frames received from the window so far (stays put while it's minimized)
    public long FramesCaptured { get { return Interlocked.Read(ref framesCaptured); } }

    public FrameRelay(string ffmpeg, string captureInput, string name, int w, int h, int fps)
    {
        this.ffmpeg = ffmpeg; this.captureInput = captureInput; this.name = name;
        this.w = w; this.h = h; this.fps = fps;
        frameBytes = w * h * 3 / 2;   // yuv420p
    }

    public void Start()
    {
        pubPipe = new NamedPipeServerStream(name + "-v", PipeDirection.Out, 1, PipeTransmissionMode.Byte, PipeOptions.None, 0, frameBytes * 2);

        // Black until the first picture arrives (e.g. the window starts out minimized)
        latest = new byte[frameBytes];
        for (int i = 0; i < w * h; i++) latest[i] = 16;
        for (int i = w * h; i < frameBytes; i++) latest[i] = 128;

        new Thread(CaptureLoop) { IsBackground = true, Name = "FrameRelay capture" }.Start();
        new Thread(Pump) { IsBackground = true, Name = "FrameRelay pump" }.Start();
    }

    public void Stop()
    {
        stopping = true;
        try { if (capture != null && !capture.HasExited) capture.Kill(); } catch { }
        try { if (capPipe != null) capPipe.Dispose(); } catch { }
        try { pubPipe.Dispose(); } catch { }
    }

    // Run the capture; if it ends (window closed, or capture refused to start), try again every 2 s.
    // Viewers keep seeing the last picture meanwhile.
    void CaptureLoop()
    {
        for (int run = 1; !stopping; run++)
        {
            try
            {
                string pipeName = name + "-cap" + run;
                capPipe = new NamedPipeServerStream(pipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous, frameBytes * 2, 0);
                // Fit the window into a fixed w x h picture (black bars if its shape changes), so resizing
                // it mid-stream can't break the stream
                string args = "-nostdin -hide_banner -loglevel error " + captureInput +
                    " -vf \"scale=" + w + ":" + h + ":force_original_aspect_ratio=decrease,pad=" + w + ":" + h +
                    ":(ow-iw)/2:(oh-ih)/2,format=yuv420p\" -f rawvideo -y \\\\.\\pipe\\" + pipeName;
                var psi = new ProcessStartInfo(ffmpeg, args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true };
                capture = new Process { StartInfo = psi };
                capture.ErrorDataReceived += (s, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) LastError = e.Data; };
                capture.Start();
                capture.BeginErrorReadLine();

                var connect = capPipe.BeginWaitForConnection(null, null);
                while (!connect.IsCompleted && !capture.HasExited && !stopping) Thread.Sleep(100);
                if (connect.IsCompleted)
                {
                    capPipe.EndWaitForConnection(connect);
                    while (!stopping)
                    {
                        byte[] buf = new byte[frameBytes];
                        int got = 0;
                        while (got < frameBytes) { int n = capPipe.Read(buf, got, frameBytes - got); if (n <= 0) break; got += n; }
                        if (got < frameBytes) break;
                        lock (frameLock) latest = buf;
                        Interlocked.Increment(ref framesCaptured);
                        LastError = "";
                    }
                }
            }
            catch (Exception e) { if (!stopping) LastError = e.Message; }
            finally
            {
                try { if (capture != null && !capture.HasExited) capture.Kill(); } catch { }
                try { capPipe.Dispose(); } catch { }
            }
            if (!stopping) Thread.Sleep(2000);
        }
    }

    void Pump()
    {
        try
        {
            pubPipe.WaitForConnection();   // stream ffmpeg opened the pipe: time 0 starts now
            var clock = Stopwatch.StartNew();
            long tick = 0;
            while (!stopping)
            {
                byte[] frame;
                lock (frameLock) frame = latest;   // frames are never modified after being published
                pubPipe.Write(frame, 0, frameBytes);
                tick++;
                long due = tick * 1000 / fps, now = clock.ElapsedMilliseconds;
                // Behind (the stream stopped reading for a moment): send without sleeping until caught up. The
                // stream counts frames to time the picture while the sound keeps real time, so skipping ahead
                // instead would leave the picture behind the sound for the rest of the stream.
                if (due > now) Thread.Sleep((int)(due - now));
            }
        }
        catch (Exception e) { if (!stopping) LastError = "Stream stopped reading: " + e.Message; }
    }
}
