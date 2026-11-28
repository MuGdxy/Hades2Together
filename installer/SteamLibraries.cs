using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace Hades2Together.Setup;

internal static class SteamLibraries
{
    internal static IEnumerable<string> Find()
    {
        using var user = Registry.CurrentUser.OpenSubKey(@"Software\Valve\Steam");
        using var machine = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\WOW6432Node\Valve\Steam");
        var defaultRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Steam");
        var libraries = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var client in new[] { user?.GetValue("SteamPath") as string, machine?.GetValue("InstallPath") as string, defaultRoot })
        {
            if (string.IsNullOrEmpty(client))
                continue;
            libraries.Add(client);
            var contents = ReadVdf(client, "steamapps/libraryfolders.vdf");
            foreach (Match match in Regex.Matches(contents, @"(?m)^\s*""(?:path|\d+)""[ \t]+""((?:\\.|[^""\\])+)"""))
            {
                var path = match.Groups[1].Value.Replace(@"\\", @"\");
                if (Regex.IsMatch(path, @"^[a-zA-Z]:[/\\]"))
                    libraries.Add(path);
            }
        }

        foreach (var library in libraries)
        {
            var manifest = ReadVdf(library, "steamapps/appmanifest_" + SteamGame.AppId + ".acf");
            if (!Regex.IsMatch(manifest, @"(?m)^[ \t]*""appid""[ \t]+""" + SteamGame.AppId + @""""))
                continue;
            var match = Regex.Match(manifest, @"(?m)^[ \t]*""installdir""[ \t]+""([^""/\\]+)""");
            if (!match.Success)
                continue;
            var folder = match.Groups[1].Value;
            string candidate;
            try
            {
                Paths.CheckRelative(folder);
                candidate = Paths.Full(Path.Combine(library, "steamapps", "common", folder));
            }
            catch (IOException) { continue; }
            yield return candidate;
        }
    }

    private static string ReadVdf(string root, string relative)
    {
        try
        {
            var file = Paths.Child(Paths.Full(root), relative);
            using var guard = new Paths(Path.GetDirectoryName(file));
            using var stream = Paths.Read(file);
            if (stream.Length > 1024 * 1024)
                return "";
            using var reader = new StreamReader(stream);
            return reader.ReadToEnd();
        }
        catch (IOException) { return ""; }
        catch (UnauthorizedAccessException) { return ""; }
        catch (ArgumentException) { return ""; }
    }
}
