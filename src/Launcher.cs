using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

[assembly: AssemblyTitle("bumsstool")]
[assembly: AssemblyProduct("bumsstool")]
[assembly: AssemblyDescription("Purple R34 screenshare toolkit by SGTGozer")]
[assembly: AssemblyVersion("1.4.2.0")]
[assembly: AssemblyFileVersion("1.4.2.0")]

internal static class Launcher
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBox(IntPtr owner, string message, string caption, uint type);

    [STAThread]
    private static int Main(string[] arguments)
    {
        try
        {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT)
                throw new PlatformNotSupportedException("bumsstool requires Windows 10 or Windows 11 (x64).");
            string root = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(root, "bumsstool.ps1");
            foreach (string relative in new[] { "bumsstool.ps1", "tools.json", @"src\Core.ps1", @"src\Launch.ps1", @"src\Prerequisites.ps1", @"src\Run-Tool.ps1", @"src\ViewModel.ps1", @"src\Main.xaml", @"assets\car.png", @"assets\car.txt" })
            {
                if (!File.Exists(Path.Combine(root, relative)))
                    throw new FileNotFoundException("A required file is missing: " + relative + ". Extract the complete ZIP before starting bumsstool.");
            }
            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string system = (!Environment.Is64BitProcess && Environment.Is64BitOperatingSystem) ? "Sysnative" : "System32";
            string powershell = Path.Combine(windows, system, @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(powershell))
                throw new FileNotFoundException("Windows PowerShell could not be found. Use the included Start-bumsstool.cmd launcher.");
            var start = new ProcessStartInfo(powershell);
            start.Arguments = "-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"";
            start.WorkingDirectory = root;
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            using (Process process = Process.Start(start))
            {
                if (process == null) throw new InvalidOperationException("Windows PowerShell did not start.");
                process.WaitForExit();
                if (process.ExitCode != 0)
                {
                    string log = Path.Combine(Path.GetTempPath(), "bumsstool-startup.log");
                    MessageBox(IntPtr.Zero, "bumsstool closed with an error.\n\nUse Start-bumsstool.cmd to see the console, or check:\n" + log, "bumsstool", 0x10);
                }
                return process.ExitCode;
            }
        }
        catch (Exception error)
        {
            MessageBox(IntPtr.Zero, error.Message, "bumsstool startup error", 0x10);
            return 1;
        }
    }
}
