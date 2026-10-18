using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
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
            using (Stream input = Assembly.GetExecutingAssembly().GetManifestResourceStream("application.zip"))
                Deploy(input, target);
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

    // Stage the complete archive first. A locked file or failed replacement
    // must not leave an installation containing files from two releases.
    internal static void Deploy(Stream input, string target)
    {
        target = Path.GetFullPath(target);
        string identity;
        using (var hash = SHA256.Create())
            identity = BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(
                target.TrimEnd(Path.DirectorySeparatorChar).ToUpperInvariant()))).Replace("-", "");
        using (var mutex = new Mutex(false, "Local\\ReadAmber.Install." + identity))
        {
            bool acquired = false;
            try
            {
                try { acquired = mutex.WaitOne(0); }
                catch (AbandonedMutexException) { acquired = true; }
                if (!acquired) throw new IOException("Another ReadAmber update is in progress.");
                DeployLocked(input, target);
            }
            finally { if (acquired) mutex.ReleaseMutex(); }
        }
    }

    private static void DeployLocked(Stream input, string target)
    {
        string prefix = target.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        string parent = Path.GetDirectoryName(target.TrimEnd(Path.DirectorySeparatorChar));
        if (String.IsNullOrEmpty(parent)) throw new IOException("Choose an application directory.");
        string staging = Path.Combine(parent, ".readamber-update-" + Guid.NewGuid().ToString("N"));
        var paths = new List<string>();
        var completed = new List<Tuple<string, string>>();
        bool preserveBackup = false;
        try
        {
            Directory.CreateDirectory(staging);
            using (ZipArchive archive = new ZipArchive(input, ZipArchiveMode.Read, true))
            {
                var unique = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    if (Path.IsPathRooted(entry.FullName) || entry.FullName.Contains(":"))
                        throw new InvalidDataException("Invalid path in application bundle.");
                    string destination = Path.GetFullPath(Path.Combine(target, entry.FullName));
                    if (!destination.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException("Invalid path in application bundle.");
                    if (String.IsNullOrEmpty(entry.Name)) continue;
                    if (!unique.Add(destination)) throw new InvalidDataException("Duplicate bundle path.");
                    string staged = Path.Combine(staging, paths.Count.ToString() + ".new");
                    entry.ExtractToFile(staged);
                    paths.Add(destination);
                }
            }
            for (int i = 0; i < paths.Count; i++)
            {
                string destination = paths[i];
                string staged = Path.Combine(staging, i.ToString() + ".new");
                Directory.CreateDirectory(Path.GetDirectoryName(destination));
                string backup = null;
                if (File.Exists(destination))
                {
                    backup = Path.Combine(staging, i.ToString() + ".old");
                    File.Replace(staged, destination, backup);
                }
                else File.Move(staged, destination);
                completed.Add(Tuple.Create(destination, backup));
            }
        }
        catch (Exception original)
        {
            var errors = new List<Exception> { original };
            for (int i = completed.Count - 1; i >= 0; i--)
            {
                try
                {
                    var item = completed[i];
                    if (item.Item2 == null) File.Delete(item.Item1);
                    else if (File.Exists(item.Item1)) File.Replace(item.Item2, item.Item1, null);
                    else File.Move(item.Item2, item.Item1);
                }
                catch (Exception rollback) { errors.Add(rollback); }
            }
            if (errors.Count > 1)
            {
                preserveBackup = true;
                throw new AggregateException("Update and rollback failed. Recovery files: " + staging, errors);
            }
            throw;
        }
        finally
        {
            if (!preserveBackup && Directory.Exists(staging))
            {
                try { Directory.Delete(staging, true); }
                catch (IOException) { Console.Error.WriteLine("Temporary update files remain: " + staging); }
                catch (UnauthorizedAccessException) { Console.Error.WriteLine("Temporary update files remain: " + staging); }
            }
        }
    }
}
