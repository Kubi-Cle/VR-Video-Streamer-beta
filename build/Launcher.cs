// VR Video Streamer.exe: double-click to open the stream window (app\StreamUI.ps1) without a console window.
// Dropping a video/music file on the .exe opens the window with that file picked.
// Rebuild with Build-Launcher.ps1.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("VR Video Streamer")]
[assembly: AssemblyProduct("VR Video Streamer")]
[assembly: AssemblyDescription("Streams your screen or videos to VR video players")]
[assembly: AssemblyVersion("1.2.4.0")]        // the program's version: Make-Release.ps1 reads it from here
[assembly: AssemblyFileVersion("1.2.4.0")]

static class Launcher
{
    [STAThread]
    static void Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string ui = Path.Combine(dir, "app", "StreamUI.ps1");
        if (!File.Exists(ui))
        {
            MessageBox.Show("The app folder wasn't found next to this program:\n" + dir +
                "\n\nKeep VR Video Streamer.exe in the same folder as its app folder. " +
                "If you got this as a .zip, right-click it and choose Extract All first, then run it from the extracted folder.",
                "VR Video Streamer", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        string arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ui + "\"";
        if (args.Length > 0) arguments += " \"" + args[0] + "\"";
        var psi = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"), arguments)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = dir
        };
        try
        {
            using (var p = Process.Start(psi))
            {
                // A failure the window couldn't report itself (it reports its own and exits with 2).
                // Anything still running after a short while has opened, or is downloading FFmpeg.
                if (p.WaitForExit(15000) && p.ExitCode != 0 && p.ExitCode != 2)
                    MessageBox.Show("The program closed before its window opened (error " + p.ExitCode + ").\n\n" +
                        "Your antivirus may have blocked it, or Windows may not allow PowerShell scripts on this PC.",
                        "VR Video Streamer", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
        catch (Exception e)
        {
            MessageBox.Show("Couldn't start PowerShell:\n" + e.Message, "VR Video Streamer", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
