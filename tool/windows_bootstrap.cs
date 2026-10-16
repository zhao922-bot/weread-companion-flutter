using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Windows.Forms;

// A per-user self-extracting bundle built with the Windows .NET Framework
// compiler. --extract <directory> validates deployment without launching the
// app or changing the user's shortcuts.
internal static class WindowsBootstrap
{
    [STAThread]
    private static int Main(string[] args)
    {
        bool extractOnly = args.Length == 2 && args[0] == "--extract";
        try
        {
            string target = Path.GetFullPath(extractOnly ? args[1] : Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Programs", "WeReadCompanion"));
            string app = Path.Combine(target, "weread_companion.exe");
            foreach (Process running in Process.GetProcessesByName("weread_companion"))
            {
                using (running)
                {
                    if (String.Equals(running.MainModule.FileName, app,
                            StringComparison.OrdinalIgnoreCase))
                        throw new IOException("Please close ReadAmber before updating.");
                }
            }
            string prefix = target.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            Directory.CreateDirectory(target);
            using (Stream input = Assembly.GetExecutingAssembly().GetManifestResourceStream("application.zip"))
            using (ZipArchive archive = new ZipArchive(input, ZipArchiveMode.Read))
            {
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    string destination = Path.GetFullPath(Path.Combine(target, entry.FullName));
                    if (!destination.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException("Invalid path in application bundle.");
                    if (String.IsNullOrEmpty(entry.Name))
                    {
                        Directory.CreateDirectory(destination);
                        continue;
                    }
                    Directory.CreateDirectory(Path.GetDirectoryName(destination));
                    entry.ExtractToFile(destination, true);
                }
            }
            if (extractOnly) return 0;
            dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
            string shortcuts = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
            dynamic shortcut = shell.CreateShortcut(Path.Combine(shortcuts, "\u9605\u73c0 ReadAmber.lnk"));
            shortcut.TargetPath = app;
            shortcut.WorkingDirectory = target;
            shortcut.IconLocation = app;
            shortcut.Save();
            // Remove only our legacy shortcut, after its replacement is saved.
            string legacyLink = Path.Combine(shortcuts, "WeRead Companion.lnk");
            if (File.Exists(legacyLink))
            {
                dynamic legacyShortcut = shell.CreateShortcut(legacyLink);
                if (String.Equals((string)legacyShortcut.TargetPath, app,
                        StringComparison.OrdinalIgnoreCase)) File.Delete(legacyLink);
            }
            Process.Start(new ProcessStartInfo(app) { WorkingDirectory = target, UseShellExecute = true });
            return 0;
        }
        catch (Exception error)
        {
            if (extractOnly) Console.Error.WriteLine(error);
            else MessageBox.Show(error.Message, "\u9605\u73c0 ReadAmber", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
