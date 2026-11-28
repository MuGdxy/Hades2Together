using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace Hades2Together.Setup;

internal static class Lifecycle
{
    private const string GameFile = "Content/Scripts/Main.lua";
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    private static string Steam, Preview, Outside;

    [STAThread]
    internal static int Main(string[] args)
    {
        Steam = Path.Combine(args[0], "Steam Game");
        Preview = Path.Combine(args[0], "Preview");
        Outside = Path.Combine(args[0], "Outside");
        if (args.Length == 4 && args[1] == "--stage")
            return TestActualPackage(args[0], args[2], args[3]);
        if (args.Length > 1)
            return InterruptedChild(args[0]);
        Directory.CreateDirectory(Outside);
        var source = Paths.Child(Steam, GameFile);
        Directory.CreateDirectory(Path.GetDirectoryName(source));
        File.WriteAllText(source, "owned Steam fixture");
        var unrelated = Path.Combine(Steam, "Ship", "d3d12.dll");
        Directory.CreateDirectory(Path.GetDirectoryName(unrelated));
        File.WriteAllText(unrelated, "a player's existing mod");
        var sentinel = Path.Combine(Outside, "Main.lua");
        File.Copy(source, sentinel);

        var os = new FixtureIntegration();
        var app = new Install(Preview, os);
        using var first = Fixture("first");
        using var second = Fixture("second");

        File.AppendAllText(source, "corruption");
        ExpectError(() => app.Apply(first, Steam, null));
        Assert(!Directory.Exists(Preview), "validation happens before installation writes");
        File.WriteAllText(source, "owned Steam fixture");

        app.Apply(first, Steam, null);
        var original = State().Active;
        Assert(os.Registered && File.Exists(Path.Combine(Preview, "Preview.exe")), "setup integration");
        Assert(!File.Exists(Path.Combine(Stage(original), "Ship", "unowned.dll")), "payload paths");
        Assert(File.ReadAllText(Path.Combine(Stage(original), "Ship", "d3d12.dll")) == "fixture loader first", "chosen loader");
        Assert(Encoding.UTF8.GetString(app.ReadActiveLauncher()) == "fixture launcher first", "first launcher active");
        Assert(File.ReadAllText(unrelated) == "a player's existing mod", "source mod preserved");
        app.Apply(first, Steam, null);
        Assert(State().Active == original && State().Manifests.Count == 1, "same build is repeat-safe");

        var passes = 0;
        ExpectError(() => app.Apply(second, Steam, _ =>
        {
            if (++passes == 2)
                File.AppendAllText(source, "changed after validation");
        }));
        File.WriteAllText(source, "owned Steam fixture");
        Assert(State().Active == original && State().Manifests.Count == 1, "failed staging rolled back");
        Assert(File.ReadAllText(Path.Combine(Stage(original), "Ship", "d3d12.dll")) == "fixture loader first", "previous preview still usable");
        Assert(Encoding.UTF8.GetString(app.ReadActiveLauncher()) == "fixture launcher first", "failed update did not select a new launcher");

        // Recreate the durable state if a process is lost just after recording
        // the stage, before writing the generation directory or its manifest.
        var preparing = State();
        preparing.Pending = Guid.NewGuid().ToString("N");
        preparing.Manifests.Add(preparing.Pending, new string('0', 64));
        File.WriteAllText(Path.Combine(Preview, "state.json"), Json.Serialize(preparing));
        app.Apply(first, Steam, null);
        Assert(State().Pending == null && State().Active == original, "recovered interruption before writing ownership");

        TerminateStaging(args[0]);
        var interrupted = State().Pending;
        Assert(interrupted != null && State().Active == original, "terminated setup left previous launcher active");
        Assert(File.Exists(Path.Combine(Stage(interrupted), ".incoming")), "partial staging file was journaled");
        app.Apply(first, Steam, null);
        Assert(!Directory.Exists(Stage(interrupted)) && State().Pending == null, "retry reclaimed interrupted generation");

        app.Apply(second, Steam, null);
        var updated = State().Active;
        Assert(updated != original && !Directory.Exists(Stage(original)), "upgrade switched generation and retired old files");
        Assert(Encoding.UTF8.GetString(app.ReadActiveLauncher()) == "fixture launcher second", "upgraded launcher active");
        var owned = Path.Combine(Stage(updated), "ownership.json");
        var savedManifest = File.ReadAllText(owned);
        File.AppendAllText(owned, " ");
        ExpectError(app.Uninstall);
        Assert(File.Exists(Paths.Child(Stage(updated), GameFile)) && os.Registered, "altered manifest blocked removal");
        Assert(State().Active == updated && !State().Removing, "uninstall preflight preserved the active installation");
        File.WriteAllText(owned, savedManifest);

        var scripts = Path.GetDirectoryName(Paths.Child(Stage(updated), GameFile));
        File.Delete(Path.Combine(scripts, "Main.lua"));
        Directory.Delete(scripts);
        Junction(scripts, Outside);
        var extra = Path.Combine(Stage(updated), "user-notes.txt");
        File.WriteAllText(extra, "keep my file");
        app.Uninstall();
        Assert(File.ReadAllText(sentinel) == "owned Steam fixture", "external junction target preserved");
        Assert(Directory.Exists(scripts) && File.Exists(extra), "junction and unowned file preserved");
        Assert(!os.Registered && !File.Exists(Path.Combine(Preview, "Preview.exe")), "uninstall cleaned owned integration");
        app.Uninstall();
        Assert(File.Exists(unrelated) && File.Exists(source), "original Steam files preserved after repeated uninstall");
        TestWindowsIntegration(args[0], first);
        Console.WriteLine("PASS: preflight, install, repeat, failed and terminated staging, atomic launcher upgrade, edited manifest, junction, uninstall, and disposable Windows registration");
        return 0;
    }

