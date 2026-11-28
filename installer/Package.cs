using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Text;
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
    internal IReadOnlyList<OwnedFile> SteamFiles { get; }
    internal IReadOnlyList<OwnedFile> Additions { get; }
    internal OwnedFile Bootstrap { get; }
    internal long Bytes { get; }
    internal string Version { get; }
    internal IEnumerable<OwnedFile> Files => SteamFiles.Concat(Additions);

    internal Package(Stream catalog, Stream payload, string version)
    {
        Version = version;
        using (var reader = new StreamReader(catalog, Encoding.UTF8))
        {
            var files = new List<OwnedFile>();
            for (var line = reader.ReadLine(); line != null; line = reader.ReadLine())
            {
                var columns = line.Split('\t');
                if (columns.Length != 3 || !(columns[0].StartsWith("Ship/") || columns[0].StartsWith("Content/")))
                    throw new IOException("Invalid Steam inventory.");
                files.Add(new OwnedFile { Name = columns[0], Size = long.Parse(columns[1], CultureInfo.InvariantCulture), Hash = columns[2] });
            }
            SteamFiles = files;
        }
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
                else
                {
                    additions.Add(file);
                }
            }
            if (Bootstrap == null || !additions.Any(file => file.Name == Install.LauncherName))
                throw new IOException("Missing preview launcher or bootstrap.");
            Additions = additions;
            OwnedFile.Validate(Files.Append(Bootstrap));
            Bytes = Files.Sum(file => file.Size);
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
        return new Package(assembly.GetManifestResourceStream("steam.tsv"),
            assembly.GetManifestResourceStream("payload.zip"),
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
    internal static readonly string[] Critical = {
        "Ship/Hades2.exe", "Ship/Hades2.pdb", "Ship/SDL2.dll",
        "Content/Scripts/Main.lua", "Content/Maps/F_Combat02.map_text"
    };

    internal static void Check(string root, IEnumerable<OwnedFile> files, Action<string> progress)
    {
        using var guard = new Paths(root);
        foreach (var file in files)
        {
            progress?.Invoke(file.Name);
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
