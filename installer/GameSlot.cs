using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace Hades2Together.Setup;

public sealed class GameFileClaim
{
    public string Generation { get; set; }
    public string Ship { get; set; }
    public string ShipIdentity { get; set; }
    public string Kind { get; set; }
    public string Identity { get; set; }
    public string Hash { get; set; }

    internal string FinalPath => Path.Combine(Ship, Kind == "loader" ? GameSlot.LoaderName : GameSlot.MarkerName);
    internal string TempPath => Path.Combine(Ship, ".hades2t-" + Generation + "-" + Kind + ".tmp");

    internal bool Valid() =>
        Generation != null && Regex.IsMatch(Generation, "^[a-f0-9]{32}$") &&
        (Kind == "loader" || Kind == "reason") &&
        Ship != null && Paths.Full(Ship) == Ship && Path.GetFileName(Ship).Equals("Ship", StringComparison.OrdinalIgnoreCase) &&
        Hash != null && Regex.IsMatch(Hash, "^[A-F0-9]{64}$") &&
        (Kind != "reason" || Hash == GameSlot.MarkerHash) &&
        CheckedIdentity(ShipIdentity) && CheckedIdentity(Identity);

    private static bool CheckedIdentity(string identity) => identity != null && Regex.IsMatch(identity, "^[A-F0-9]{8}:[A-F0-9]{16}$");
}

internal sealed class GameSlot
{
    internal const string LoaderName = "d3d12.dll";
    internal const string MarkerName = "ReturnOfModdingFirstEnabledReason.txt";
    // rom::enabled_reason::ENABLED_BY_ENV_VAR. With either explicit-on
    // first reason, ordinary Steam launches leave modding disabled.
    private static readonly byte[] MarkerBytes = Encoding.ASCII.GetBytes("2\r\n");
    internal const string MarkerHash = "DF4E26A04A444901B95AFEF44E4A96CFAE34690FFF2AD2C66389C70079CDFF2B";

    internal string Ship { get; }
    internal string ShipIdentity { get; }
    internal bool NeedsLoader { get; }
    internal bool NeedsMarker { get; }
    internal long SteamBytes { get; }

    internal GameSlot(string source, OwnedFile loader)
    {
        Ship = Path.Combine(source, "Ship");
        using var guard = new Paths(Ship);
        ShipIdentity = Paths.Identity(Ship, directory: true);
        var dllPath = Path.Combine(Ship, LoaderName);
        var markerPath = Path.Combine(Ship, MarkerName);
        NeedsLoader = !Paths.Exists(dllPath);
        NeedsMarker = !Paths.Exists(markerPath);
        if (!NeedsLoader)
        {
            if (!SteamGame.Matches(source, loader, strict: false))
                throw new IOException(Texts.Choose(
                    "Steam 游戏目录已安装其他 d3d12.dll。请使用没有冲突加载器的兼容游戏目录。",
                    "The game already has a different Ship\\d3d12.dll. Choose a compatible installation without a conflicting loader."));
            if (NeedsMarker)
                throw new IOException(Texts.Choose(
                    "现有加载器尚未初始化。请按平时的方式从 Steam 启动游戏一次，然后关闭游戏并重试。",
                    "The existing loader has no first-launch settings. Start the game normally from Steam once, then close it and retry Setup."));
        }
        else
        {
            if (ExplicitEnvironment())
                throw new IOException(Texts.Choose(
                    "检测到启用加载器的 rom_enabled 环境设置。请清除该设置后重试。",
                    "An existing rom_enabled environment setting would enable the loader on normal launches. Clear it before installing."));
            if (!NeedsMarker && !ExplicitFirstReason(markerPath))
                throw IncompatibleMarker();
        }
        if (!NeedsMarker)
            Paths.Ordinary(markerPath, directory: false);
        SteamBytes = (NeedsLoader ? loader.Size : 0) + (NeedsMarker ? MarkerBytes.Length : 0);
    }

    internal void Publish(Package package, InstallState state, string generation, Action save)
    {
        using var guard = new Paths(Ship);
        if (Paths.Identity(Ship, directory: true) != ShipIdentity)
            throw new IOException("The Steam game folder moved during setup.");
        var current = new GameSlot(Path.GetDirectoryName(Ship), package.Loader);
        if (!current.NeedsLoader)
            return;
        if (current.SteamBytes > SteamBytes)
            throw new IOException("The loader slot changed while Setup was running. Run Setup again.");
        try
        {
            if (current.NeedsMarker)
            {
                using var reason = new MemoryStream(MarkerBytes, writable: false);
                var hash = Paths.Hash(reason);
                if (hash != MarkerHash)
                    throw new IOException("Invalid built-in loader settings.");
                reason.Position = 0;
                Place("reason", MarkerHash, reason, state, generation, save);
            }
            using var marker = Paths.Read(Path.Combine(Ship, MarkerName));
            if (!ExplicitFirstReason(marker))
                throw IncompatibleMarker();
            using var loader = package.Open(package.Loader);
            Place("loader", package.Loader.Hash, loader, state, generation, save);
        }
        catch (Exception error) when (error is UnauthorizedAccessException ||
            (error is IOException io && (io.HResult & 0xFFFF) == 19))
        {
            throw new IOException(Texts.Choose(
                "无法写入 Steam 游戏的 Ship 目录。请在 Steam 中将游戏移到当前账户可写的库，然后重试。",
                "Setup cannot write to this game's Ship folder. Move the game in Steam to a library your Windows account can write to, then rerun Setup."), error);
        }
    }