    private static string Stage(string id) => Path.Combine(Preview, "version-" + id);
    private static InstallState State() => Json.Deserialize<InstallState>(File.ReadAllText(Path.Combine(Preview, "state.json")));

    private static Package Fixture(string version)
    {
        var size = "owned Steam fixture".Length;
        using var known = new MemoryStream(Encoding.UTF8.GetBytes("owned Steam fixture"));
        var catalog = new MemoryStream(Encoding.UTF8.GetBytes(GameFile + "\t" + size + "\t" + Paths.Hash(known) + "\n"));
        var payload = new MemoryStream();
        using (var zip = new ZipArchive(payload, ZipArchiveMode.Create, leaveOpen: true))
        {
            using (var launcher = new StreamWriter(zip.CreateEntry("Preview.exe").Open()))
                launcher.Write("fixture bootstrap");
            using (var launcher = new StreamWriter(zip.CreateEntry(Install.LauncherName).Open()))
                launcher.Write("fixture launcher " + version);
            using (var loader = new StreamWriter(zip.CreateEntry("Ship/d3d12.dll").Open()))
                loader.Write("fixture loader " + version);
        }
        payload.Position = 0;
        return new Package(catalog, payload, version);
    }

    private static void TerminateStaging(string scratch)
    {
        using var child = Process.Start(new ProcessStartInfo(typeof(Lifecycle).Assembly.Location,
            "\"" + scratch + "\" child") { UseShellExecute = false });
        try
        {
            var signal = Path.Combine(scratch, "terminate-ready");
            var expires = DateTime.UtcNow.AddSeconds(10);
            while (!File.Exists(signal) && !child.HasExited && DateTime.UtcNow < expires)
                Thread.Sleep(25);
            Assert(File.Exists(signal) && !child.HasExited, "child reached interrupted staging fixture");
        }
        finally
        {
            if (!child.HasExited)
                child.Kill();
            child.WaitForExit();
        }
    }

