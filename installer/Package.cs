using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Text.RegularExpressions;

namespace Hades2Together.Setup;

public sealed class OwnedFile
{
    public string Name { get; set; }
    public long Size { get; set; }
    public string Hash { get; set; }

    internal static void Validate(IEnumerable<OwnedFile> files)
    {
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var file in files)
        {
            Paths.CheckRelative(file.Name);
            if (!names.Add(file.Name) || file.Size < 0 || !Regex.IsMatch(file.Hash, "^[A-F0-9]{64}$"))
                throw new IOException("Invalid inventory: " + file.Name);
        }
    }
}

internal sealed class Package : IDisposable
{
    private readonly ZipArchive archive;
    internal IReadOnlyList<OwnedFile> Additions { get; }
    internal OwnedFile Bootstrap { get; }
    internal OwnedFile Loader { get; }
    internal long ProfileBytes { get; }
    internal string Version { get; }

    internal Package(Stream payload, string version)
    {
        Version = version;
        archive = new ZipArchive(payload, ZipArchiveMode.Read);
        try
        {
            var additions = new List<OwnedFile>();
            foreach (var entry in archive.Entries)
            {
                using var stream = entry.Open();
                var file = new OwnedFile { Name = entry.FullName, Size = entry.Length, Hash = Paths.Hash(stream) };
                if (entry.FullName == "Preview.exe")
                {
                    if (Bootstrap != null)
                        throw new IOException("Duplicate launcher.");
                    Bootstrap = file;
                }
                else if (entry.FullName == "Ship/" + GameSlot.LoaderName)
                {
                    if (Loader != null)
                        throw new IOException("Duplicate game loader.");
                    Loader = file;
                }
                else
                {
                    if (entry.FullName != Install.LauncherName &&
                        !entry.FullName.StartsWith("ReturnOfModding/", StringComparison.Ordinal) &&
                        !entry.FullName.StartsWith("Notices/", StringComparison.Ordinal))
                        throw new IOException("Unexpected preview payload: " + entry.FullName);
                    additions.Add(file);
                }
            }
            if (Bootstrap == null || Loader == null || !additions.Any(file => file.Name == Install.LauncherName))
                throw new IOException("Missing preview launcher, bootstrap or game loader.");
            Additions = additions;
            OwnedFile.Validate(Additions.Append(Bootstrap).Append(Loader));
            ProfileBytes = Bootstrap.Size + Additions.Sum(file => file.Size);
        }
        catch
        {
            archive.Dispose();
            throw;
        }
    }

    internal static Package Embedded()
    {
        var assembly = Assembly.GetExecutingAssembly();
        return new Package(assembly.GetManifestResourceStream("payload.zip"),
            assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>().InformationalVersion);
    }

    internal Stream Open(OwnedFile file) => archive.GetEntry(file.Name).Open();

    internal string Notice()
    {
        using var main = new StreamReader(archive.GetEntry("Notices/NOTICE.txt").Open());
        var loader = archive.GetEntry("Notices/Loader/NOTICE.txt");
        if (loader == null)
            return main.ReadToEnd();
        using var details = new StreamReader(loader.Open());
        return main.ReadToEnd() + "\r\n\r\n" + details.ReadToEnd();
    }

    public void Dispose() => archive.Dispose();
}

internal static class SteamGame
{
    internal const string AppId = "1145350";
    internal static readonly OwnedFile[] Pins = {
        new OwnedFile { Name = "Ship/Hades2.exe", Size = 6432432, Hash = "A6BE16E91683E6FE3E566C5D68C1DCF8992BAB9126B856606D57B7115E9C30DC" },
        new OwnedFile { Name = "Ship/Hades2.pdb", Size = 37187584, Hash = "DFEBC6219DEAAAA1D96DC03FE2866D14CA621E1836F685FF40E989C81D577EA7" },
        new OwnedFile { Name = "Ship/SDL2.dll", Size = 1576448, Hash = "7457CC5C885505B7EBF9C05AD57881468C3DBBA551B3DF8E18CE5D31A09F6A2C" },
        new OwnedFile { Name = "Content/Scripts/Main.lua", Size = 15946, Hash = "CC64A8D7838CF60198D20E8D3C33D7B7792430BC4D86E700CA54925D122D236C" },
        new OwnedFile { Name = "Content/Maps/F_Combat02.map_text", Size = 11829, Hash = "42B5E48375FFDB3C858FCBE61F6C8EE4AF1B96AA98F747387131B794AD8D4970" }
    };

    internal static void Check(string root, IEnumerable<OwnedFile> files)
    {
        using var guard = new Paths(root);
        foreach (var file in files)
        {
            if (!Matches(root, file, strict: false))
                throw new IOException(Texts.Choose("Steam 文件缺失、被重定向或与支持版本不符：",
                    "A Steam file is missing, redirected or differs from the supported build: ") + file.Name);
        }
    }

    internal static bool Matches(string root, OwnedFile file, bool strict)
    {
        var path = Paths.Child(root, file.Name);
        try
        {
            using var guard = new Paths(Path.GetDirectoryName(path));
            using var stream = Paths.Read(path);
            return stream.Length == file.Size && Paths.Hash(stream) == file.Hash;
        }
        catch (IOException) when (!strict) { return false; }
        catch (UnauthorizedAccessException) when (!strict) { return false; }
    }
}
