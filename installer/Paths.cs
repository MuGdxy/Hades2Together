using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace Hades2Together.Setup;

// Keep directory components open without FILE_SHARE_DELETE while operating below
// them. Open links themselves on Windows, then reject them by handle.
internal sealed class Paths : IDisposable
{
    private readonly List<SafeFileHandle> directories = new List<SafeFileHandle>();

    internal Paths(string directory, bool create = false)
    {
        var root = Path.GetPathRoot(directory);
        if (root.Length != 3 || root[1] != ':' || root[2] != '\\')
            throw new IOException("Expected a local drive path.");
        try
        {
            directories.Add(Open(root, directory: true));
            var current = root;
            foreach (var part in directory.Substring(root.Length).Split(new[] { '\\' }, StringSplitOptions.RemoveEmptyEntries))
            {
                CheckRelative(part);
                current = Path.Combine(current, part);
                if (create && !Exists(current))
                    Directory.CreateDirectory(current);
                directories.Add(Open(current, directory: true));
            }
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    internal static string Full(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || path.StartsWith(@"\\", StringComparison.Ordinal))
            throw new IOException("Expected a local drive path.");
        return Path.GetFullPath(path).TrimEnd('\\', '/');
    }

    internal static string Child(string root, string relative)
    {
        CheckRelative(relative);
        return Path.Combine(root, relative.Replace('/', '\\'));
    }

    internal static void CheckRelative(string relative)
    {
        foreach (var part in relative.Split('/'))
        {
            if (part.Length == 0 || part.EndsWith(".") || part.EndsWith(" ") ||
                part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
                System.Text.RegularExpressions.Regex.IsMatch(part,
                    @"^(CON|PRN|AUX|NUL|COM[0-9¹²³]|LPT[0-9¹²³])(\.|$)",
                    System.Text.RegularExpressions.RegexOptions.IgnoreCase))
                throw new IOException("Unsafe package path: " + relative);
        }
    }

    internal static bool Exists(string path)
    {
        try { File.GetAttributes(path); return true; }
        catch (FileNotFoundException) { return false; }
        catch (DirectoryNotFoundException) { return false; }
    }

    internal static bool Ordinary(string path, bool directory)
    {
        using var handle = Open(path, directory);
        return true;
    }

    internal static void CheckPrivateFile(string path)
    {
        using var handle = Open(path, directory: false);
        if (!GetFileInformationByHandle(handle, out var info) || info.Links != 1)
            throw new IOException("The preview file has another filesystem link: " + path);
    }

    internal static FileStream Read(string path)
    {
        var handle = Open(path, directory: false);
        try { return new FileStream(handle, FileAccess.Read, 1024 * 1024); }
        catch { handle.Dispose(); throw; }
    }

    internal static string Hash(string path)
    {
        using var guard = new Paths(Path.GetDirectoryName(path));
        using var stream = Read(path);
        return Hash(stream);
    }

    internal static string Hash(Stream stream)
    {
        using var sha = SHA256.Create();
        return Hex(sha.ComputeHash(stream));
    }

    internal static string Hex(byte[] bytes) => BitConverter.ToString(bytes).Replace("-", "");

    internal static string Identity(string path, bool directory)
    {
        using var handle = Open(path, directory);
        return Identity(handle);
    }

    internal static string Identity(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out var info) || (info.IndexHigh == 0 && info.IndexLow == 0))
            throw new IOException("Windows could not identify the owned file or directory.");
        return $"{info.Volume:X8}:{info.IndexHigh:X8}{info.IndexLow:X8}";
    }

    internal static void DeleteVerified(string path, long? size, string hash, string identity = null)
    {
        using var handle = Open(path, directory: false, delete: true);
        if (identity != null && Identity(handle) != identity)
            return;
        using var stream = new FileStream(handle, FileAccess.Read, 1024 * 1024);
        if ((!size.HasValue || stream.Length == size.Value) && (hash == null || Hash(stream) == hash) &&
            !SetFileInformationByHandle(handle, 4, new byte[] { 1 }, 1))
            throw new IOException("Unable to remove the owned file: " + path);
    }

    public void Dispose()
    {
        for (var i = directories.Count - 1; i >= 0; i--)
            directories[i].Dispose();
    }

    private static SafeFileHandle Open(string path, bool directory, bool delete = false)
    {
        const uint read = 0x80000000, readAttributes = 0x80, deleteAccess = 0x00010000, openExisting = 3;
        const uint backupSemantics = 0x02000000, openReparse = 0x00200000;
        var access = (directory ? readAttributes : read) | (delete ? deleteAccess : 0);
        var shared = directory ? FileShare.Read | FileShare.Write : FileShare.Read;
        var handle = CreateFile(@"\\?\" + path, access, shared, IntPtr.Zero, openExisting,
            openReparse | (directory ? backupSemantics : 0), IntPtr.Zero);
        if (!handle.IsInvalid && GetFileInformationByHandle(handle, out var info) &&
            (info.Attributes & FileAttributes.ReparsePoint) == 0 &&
            ((info.Attributes & FileAttributes.Directory) != 0) == directory)
            return handle;
        handle.Dispose();
        throw new IOException("Missing, inaccessible or redirected path: " + path);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileInformation
    {
        internal FileAttributes Attributes;
        internal System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
        internal uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string name, uint access, FileShare share,
        IntPtr security, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation information);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int informationClass, byte[] information, uint size);
}
