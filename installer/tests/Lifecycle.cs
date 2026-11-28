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
    private const string PluginFile = "ReturnOfModding/plugins/Fixture/main.lua";
    private const string TestLoader = "fixture loader";
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    private static string Steam, Preview, Outside;

    [STAThread]
    internal static int Main(string[] args)
    {
        Steam = Path.Combine(args[0], "Steam Game");
        Preview = Path.Combine(args[0], "Preview");
        Outside = Path.Combine(args[0], "Outside");
        if (args.Length == 3 && args[1] == "--stage")
            return TestActualPackage(args[0], args[2]);
        if (args.Length > 1)
            return InterruptedChild(args[0]);
        Directory.CreateDirectory(Outside);
        var source = MakeGame(Steam);
        var unrelated = Path.Combine(Steam, "Ship", "unrelated-mod.dll");
        File.WriteAllText(unrelated, "a player's existing mod");
        var sentinel = Path.Combine(Outside, "Main.lua");
        File.WriteAllText(sentinel, "fixture mod data");

        var os = new FixtureIntegration();
        var app = ForFixture(Preview, os);
        using var first = Fixture("first");
        using var second = Fixture("second");

        File.AppendAllText(source, "corruption");
        ExpectError(() => app.Apply(first, Steam, null));
        Assert(!Directory.Exists(Preview), "validation happens before installation writes");
        File.WriteAllText(source, "owned Steam fixture");

        var noSpace = ForFixture(Preview, os, _ => 0);
        ExpectError(() => noSpace.Apply(first, Steam, null));
        Assert(!Directory.Exists(Preview) && !os.Registered, "fresh install with insufficient space makes no writes");

        var loaderPath = GamePath(Steam, GameSlot.LoaderName);
        var markerPath = GamePath(Steam, GameSlot.MarkerName);
        var failedRegistration = ForFixture(Preview, new FixtureIntegration { FailRegistration = true });
        ExpectError(() => failedRegistration.Apply(first, Steam, null));
        Assert(!File.Exists(loaderPath) && !File.Exists(markerPath), "failed registration left regular Steam startup untouched");

        app.Apply(first, Steam, null);
        var original = State().Active;
        Assert(os.Registered && File.Exists(Path.Combine(Preview, "Preview.exe")), "setup integration");
        Assert(!Directory.Exists(Path.Combine(Stage(original), "Ship")) && !Directory.Exists(Path.Combine(Stage(original), "Content")),
            "no base game directories copied or linked");
        Assert(File.ReadAllText(loaderPath) == TestLoader && File.ReadAllText(markerPath) == "2\r\n",
            "loader is installed into Ship with ordinary Steam disabled before first preview");
        Assert(State().GameFiles.Count == 2, "loader and explicit first reason tracked as owned");
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
        Assert(File.ReadAllText(loaderPath) == TestLoader, "previous preview loader unchanged");
        Assert(Encoding.UTF8.GetString(app.ReadActiveLauncher()) == "fixture launcher first", "failed update did not select a new launcher");

        // Recreate the durable state if a process is lost just after recording
        // the stage, before writing the generation directory or its manifest.
        var preparing = State();
        preparing.Pending = Guid.NewGuid().ToString("N");
        preparing.Manifests.Add(preparing.Pending, new string('0', 64));
        var pendingClaim = new GameFileClaim
        {
            Generation = preparing.Pending, Kind = "reason", Hash = GameSlot.MarkerHash,
            Ship = Path.Combine(Steam, "Ship"),
            ShipIdentity = Paths.Identity(Path.Combine(Steam, "Ship"), directory: true)
        };
        File.WriteAllText(pendingClaim.TempPath, "an incomplete transaction");
        pendingClaim.Identity = Paths.Identity(pendingClaim.TempPath, directory: false);
        preparing.GameFiles.Add(pendingClaim);
        File.WriteAllText(Path.Combine(Preview, "state.json"), Json.Serialize(preparing));
        app.Apply(first, Steam, null);
        Assert(State().Pending == null && State().Active == original && !File.Exists(pendingClaim.TempPath) &&
            File.ReadAllText(markerPath) == "2\r\n", "recovered interrupted Steam-side staging without removing the active marker");

        TerminateStaging(args[0]);
        var interrupted = State().Pending;
        Assert(interrupted != null && State().Active == original, "terminated setup left previous launcher active");
        Assert(File.Exists(Path.Combine(Stage(interrupted), ".incoming")), "partial staging file was journaled");
        var retained = Path.Combine(Stage(interrupted), "personal-note.txt");
        File.WriteAllText(retained, "keep this");
        var probed = false;
        var recovery = ForFixture(Preview, os, _ =>
        {
            probed = true;
            Assert(State().Active == original, "recovery preserves the active version while measuring space");
            Assert(File.Exists(retained), "recovery preserves unrelated files");
            return File.Exists(Path.Combine(Stage(interrupted), ".incoming")) ? 0 : 128L * 1024 * 1024;
        });
        recovery.Apply(second, Steam, null);
        Assert(probed && State().Pending == null && !File.Exists(Path.Combine(Stage(interrupted), ".incoming")),
            "retry reclaims the pending copy before measuring space");
        var updated = State().Active;
        Assert(updated != original && !Directory.Exists(Stage(original)), "upgrade switched generation and retired old files");
        Assert(Encoding.UTF8.GetString(app.ReadActiveLauncher()) == "fixture launcher second", "upgraded launcher active");
        var priorRomEnv = Environment.GetEnvironmentVariable("rom_enabled");
        var start = app.PrepareLaunch();
        var profile = Path.Combine(Stage(updated), "profile");
        Assert(start.FileName == GamePath(Steam, "Hades2.exe") && start.WorkingDirectory == Path.Combine(Steam, "Ship"),
            "preview launches the original Steam game directly");
        Assert(start.EnvironmentVariables["rom_enabled"] == "true" &&
            start.EnvironmentVariables["rom_modding_root_folder"] == Stage(updated) &&
            start.EnvironmentVariables["USERPROFILE"] == profile &&
            start.EnvironmentVariables["H2T_SAMPLER_SCRATCH_SHIP"] == start.WorkingDirectory &&
            start.Arguments.Contains("/AllowSaveLoad=false") &&
            start.Arguments.Contains("/DevSavePathStr=\"" + profile + "\"") &&
            Environment.GetEnvironmentVariable("rom_enabled") == priorRomEnv, "private no-save launch environment is child-only");
        var owned = Path.Combine(Stage(updated), "ownership.json");
        var savedManifest = File.ReadAllText(owned);
        File.AppendAllText(owned, " ");
        ExpectError(app.Uninstall);
        Assert(File.Exists(Paths.Child(Stage(updated), PluginFile)) && File.Exists(loaderPath) && os.Registered,
            "altered manifest blocked removal");
        Assert(State().Active == updated && !State().Removing, "uninstall preflight preserved the active installation");
        File.WriteAllText(owned, savedManifest);

        var scripts = Path.GetDirectoryName(Paths.Child(Stage(updated), PluginFile));
        File.Delete(Path.Combine(scripts, "main.lua"));
        Directory.Delete(scripts);
        Junction(scripts, Outside);
        var extra = Path.Combine(Stage(updated), "user-notes.txt");
        File.WriteAllText(extra, "keep my file");
        app.Uninstall();
        Assert(File.ReadAllText(sentinel) == "fixture mod data", "external junction target preserved");
        Assert(Directory.Exists(scripts) && File.Exists(extra), "junction and unowned file preserved");
        Assert(!os.Registered && !File.Exists(Path.Combine(Preview, "Preview.exe")), "uninstall cleaned owned integration");
        Assert(!File.Exists(loaderPath) && !File.Exists(markerPath), "uninstall removes only the Steam slot it owned");
        app.Uninstall();
        Assert(File.Exists(unrelated) && File.Exists(source), "original Steam files preserved after repeated uninstall");
        TestGameSlotOwnership(args[0], first);
        TestWindowsIntegration(args[0], first);
        Console.WriteLine("PASS: stock protection, owned and borrowed Steam slots, moves, child-only launch, rollback, recovery, junction and Windows registration");
        return 0;
    }

    private static string Stage(string id) => Path.Combine(Preview, "version-" + id);
    private static InstallState State() => Json.Deserialize<InstallState>(File.ReadAllText(Path.Combine(Preview, "state.json")));

    private static Install ForFixture(string root, Integration integration, Func<string, long> freeSpace = null)
    {
        var size = "owned Steam fixture".Length;
        using var known = new MemoryStream(Encoding.UTF8.GetBytes("owned Steam fixture"));
        return new Install(root, integration, freeSpace, new[] { new OwnedFile { Name = GameFile, Size = size, Hash = Paths.Hash(known) } });
    }

    private static string GamePath(string root, string file) => Path.Combine(root, "Ship", file);

    private static string MakeGame(string root)
    {
        Directory.CreateDirectory(Path.Combine(root, "Ship", "ReturnOfModding"));
        File.WriteAllText(GamePath(root, "Hades2.exe"), "synthetic game executable");
        File.WriteAllText(GamePath(root, "Hades2.pdb"), "synthetic game symbols");
        File.WriteAllText(GamePath(root, "SDL2.dll"), "synthetic game dependency");
        File.WriteAllText(GamePath(root, @"ReturnOfModding\user-config.txt"), "other mods");
        var script = Paths.Child(root, GameFile);
        Directory.CreateDirectory(Path.GetDirectoryName(script));
        File.WriteAllText(script, "owned Steam fixture");
        return script;
    }

    private static Package Fixture(string version)
    {
        var payload = new MemoryStream();
        using (var zip = new ZipArchive(payload, ZipArchiveMode.Create, leaveOpen: true))
        {
            using (var launcher = new StreamWriter(zip.CreateEntry("Preview.exe").Open()))
                launcher.Write("fixture bootstrap");
            using (var launcher = new StreamWriter(zip.CreateEntry(Install.LauncherName).Open()))
                launcher.Write("fixture launcher " + version);
            using (var loader = new StreamWriter(zip.CreateEntry("Ship/d3d12.dll").Open()))
                loader.Write(TestLoader);
            using (var mod = new StreamWriter(zip.CreateEntry(PluginFile).Open()))
                mod.Write("fixture mod data");
        }
        payload.Position = 0;
        return new Package(payload, version);
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
        var app = ForFixture(root, new WindowsIntegration(programs, keyPath + "\\Preview"));
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

    private static void TestGameSlotOwnership(string scratch, Package package)
    {
        var borrowed = Path.Combine(scratch, "Existing loader");
        MakeGame(borrowed);
        var loader = GamePath(borrowed, GameSlot.LoaderName);
        var marker = GamePath(borrowed, GameSlot.MarkerName);
        var root = Path.Combine(scratch, "Borrowed profile");
        var app = ForFixture(root, new FixtureIntegration());

        File.WriteAllText(loader, "different loader");
        ExpectError(() => app.Apply(package, borrowed, null));
        Assert(File.ReadAllText(loader) == "different loader" && !Directory.Exists(root), "foreign loader rejected without writes");
        File.WriteAllText(loader, TestLoader);
        ExpectError(() => app.Apply(package, borrowed, null));
        Assert(!File.Exists(marker) && !Directory.Exists(root), "existing uninitialized loader left alone");
        File.WriteAllText(marker, "6\r\n");
        var defaultMod = GamePath(borrowed, @"ReturnOfModding\user-config.txt");
        app.Apply(package, borrowed, null);
        app.Uninstall();
        Assert(File.ReadAllText(loader) == TestLoader && File.ReadAllText(marker) == "6\r\n" &&
            File.ReadAllText(defaultMod) == "other mods", "borrowed loader, first reason and default profile preserved");
        File.Delete(loader);
        ExpectError(() => app.Apply(package, borrowed, null));
        Assert(!File.Exists(loader) && File.ReadAllText(marker) == "6\r\n", "stale incompatible marker refused");
        File.WriteAllText(marker, "4\r\n");
        app.Apply(package, borrowed, null);
        app.Uninstall();
        Assert(!File.Exists(loader) && File.ReadAllText(marker) == "4\r\n", "compatible preexisting marker remains borrowed");

        var origin = Path.Combine(scratch, "Steam library A");
        var moved = Path.Combine(scratch, "Steam library B");
        MakeGame(origin);
        app.Apply(package, origin, null);
        Directory.Move(origin, moved);
        ExpectError(() => app.PrepareLaunch());
        app.Apply(package, moved, null);
        Assert(app.PrepareLaunch().FileName == GamePath(moved, "Hades2.exe"), "moved Steam launch was rebound");
        app.Uninstall();
        Assert(!File.Exists(GamePath(moved, GameSlot.LoaderName)) && !File.Exists(GamePath(moved, GameSlot.MarkerName)),
            "uninstall finds the same owned slot after a same-volume move");

        app.Apply(package, moved, null);
        var external = Path.Combine(scratch, "Borrowed external Ship");
        Directory.CreateDirectory(external);
        var redirected = Path.Combine(moved, "Ship");
        var originalShip = Path.Combine(moved, "Unlinked original Ship");
        Directory.Move(redirected, originalShip);
        File.WriteAllText(Path.Combine(external, GameSlot.LoaderName), TestLoader);
        File.WriteAllText(Path.Combine(external, GameSlot.MarkerName), "2\r\n");
        Junction(redirected, external);
        app.Uninstall();
        Assert(File.ReadAllText(Path.Combine(external, GameSlot.LoaderName)) == TestLoader &&
            File.ReadAllText(Path.Combine(external, GameSlot.MarkerName)) == "2\r\n", "redirected Steam destination left untouched");
    }

    private static int TestActualPackage(string scratch, string setup)
    {
        var assembly = Assembly.Load(File.ReadAllBytes(setup));
        using var package = new Package(assembly.GetManifestResourceStream("payload.zip"), "mod-only package staging fixture");
        var source = Path.Combine(scratch, "Disposable synthetic Steam");
        MakeGame(source);
        var stock = Snapshot(source);
        var root = Path.Combine(scratch, "Actual mod profile");
        var app = ForFixture(root, new FixtureIntegration());
        app.Apply(package, source, null);
        var after = Snapshot(source);
        Assert(stock.All(file => after.TryGetValue(file.Key, out var value) && value == file.Value),
            "all original files in the representative game fixture stayed byte-for-byte unchanged");
        var newSteamFiles = after.Keys.Except(stock.Keys).OrderBy(path => path).ToArray();
        Assert(newSteamFiles.SequenceEqual(new[] { GamePath(source, GameSlot.LoaderName), GamePath(source, GameSlot.MarkerName) }
            .OrderBy(path => path)), "the game-facing slot adds only loader and first-reason marker");
        Assert(SteamGame.Matches(source, package.Loader, strict: true), "game-facing loader hash");
        foreach (var file in Directory.EnumerateFileSystemEntries(root, "*", SearchOption.AllDirectories))
        {
            Assert((File.GetAttributes(file) & FileAttributes.ReparsePoint) == 0, "no mirrored content or filesystem links");
            Assert(Path.GetFileName(file) != "Hades2.exe" && Path.GetFileName(file) != "Hades2.pdb" &&
                Path.GetFileName(file) != "SDL2.dll" && Path.GetFileName(file) != "Content", "no retail copies");
        }
        Console.WriteLine("download_bytes=" + new FileInfo(setup).Length);
        Console.WriteLine("steam_installed_bytes=" + newSteamFiles.Sum(file => new FileInfo(file).Length));
        Console.WriteLine("profile_installed_bytes_including_metadata=" +
            Directory.GetFiles(root, "*", SearchOption.AllDirectories).Sum(file => new FileInfo(file).Length));
        Console.WriteLine("profile_payload_bytes=" + package.ProfileBytes);
        var launcher = Assembly.Load(app.ReadActiveLauncher()).GetType(typeof(InstalledApps).FullName, throwOnError: true);
        Assert(launcher.GetMethod("LaunchCore") != null && launcher.GetMethod("UninstallCore") != null, "versioned launcher dispatch targets");
        app.Uninstall();
        Assert(!Directory.Exists(root) && stock.OrderBy(file => file.Key).SequenceEqual(Snapshot(source).OrderBy(file => file.Key)),
            "packaged mod cleanly uninstalled with stock restored");
        Console.WriteLine("PASS: embedded package installed and uninstalled in synthetic Steam and profile roots without launching");
        return 0;
    }

    private static System.Collections.Generic.Dictionary<string, string> Snapshot(string root) =>
        Directory.GetFiles(root, "*", SearchOption.AllDirectories).ToDictionary(file => file, Paths.Hash);

    private static int InterruptedChild(string scratch)
    {
        using var update = Fixture("interrupted");
        var installer = ForFixture(Preview, new FixtureIntegration());
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
        internal bool FailRegistration { get; set; }
        internal override void Prepare(string launcher, InstallState state) { }
        internal override void Register(string launcher, InstallState state, Action save)
        {
            if (FailRegistration)
                throw new IOException("Injected registration failure.");
            Registered = true;
        }
        internal override void Remove(string launcher, InstallState state) => Registered = false;
    }
}
