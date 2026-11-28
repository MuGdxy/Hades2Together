using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace Hades2Together.Setup;

public sealed class InstallState
{
    public string Format { get; set; }
    public string Active { get; set; }
    public string Pending { get; set; }
    public bool Removing { get; set; }
    public string BootstrapHash { get; set; }
    public string ShortcutHash { get; set; }
    public Dictionary<string, string> Manifests { get; set; } = new Dictionary<string, string>();
}

public sealed class StageManifest
{
    public string Version { get; set; }
    public string Source { get; set; }
    public OwnedFile[] Files { get; set; }
}

internal sealed class Install
{
    private const string StateFormat = "Hades2Together.Preview/1";
    private const string ManifestName = "ownership.json";
    private const string IncomingName = ".incoming";
    internal const string LauncherName = "PreviewApp.exe";
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024 };
    private readonly string root;
    private readonly Integration integration;
    private string StateFile => Path.Combine(root, "state.json");
    private string Bootstrap => Path.Combine(root, "Preview.exe");

    internal Install(string root, Integration integration)
    {
        this.root = Paths.Full(root);
        this.integration = integration;
    }

    internal static Install ForUser() => new Install(
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Hades2Together", "Preview"),
        new WindowsIntegration());

    internal static void Exclusive(Action operation)
    {
        using var identity = WindowsIdentity.GetCurrent();
        using var mutex = new Mutex(false, @"Global\Hades2Together.Preview." + identity.User.Value);
        try
        {
            if (!mutex.WaitOne(0))
                throw new IOException(Texts.Choose("请先关闭预览版或其他安装窗口。", "Close the preview or another active setup operation first."));
        }
        catch (AbandonedMutexException) { }
        try { operation(); }
        finally { mutex.ReleaseMutex(); }
    }

    internal void Apply(Package package, string source, Action<string> progress)
    {
        source = Paths.Full(source);
        if (Contains(source, root) || Contains(root, source))
            throw new IOException("The Steam game and preview folders must be separate.");
        var state = ReadState();
        if (state.Removing)
            throw new IOException(Texts.Choose("请先完成卸载，再重新安装。", "Finish uninstalling the preview before reinstalling."));
        var previousId = state.Active;
        var previous = previousId == null ? null : ReadManifest(state, previousId);
        SteamGame.Check(source, package.SteamFiles, progress);

        // Validate the entire source and check space before starting a new transaction.
        var reuse = previous != null && previous.Version == package.Version &&
            string.Equals(previous.Source, source, StringComparison.OrdinalIgnoreCase) &&
            previous.Files.SequenceEqual(package.Files, new FileIdentity()) &&
            previous.Files.All(file => SteamGame.Matches(Stage(state.Active), file, strict: false));
        if (!reuse)
        {
            var available = new DriveInfo(Path.GetPathRoot(root)).AvailableFreeSpace;
            var needed = package.Bytes + package.Bootstrap.Size + 64L * 1024 * 1024;
            if (available < needed)
                throw new IOException(Texts.Choose("预览目录磁盘空间不足，需要 ", "The preview drive needs ") + Texts.Space(needed));
        }

        using var guard = new Paths(root, create: true);
        if (state.Pending != null)
        {
            CollectRetired(state);
            if (state.Pending != null)
                throw new IOException("An interrupted setup could not be recovered.");
        }
        integration.Prepare(Bootstrap, state);
        if (reuse)
        {
            CheckBootstrap(state);
            integration.Register(Bootstrap, state, () => Save(state));
            Save(state);
            CollectRetired(state);
            return;
        }

        var id = Guid.NewGuid().ToString("N");
        var stage = Stage(id);
        var manifest = new StageManifest { Version = package.Version, Source = source, Files = package.Files.ToArray() };
        var manifestBytes = Encode(manifest);
        if (state.BootstrapHash == null)
        {
            if (Paths.Exists(Bootstrap))
                throw new IOException("An unrelated file occupies the preview launcher path.");
            state.BootstrapHash = package.Bootstrap.Hash;
        }
        using (var stream = new MemoryStream(manifestBytes))
            state.Manifests.Add(id, Paths.Hash(stream));
        state.Pending = id;
        Save(state);
        var isFirstInstall = state.Active == null;
        var installedBootstrap = false;
        var registered = false;
        try
        {
            using (var stageGuard = new Paths(stage, create: true))
            {
                var incoming = Path.Combine(stage, IncomingName);
                WriteNew(incoming, manifestBytes);
                File.Move(incoming, Path.Combine(stage, ManifestName));
                foreach (var file in package.SteamFiles)
                {
                    progress?.Invoke(file.Name);
                    var from = Paths.Child(source, file.Name);
                    using var sourceGuard = new Paths(Path.GetDirectoryName(from));
                    using var stream = Paths.Read(from);
                    CopyVerified(stage, file, stream, stage);
                }
                foreach (var file in package.Additions)
                {
                    using var stream = package.Open(file);
                    CopyVerified(stage, file, stream, stage);
                }
            }

            if (isFirstInstall && !Paths.Exists(Bootstrap))
            {
                state.BootstrapHash = package.Bootstrap.Hash;
                using var stream = package.Open(package.Bootstrap);
                CopyVerified(root, package.Bootstrap, stream, stage);
                installedBootstrap = true;
            }
            else
            {
                CheckBootstrap(state);
            }
            registered = true;
            integration.Register(Bootstrap, state, () => Save(state));
            state.Active = id;
            state.Pending = null;
            Save(state); // The previous generation remains active until this atomic replace.
        }
        catch
        {
            state.Active = previousId;
            state.Pending = id;
            if (isFirstInstall && registered)
                integration.Remove(Bootstrap, state);
            if (installedBootstrap)
            {
                DeleteMatching(root, package.Bootstrap);
            }
            if (isFirstInstall && !Paths.Exists(Bootstrap))
                state.BootstrapHash = null;
            Save(state);
            CollectRetired(state);
            throw;
        }
        CollectRetired(state);
    }

    internal void Uninstall()
    {
        var state = ReadState();
        if (!Paths.Exists(StateFile))
            return;
        using (var guard = new Paths(root))
        {
            foreach (var id in state.Manifests.Keys)
            {
                var stage = Stage(id);
                using var stageGuard = Paths.Exists(stage) ? new Paths(stage) : null;
                if (id == state.Pending && !Paths.Exists(Path.Combine(stage, ManifestName)))
                    continue;
                ReadManifest(state, id);
            }
            // Retire every generation before deleting it. An interrupted removal can be retried.
            state.Active = null;
            state.Removing = true;
            Save(state);
            CollectRetired(state);
            if (state.Manifests.Count != 0)
                throw new IOException(Texts.Choose("部分安装文件仍被占用，或所有权清单已改变。", "Some installed files are busy or an ownership manifest has changed."));
            integration.Remove(Bootstrap, state);
            if (state.BootstrapHash != null && Paths.Exists(Bootstrap) && !IsRedirectedOrMissing(root, "Preview.exe"))
                Paths.DeleteVerified(Bootstrap, null, state.BootstrapHash);
            File.Delete(StateFile);
        }
        using var parent = new Paths(Path.GetDirectoryName(root));
        DeleteEmpty(root);
    }

    internal void Launch()
    {
        using var guard = new Paths(root);
        var state = ReadState();
        if (state.Active == null)
            throw new IOException(Texts.Choose("请先安装 Hades2Together 预览版。", "Install the Hades2Together preview first."));
        var stage = Stage(state.Active);
        using var stageGuard = new Paths(stage);
        var manifest = ReadManifest(state, state.Active);
        var required = SteamGame.Critical.Concat(new[] { "Ship/d3d12.dll" });
        foreach (var name in required)
        {
            var file = manifest.Files.Single(item => item.Name == name);
            if (!SteamGame.Matches(stage, file, strict: true))
                throw new IOException(Texts.Choose("预览文件已改变，请重新安装：", "A preview file changed. Reinstall the preview: ") + name);
        }
        CheckTree(stage);
        var ship = Path.Combine(stage, "Ship");
        var profile = Path.Combine(stage, "profile");
        using var profileGuard = new Paths(Path.Combine(profile, "Hades2Together"), create: true);
        var start = new System.Diagnostics.ProcessStartInfo(Path.Combine(ship, "Hades2.exe"))
        {
            UseShellExecute = false,
            WorkingDirectory = ship,
            Arguments = "/Windowed=true /RequireFocusToUpdate=false /AllowSaveLoad=false /UseDevSaves=true " +
                "/DevSavePathStr=\"" + profile + "\" /AllowControlHotSwap=false /DirectLoad=F_Combat02 /DirectLoadShell=false"
        };
        start.EnvironmentVariables["USERPROFILE"] = profile;
        start.EnvironmentVariables["SteamAppId"] = SteamGame.AppId;
        start.EnvironmentVariables["H2T_SAMPLER_SCRATCH_SHIP"] = ship;
        using var game = System.Diagnostics.Process.Start(start);
        game.WaitForExit();
        if (game.ExitCode != 0)
            throw new IOException(Texts.Choose("预览游戏退出，代码 ", "The preview game exited with code ") + game.ExitCode);
    }

    internal byte[] ReadActiveLauncher(bool allowUninstallRecovery = false)
    {
        if (!Paths.Exists(root) && allowUninstallRecovery)
            return null;
        using var guard = new Paths(root);
        var state = ReadState();
        if (state.Active == null && allowUninstallRecovery)
            return null;
        if (state.Active == null)
            throw new IOException(Texts.Choose("请先安装 Hades2Together 预览版。", "Install the Hades2Together preview first."));
        var stage = Stage(state.Active);
        using var stageGuard = new Paths(stage);
        var manifest = ReadManifest(state, state.Active);
        var launcher = manifest.Files.Single(item => item.Name == LauncherName);
        using var stream = Paths.Read(Path.Combine(stage, LauncherName));
        if (launcher.Size != stream.Length || launcher.Size > 16 * 1024 * 1024 || Paths.Hash(stream) != launcher.Hash)
            throw new IOException("The active preview launcher has changed.");
        stream.Position = 0;
        using var memory = new MemoryStream((int)launcher.Size);
        stream.CopyTo(memory);
        return memory.ToArray();
    }

    private static bool Contains(string parent, string path) =>
        string.Equals(parent, path, StringComparison.OrdinalIgnoreCase) ||
        path.StartsWith(parent + "\\", StringComparison.OrdinalIgnoreCase);

    private InstallState ReadState()
    {
        if (!Paths.Exists(root))
            return new InstallState { Format = StateFormat };
        using var guard = new Paths(root);
        if (!Paths.Exists(StateFile))
            return new InstallState { Format = StateFormat };
        using var stream = Paths.Read(StateFile);
        using var reader = new StreamReader(stream);
        var state = Json.Deserialize<InstallState>(reader.ReadToEnd());
        if (state?.Format != StateFormat || state.Manifests == null ||
            (state.Active != null && (!state.Manifests.ContainsKey(state.Active) || state.Removing)) ||
            (state.Pending != null && (!state.Manifests.ContainsKey(state.Pending) || state.Pending == state.Active)) ||
            !ValidHash(state.BootstrapHash) || !ValidHash(state.ShortcutHash) ||
            state.Manifests.Any(entry => !Id(entry.Key) || entry.Value == null || !ValidHash(entry.Value)))
            throw new IOException("Invalid preview installation state.");
        return state;
    }

    private static bool Id(string id) => Regex.IsMatch(id, "^[a-f0-9]{32}$");
    private static bool ValidHash(string hash) => hash == null || Regex.IsMatch(hash, "^[A-F0-9]{64}$");

    private string Stage(string id)
    {
        if (!Id(id))
            throw new IOException("Invalid preview generation.");
        return Path.Combine(root, "version-" + id);
    }

    private StageManifest ReadManifest(InstallState state, string id)
    {
        var stage = Stage(id);
        using var guard = new Paths(stage);
        using var stream = Paths.Read(Path.Combine(stage, ManifestName));
        if (Paths.Hash(stream) != state.Manifests[id])
            throw new IOException("Preview ownership manifest has changed.");
        stream.Position = 0;
        using var reader = new StreamReader(stream);
        var manifest = Json.Deserialize<StageManifest>(reader.ReadToEnd());
        if (manifest?.Files == null)
            throw new IOException("Invalid preview ownership manifest.");
        OwnedFile.Validate(manifest.Files);
        return manifest;
    }

    private static byte[] Encode(object data) => Encoding.UTF8.GetBytes(Json.Serialize(data));

    private void Save(InstallState state)
    {
        var temporary = Path.Combine(root, "state-" + Guid.NewGuid().ToString("N") + ".tmp");
        WriteNew(temporary, Encode(state));
        try
        {
            if (Paths.Exists(StateFile))
            {
                Paths.Ordinary(StateFile, directory: false);
                File.Replace(temporary, StateFile, null);
            }
            else
            {
                File.Move(temporary, StateFile);
            }
        }
        finally { File.Delete(temporary); }
    }

    private static void WriteNew(string path, byte[] bytes)
    {
        using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        stream.Write(bytes, 0, bytes.Length);
        stream.Flush(true);
    }

    private static void CopyVerified(string destination, OwnedFile file, Stream input, string staging)
    {
        var path = Paths.Child(destination, file.Name);
        using var guard = new Paths(Path.GetDirectoryName(path), create: true);
        using var stagingGuard = new Paths(staging);
        var incoming = Path.Combine(staging, IncomingName);
        var created = false;
        try
        {
            using (var output = new FileStream(incoming, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1024 * 1024))
            {
                created = true;
                input.CopyTo(output, 1024 * 1024);
                output.Flush(true);
            }
            using (var check = Paths.Read(incoming))
            {
                if (check.Length != file.Size || Paths.Hash(check) != file.Hash)
                    throw new IOException("A file changed during staging: " + file.Name);
            }
            File.Move(incoming, path);
        }
        catch
        {
            if (created)
                File.Delete(incoming);
            throw;
        }
    }

    private void CheckBootstrap(InstallState state)
    {
        if (state.BootstrapHash == null || Paths.Hash(Bootstrap) != state.BootstrapHash)
            throw new IOException("The preview launcher is missing or has changed.");
    }

    private void CollectRetired(InstallState state)
    {
        foreach (var id in state.Manifests.Keys.Where(id => id != state.Active).ToArray())
        {
            var hash = state.Manifests[id];
            if (RemoveStage(state, id))
            {
                state.Manifests.Remove(id);
                if (state.Pending == id)
                    state.Pending = null;
                Save(state);
                var stage = Stage(id);
                if (Paths.Exists(stage))
                {
                    try
                    {
                        using (var guard = new Paths(stage))
                        {
                            var manifest = Path.Combine(stage, ManifestName);
                            if (Paths.Exists(manifest))
                                Paths.DeleteVerified(manifest, null, hash);
                        }
                        DeleteEmpty(stage);
                    }
                    catch (IOException) { }
                    catch (UnauthorizedAccessException) { }
                }
            }
        }
    }

    private bool RemoveStage(InstallState state, string id)
    {
        var stage = Stage(id);
        if (!Paths.Exists(stage))
            return true;
        try
        {
            using (var guard = new Paths(stage))
            {
                if (state.Pending == id)
                {
                    var incoming = Path.Combine(stage, IncomingName);
                    if (Paths.Exists(incoming))
                    {
                        Paths.CheckPrivateFile(incoming);
                        File.Delete(incoming);
                    }
                    if (!Paths.Exists(Path.Combine(stage, ManifestName)))
                        return !Directory.EnumerateFileSystemEntries(stage).Any();
                }
                var manifest = ReadManifest(state, id);
                foreach (var file in manifest.Files)
                    DeleteMatching(stage, file);
                var directories = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var file in manifest.Files)
                {
                    var directory = Path.GetDirectoryName(Paths.Child(stage, file.Name));
                    while (directory.Length > stage.Length)
                    {
                        directories.Add(directory);
                        directory = Path.GetDirectoryName(directory);
                    }
                }
                foreach (var directory in directories.OrderByDescending(path => path.Length))
                {
                    var relative = directory.Substring(stage.Length + 1).Replace('\\', '/');
                    if (!IsRedirectedOrMissing(stage, relative))
                        DeleteEmpty(directory);
                }
            }
            return true;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    private static void DeleteMatching(string directory, OwnedFile file)
    {
        var path = Paths.Child(directory, file.Name);
        var parent = Path.GetDirectoryName(path);
        try
        {
            using var guard = new Paths(parent);
            if (Paths.Exists(path))
                Paths.DeleteVerified(path, file.Size, file.Hash);
        }
        catch (IOException) when (IsRedirectedOrMissing(directory, file.Name)) { }
    }

    private static bool IsRedirectedOrMissing(string root, string relative)
    {
        var current = root;
        foreach (var name in relative.Split('/'))
        {
            current = Path.Combine(current, name);
            if (!Paths.Exists(current) || (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                return true;
        }
        return false;
    }

    private static void DeleteEmpty(string directory)
    {
        using var parent = new Paths(Path.GetDirectoryName(directory));
        if (!Paths.Exists(directory) ||
            (File.GetAttributes(directory) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != FileAttributes.Directory)
            return;
        using (var guard = new Paths(directory))
        {
            if (Directory.EnumerateFileSystemEntries(directory).Any())
                return;
        }
        Directory.Delete(directory, recursive: false);
    }

    private static void CheckTree(string directory)
    {
        using var guard = new Paths(directory);
        foreach (var entry in Directory.EnumerateFileSystemEntries(directory))
        {
            var attributes = File.GetAttributes(entry);
            if ((attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Redirected preview file: " + entry);
            if ((attributes & FileAttributes.Directory) != 0)
                CheckTree(entry);
            else
                Paths.CheckPrivateFile(entry);
        }
    }

    private sealed class FileIdentity : IEqualityComparer<OwnedFile>
    {
        public bool Equals(OwnedFile x, OwnedFile y) => x.Name == y.Name && x.Hash == y.Hash && x.Size == y.Size;
        public int GetHashCode(OwnedFile file) => file.Name.GetHashCode();
    }
}