    private static void TestWindowsIntegration(string scratch, Package package)
    {
        var programs = Path.Combine(scratch, "Fixture Start Menu");
        Directory.CreateDirectory(programs);
        var root = Path.Combine(scratch, "Player's Preview");
        var launcher = Path.Combine(root, "Preview.exe");
        var keyPath = @"Software\Hades2Together.PreviewFixture-" + Guid.NewGuid().ToString("N");
        using (Registry.CurrentUser.CreateSubKey(keyPath)) { }
        // The production integration refuses an existing registry entry with
        // no owner. Use a child below the disposable parent as the test slot.
        var app = new Install(root, new WindowsIntegration(programs, keyPath + "\\Preview"));
        try
        {
            app.Apply(package, Steam, null);
            var shortcut = Directory.GetFiles(programs, "*.lnk").Single();
            dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell", throwOnError: true));
            dynamic link = shell.CreateShortcut(shortcut);
            try
            {
                Assert(link.Arguments == "--launch" && string.Equals(link.TargetPath, launcher, StringComparison.OrdinalIgnoreCase),
                    "real Start menu shortcut points to bootstrap");
            }
            finally
            {
                Marshal.FinalReleaseComObject(link);
                Marshal.FinalReleaseComObject(shell);
            }
            using (var key = Registry.CurrentUser.OpenSubKey(keyPath + "\\Preview"))
            {
                var command = (string)key.GetValue("UninstallString");
                var encoded = command.Split(' ').Last();
                var script = Encoding.Unicode.GetString(Convert.FromBase64String(encoded));
                Assert(script.Contains("Player''s Preview") && script.Contains("Hades2Together.Setup.InstalledApps"),
                    "real Installed apps command quotes the path and calls the bootstrap");
                File.WriteAllText(Path.Combine(scratch, "uninstall-command.ps1"), script);
            }
            app.Uninstall();
            Assert(!File.Exists(shortcut) && !Directory.Exists(root), "real Windows integration removed");
            using var removed = Registry.CurrentUser.OpenSubKey(keyPath + "\\Preview");
            Assert(removed == null, "disposable key removed");
        }
        finally { Registry.CurrentUser.DeleteSubKeyTree(keyPath, throwOnMissingSubKey: false); }
    }

    private static int TestActualPackage(string scratch, string setup, string source)
    {
        var assembly = Assembly.Load(File.ReadAllBytes(setup));
        using var package = new Package(assembly.GetManifestResourceStream("steam.tsv"),
            assembly.GetManifestResourceStream("payload.zip"), "package staging fixture");
        Assert(package.SteamFiles.Count == 5834, "catalog contains full Steam inventory");
        Assert(SteamLibraries.Find().Contains(source, StringComparer.OrdinalIgnoreCase), "registered Steam library detected");
        var root = Path.Combine(scratch, "Full package staging");
        var app = new Install(root, new FixtureIntegration());
        app.Apply(package, source, null);
        var active = Directory.GetDirectories(root).Single();
        var native = package.Additions.Single(file => file.Name == "Ship/d3d12.dll");
        Assert(SteamGame.Matches(active, native, strict: true), "staged candidate loader hash");
        var launcher = Assembly.Load(app.ReadActiveLauncher()).GetType(typeof(InstalledApps).FullName, throwOnError: true);
        Assert(launcher.GetMethod("LaunchCore") != null && launcher.GetMethod("UninstallCore") != null, "versioned launcher dispatch targets");
        app.Uninstall();
        Assert(!Directory.Exists(root), "full retail-sized staging was cleanly removed");
        Console.WriteLine("PASS: stock Steam detected; embedded package fully staged and uninstalled in scratch without a game launch");
        return 0;
    }

    private static int InterruptedChild(string scratch)
    {
        using var update = Fixture("interrupted");
        var installer = new Install(Preview, new FixtureIntegration());
        var passes = 0;
        installer.Apply(update, Steam, _ =>
        {
            if (++passes != 2)
                return;
            File.WriteAllText(Path.Combine(Stage(State().Pending), ".incoming"), "partial staging data");
            File.WriteAllText(Path.Combine(scratch, "terminate-ready"), "");
            Thread.Sleep(Timeout.Infinite);
        });
        return 1;
    }

    private static void Junction(string name, string target)
    {
        using var process = Process.Start(new ProcessStartInfo(Environment.GetEnvironmentVariable("ComSpec"),
            "/d /c mklink /J \"" + name + "\" \"" + target + "\"") { UseShellExecute = false });
        process.WaitForExit();
        Assert(process.ExitCode == 0, "fixture junction created");
    }

    private static void ExpectError(Action operation)
    {
        try { operation(); }
        catch (IOException) { return; }
        throw new Exception("Expected IO error.");
    }

    private static void Assert(bool condition, string detail)
    {
        if (!condition)
            throw new Exception("FAIL: " + detail);
    }

    private sealed class FixtureIntegration : Integration
    {
        internal bool Registered { get; private set; }
        internal override void Prepare(string launcher, InstallState state) { }
        internal override void Register(string launcher, InstallState state, Action save) => Registered = true;
        internal override void Remove(string launcher, InstallState state) => Registered = false;
    }
}