    private void Place(string kind, string hash, Stream input, InstallState state, string generation, Action save)
    {
        var claim = new GameFileClaim { Generation = generation, Ship = Ship, ShipIdentity = ShipIdentity, Kind = kind, Hash = hash };
        var created = false;
        try
        {
            using (var output = new FileStream(claim.TempPath, FileMode.CreateNew, FileAccess.Write, FileShare.Read))
            {
                created = true;
                claim.Identity = Paths.Identity(output.SafeFileHandle);
                state.GameFiles.Add(claim);
                save(); // Journal the file ID before writing or publishing the file.
                input.CopyTo(output);
                output.Flush(true);
            }
            if (Paths.Hash(claim.TempPath) != hash)
                throw new IOException("The loader file changed during setup.");
            File.Move(claim.TempPath, claim.FinalPath);
        }
        catch
        {
            if (created && Paths.Exists(claim.TempPath) && claim.Identity != null)
                Paths.DeleteVerified(claim.TempPath, null, null, claim.Identity);
            throw;
        }
    }

    internal static void RebindKnownMoves(InstallState state, GameSlot selected)
    {
        using var guard = new Paths(selected.Ship);
        if (Paths.Identity(selected.Ship, directory: true) != selected.ShipIdentity)
            throw new IOException("The Steam game folder moved during setup.");
        foreach (var claim in state.GameFiles.Where(file => file.ShipIdentity == selected.ShipIdentity))
        {
            var name = claim.Kind == "loader" ? LoaderName : MarkerName;
            var candidate = Path.Combine(selected.Ship, name);
            if (!Paths.Exists(candidate) || (File.GetAttributes(candidate) & FileAttributes.ReparsePoint) != 0)
                continue;
            if (Paths.Identity(candidate, directory: false) == claim.Identity && Paths.Hash(candidate) == claim.Hash)
                claim.Ship = selected.Ship;
        }
    }

    internal static void Remove(InstallState state, string generation)
    {
        var files = state.GameFiles.Where(file => generation == null || file.Generation == generation)
            .OrderBy(file => file.Kind == "loader" ? 0 : 1).ToArray();
        foreach (var file in files)
        {
            using var guard = LocateClaim(file);
            if (guard != null)
            {
                RemoveMatching(file.TempPath, file.Identity, hash: null);
                if (file.Kind == "loader" || !Paths.Exists(Path.Combine(file.Ship, LoaderName)))
                    RemoveMatching(file.FinalPath, file.Identity, file.Hash);
            }
            state.GameFiles.Remove(file);
        }
    }

    private static Paths LocateClaim(GameFileClaim file)
    {
        Paths guard;
        try { guard = new Paths(file.Ship); }
        catch (IOException) { return null; }
        if (Paths.Identity(file.Ship, directory: true) == file.ShipIdentity)
            return guard;
        guard.Dispose();
        return null;
    }

    private static void RemoveMatching(string path, string identity, string hash)
    {
        if (!Paths.Exists(path) || (File.GetAttributes(path) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0)
            return;
        Paths.DeleteVerified(path, null, hash, identity);
    }

    internal static ProcessStartInfo StartInfo(string source, string stage, string profile)
    {
        var ship = Path.Combine(source, "Ship");
        var start = new ProcessStartInfo(Path.Combine(ship, "Hades2.exe"))
        {
            UseShellExecute = false,
            WorkingDirectory = ship,
            Arguments = "/Windowed=true /RequireFocusToUpdate=false /AllowSaveLoad=false /UseDevSaves=true " +
                "/DevSavePathStr=\"" + profile + "\" /AllowControlHotSwap=false /DirectLoad=F_Combat02 /DirectLoadShell=false"
        };
        start.EnvironmentVariables["USERPROFILE"] = profile;
        start.EnvironmentVariables["SteamAppId"] = SteamGame.AppId;
        start.EnvironmentVariables["H2T_SAMPLER_SCRATCH_SHIP"] = ship;
        start.EnvironmentVariables["rom_enabled"] = "true";
        start.EnvironmentVariables["rom_modding_root_folder"] = stage;
        return start;
    }

    private static bool ExplicitEnvironment() => new[] {
        EnvironmentVariableTarget.Process, EnvironmentVariableTarget.User, EnvironmentVariableTarget.Machine
    }.Any(scope => Environment.GetEnvironmentVariable("rom_enabled", scope)?.Contains("true") == true);

    private static bool ExplicitFirstReason(string path)
    {
        using var stream = Paths.Read(path);
        return ExplicitFirstReason(stream);
    }

    private static bool ExplicitFirstReason(Stream stream)
    {
        if (stream.Length > 32)
            return false;
        using var reader = new StreamReader(stream, Encoding.ASCII, false, 1024, leaveOpen: true);
        var reason = reader.ReadToEnd().Trim();
        return reason == "2" || reason == "4";
    }

    private static IOException IncompatibleMarker() => new IOException(Texts.Choose(
        "现有加载器设置会在普通 Steam 启动时启用模组。请选择没有冲突加载器设置的兼容游戏目录。",
        "Existing loader settings would enable modding during normal Steam launches. Choose a compatible game folder without conflicting loader settings."));
}
