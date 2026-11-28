using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace Hades2Together.Setup;

internal abstract class Integration
{
    internal abstract void Prepare(string launcher, InstallState state);
    internal abstract void Register(string launcher, InstallState state, Action save);
    internal abstract void Remove(string launcher, InstallState state);
}

internal sealed class WindowsIntegration : Integration
{
    private const string ProgramsEntry = "Hades2Together Preview.lnk";
    private const string InstalledAppsKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Hades2Together.Preview";
    private const string OwnerValue = "Hades2TogetherPreviewOwner";
    private readonly string programs;
    private readonly string registryPath;
    private string Shortcut => Path.Combine(programs, ProgramsEntry);

    internal WindowsIntegration() : this(Environment.GetFolderPath(Environment.SpecialFolder.Programs), InstalledAppsKey) { }

    internal WindowsIntegration(string programs, string registryPath)
    {
        this.programs = Paths.Full(programs);
        this.registryPath = registryPath;
    }

    internal override void Prepare(string launcher, InstallState state)
    {
        using var folder = new Paths(programs);
        if (Paths.Exists(Shortcut) && (state.ShortcutHash == null || Paths.Hash(Shortcut) != state.ShortcutHash))
            throw new IOException("A Start menu entry already exists at " + Shortcut);
        using var key = Registry.CurrentUser.OpenSubKey(registryPath);
        if (key != null && !RegistryOwned(key, launcher))
            throw new IOException("A different application owns the preview Installed apps entry.");
    }

    internal override void Register(string launcher, InstallState state, Action save)
    {
        using var folder = new Paths(programs);
        if (!Paths.Exists(Shortcut))
        {
            var temp = Path.Combine(programs, Guid.NewGuid().ToString("N") + ".lnk");
            try
            {
                CreateShortcut(temp, launcher);
                state.ShortcutHash = Paths.Hash(temp);
                save();
                File.Move(temp, Shortcut);
            }
            finally { File.Delete(temp); }
        }
        using var key = Registry.CurrentUser.CreateSubKey(registryPath);
        key.SetValue(OwnerValue, launcher);
        key.SetValue("DisplayName", Texts.Choose("Hades2Together 预览版", "Hades2Together Preview"));
        key.SetValue("DisplayIcon", launcher);
        key.SetValue("Publisher", "Hades2Together");
        key.SetValue("InstallLocation", Path.GetDirectoryName(launcher));
        key.SetValue("UninstallString", UninstallCommand(launcher));
        key.SetValue("NoModify", 1, RegistryValueKind.DWord);
        key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
    }

    internal override void Remove(string launcher, InstallState state)
    {
        using (var folder = new Paths(programs))
        {
            if (state.ShortcutHash != null && Paths.Exists(Shortcut))
            {
                try
                {
                    Paths.DeleteVerified(Shortcut, null, state.ShortcutHash);
                }
                catch (IOException) { } // A replaced shortcut is left in place.
            }
        }
        using (var key = Registry.CurrentUser.OpenSubKey(registryPath))
        {
            if (key == null || !RegistryOwned(key, launcher))
                return;
        }
        Registry.CurrentUser.DeleteSubKey(registryPath, throwOnMissingSubKey: false);
    }

    private static bool RegistryOwned(RegistryKey key, string launcher) =>
        StringComparer.OrdinalIgnoreCase.Equals(key.GetValue(OwnerValue) as string, launcher);

    private static void CreateShortcut(string path, string launcher)
    {
        dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell", throwOnError: true));
        dynamic link = null;
        try
        {
            link = shell.CreateShortcut(path);
            link.TargetPath = launcher;
            link.Arguments = "--launch";
            link.WorkingDirectory = Path.GetDirectoryName(launcher);
            link.Description = Texts.Choose("启动 Hades2Together 预览版（禁用存档）", "Start Hades2Together Preview with saves disabled");
            link.Save();
        }
        finally
        {
            if (link != null)
                Marshal.FinalReleaseComObject(link);
            Marshal.FinalReleaseComObject(shell);
        }
    }

    internal static string UninstallScript(string launcher)
    {
        // Load from bytes so Windows can remove the installed executable during
        // this invocation. Windows PowerShell is included in Windows 10/11.
        var literal = "'" + launcher.Replace("'", "''") + "'";
        return "$ErrorActionPreference='Stop'; $p=" + literal +
            "; $item=[IO.Path]::GetPathRoot($p); foreach ($part in $p.Substring($item.Length).Split('\\')) {" +
            " $item=[IO.Path]::Combine($item,$part);" +
            " if (([IO.File]::GetAttributes($item) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {throw 'Redirected preview path'}" +
            " }" +
            " $assembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($p));" +
            " exit ($assembly.GetType('Hades2Together.Setup.InstalledApps').GetMethod('Uninstall').Invoke($null,$null))";
    }

    private static string UninstallCommand(string launcher)
    {
        var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(UninstallScript(launcher)));
        var host = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
        return "\"" + host + "\" -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand " + encoded;
    }
}
