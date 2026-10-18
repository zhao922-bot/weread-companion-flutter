using System;
using System.IO;
using System.IO.Compression;
using System.Threading;

internal static class WindowsBootstrapTest
{
    private sealed class PausedBundle : MemoryStream
    {
        internal readonly ManualResetEvent Entered = new ManualResetEvent(false);
        internal readonly ManualResetEvent Release = new ManualResetEvent(false);
        internal PausedBundle(byte[] data) : base(data) {}
        public override int Read(byte[] buffer, int offset, int count)
        {
            Entered.Set();
            if (!Release.WaitOne(10000)) throw new IOException("Test gate timed out");
            return base.Read(buffer, offset, count);
        }
        protected override void Dispose(bool disposing)
        {
            if (disposing) { Entered.Dispose(); Release.Dispose(); }
            base.Dispose(disposing);
        }
    }
    private static MemoryStream Bundle(params string[] paths)
    {
        var stream = new MemoryStream();
        using (var zip = new ZipArchive(stream, ZipArchiveMode.Create, true))
            foreach (string path in paths)
                using (var writer = new StreamWriter(zip.CreateEntry(path).Open()))
                    writer.Write("new:" + path);
        stream.Position = 0;
        return stream;
    }

    private static void Check(bool value, string message)
    {
        if (!value) throw new Exception(message);
    }

    private static void Fails(Action action)
    {
        try { action(); }
        catch (IOException) { return; }
        catch (InvalidDataException) { return; }
        catch (UnauthorizedAccessException) { return; }
        throw new Exception("Expected deployment failure");
    }

    private static int Main(string[] args)
    {
        try { return Run(args); }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.GetType().FullName + ": " + error.Message);
            return 1;
        }
    }

    private static int Run(string[] args)
    {
        // The launcher passes an isolated directory inside its build folder.
        string root = Path.GetFullPath(args[0]);
        string target = Path.Combine(root, "application");
        Directory.CreateDirectory(Path.Combine(target, "data"));
        string app = Path.Combine(target, "weread_companion.exe");
        string data = Path.Combine(target, "data", "app.so");
        string personal = Path.Combine(target, "personal.txt");
        File.WriteAllText(app, "old-exe");
        File.WriteAllText(data, "old-data");
        File.WriteAllText(personal, "keep");

        // Real Windows sharing violation after two replacements, including a
        // newly created file. Both changes must roll back before retry.
        using (var locked = File.Open(data, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        using (var bundle = Bundle("weread_companion.exe", "fresh.txt", "data/app.so"))
            Fails(() => WindowsBootstrap.Deploy(bundle, target));
        Check(File.ReadAllText(app) == "old-exe", "Failed upgrade changed the executable");
        Check(File.ReadAllText(data) == "old-data", "Failed upgrade changed runtime data");
        Check(!File.Exists(Path.Combine(target, "fresh.txt")), "Failed upgrade left a new file");
        Check(Directory.GetDirectories(root, ".readamber-update-*").Length == 0, "Rollback leaked staging");

        using (var bundle = Bundle("weread_companion.exe", "fresh.txt", "data/app.so"))
            WindowsBootstrap.Deploy(bundle, target);
        Check(File.ReadAllText(app) == "new:weread_companion.exe", "Retry did not update executable");
        Check(File.ReadAllText(data) == "new:data/app.so", "Retry did not update runtime");
        Check(File.ReadAllText(personal) == "keep", "Update removed unrelated files");

        foreach (string invalid in new[] { "../escape.txt", "data/../../escape.txt", "file:stream" })
        {
            File.WriteAllText(app, "unchanged");
            using (var bundle = Bundle("weread_companion.exe", invalid))
                Fails(() => WindowsBootstrap.Deploy(bundle, target));
            Check(File.ReadAllText(app) == "unchanged", "Invalid bundle was partly installed");
            Check(!File.Exists(Path.Combine(root, "escape.txt")), "Bundle escaped target");
        }
        using (var bundle = Bundle("weread_companion.exe", "WEREAD_COMPANION.EXE"))
            Fails(() => WindowsBootstrap.Deploy(bundle, target));
        Check(File.ReadAllText(app) == "unchanged", "Duplicate path was partly installed");

        // A file/directory collision during publishing also rolls back.
        using (var bundle = Bundle("weread_companion.exe", "personal.txt/child"))
            Fails(() => WindowsBootstrap.Deploy(bundle, target));
        Check(File.ReadAllText(app) == "unchanged", "Path collision was not rolled back");
        Check(File.ReadAllText(personal) == "keep", "Path collision damaged existing file");
        Check(Directory.GetDirectories(root, ".readamber-update-*").Length == 0, "Deployment leaked staging");

        using (var bundle = Bundle("weread_companion.exe"))
        using (var paused = new PausedBundle(bundle.ToArray()))
        {
            Exception backgroundError = null;
            var worker = new Thread(() => {
                try { WindowsBootstrap.Deploy(paused, target); }
                catch (Exception error) { backgroundError = error; }
            });
            worker.IsBackground = true;
            worker.Start();
            try
            {
                Check(paused.Entered.WaitOne(5000), "First update never entered staging");
                using (var competing = Bundle("weread_companion.exe"))
                    Fails(() => WindowsBootstrap.Deploy(competing, target + Path.DirectorySeparatorChar));
                Check(File.ReadAllText(app) == "unchanged", "Competing update modified target");
            }
            finally { paused.Release.Set(); Check(worker.Join(10000), "Update worker did not stop"); }
            Check(backgroundError == null, "First update failed after competing update was rejected");
        }
        Check(File.ReadAllText(app) == "new:weread_companion.exe", "First update did not finish");
        Console.WriteLine("Windows deployment: rollback, retry, preservation and archive validation passed.");
        return 0;
    }
}
