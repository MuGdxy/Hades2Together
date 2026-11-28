using System;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.ExceptionServices;
using System.Threading.Tasks;
using System.Windows.Forms;

[assembly: System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.8")]

namespace Hades2Together.Setup;

internal static class Texts
{
    private static readonly bool Chinese = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh";
    internal static string Choose(string chinese, string english) => Chinese ? chinese : english;
    internal static string Title => Choose("Hades2Together 预览版", "Hades2Together Preview");
    internal static string Space(long bytes) => (bytes / (1024.0 * 1024)).ToString("0.0", CultureInfo.CurrentCulture) + " MiB";
}

internal static class Program
{
    [STAThread]
    internal static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        if (!Environment.Is64BitProcess || Environment.OSVersion.Version.Major < 10)
            return Error(new PlatformNotSupportedException("Windows x64 is required."), gui: true);
        try
        {
#if SETUP
            if (args.Length == 0)
            {
                using var package = Package.Embedded();
                Application.Run(new SetupForm(package));
                return 0;
            }
#else
            if (args.Length == 0)
                args = new[] { "--launch" };
#endif
            if (args.SequenceEqual(new[] { "--launch" }))
            {
#if SETUP
                AttachParentConsole();
#endif
                Install.Exclusive(InstalledApps.LaunchCore);
                return 0;
            }
            AttachParentConsole();
            if (args.SequenceEqual(new[] { "--uninstall" }))
            {
#if SETUP
                Install.Exclusive(InstalledApps.UninstallCore);
                return 0;
#else
                throw new IOException("Use Windows Installed apps to uninstall the installed launcher.");
#endif
            }
#if SETUP
            if (args.Length == 2 && (args[0] == "--check" || args[0] == "--install"))
            {
                using var package = Package.Embedded();
                if (args[0] == "--check")
                {
                    var source = Paths.Full(args[1]);
                    SteamGame.Check(source, SteamGame.Pins);
                    var slot = new GameSlot(source, package.Loader);
                    Console.WriteLine("Compatible Steam build 143476");
                    Console.WriteLine("download_bytes=" + new FileInfo(Assembly.GetExecutingAssembly().Location).Length);
                    Console.WriteLine("profile_payload_bytes=" + package.ProfileBytes);
                    Console.WriteLine("steam_payload_bytes=" + slot.SteamBytes);
                }
                else
                    Install.Exclusive(() => Install.ForUser().Apply(package, args[1], null));
                return 0;
            }
#endif
            Console.Error.WriteLine("Usage: Hades2Together-Setup.exe [--check <game-dir> | --install <game-dir> | --uninstall | --launch]");
            return 2;
        }
        catch (Exception error)
        {
#if SETUP
            return Error(error, gui: args.Length == 0);
#else
            return Error(error, gui: args.Length == 0 || args.SequenceEqual(new[] { "--launch" }));
#endif
        }
    }

    internal static int Error(Exception error, bool gui)
    {
        if (gui)
            MessageBox.Show(error.Message, Texts.Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
        else
            Console.Error.WriteLine(error.Message);
        return 1;
    }

    private static void AttachParentConsole()
    {
        // Preserve handles inherited when a caller redirected a CLI invocation.
        if (GetStdHandle(-11) == IntPtr.Zero && GetStdHandle(-12) == IntPtr.Zero)
            AttachConsole(unchecked((uint)-1));
    }
    [DllImport("kernel32.dll")] private static extern IntPtr GetStdHandle(int kind);
    [DllImport("kernel32.dll")] private static extern bool AttachConsole(uint process);
}

public static class InstalledApps
{
    public static void LaunchCore()
    {
#if BOOTSTRAP || SETUP
        Dispatch(nameof(LaunchCore), Install.ForUser().ReadActiveLauncher());
#else
        Install.ForUser().Launch();
#endif
    }

    public static void UninstallCore()
    {
#if BOOTSTRAP || SETUP
        var active = Install.ForUser().ReadActiveLauncher(allowUninstallRecovery: true);
        if (active != null)
        {
            Dispatch(nameof(UninstallCore), active);
            return;
        }
#endif
        Install.ForUser().Uninstall();
    }

    private static void Dispatch(string method, byte[] launcher)
    {
        var installedApps = Assembly.Load(launcher).GetType(typeof(InstalledApps).FullName, throwOnError: true);
        try { installedApps.GetMethod(method).Invoke(null, null); }
        catch (TargetInvocationException error) when (error.InnerException != null)
        {
            ExceptionDispatchInfo.Capture(error.InnerException).Throw();
        }
    }

    public static int Uninstall()
    {
        try
        {
            Install.Exclusive(UninstallCore);
            MessageBox.Show(Texts.Choose("已卸载预览版。", "The preview was uninstalled."), Texts.Title);
            return 0;
        }
        catch (Exception error) { return Program.Error(error, gui: true); }
    }
}

#if SETUP
internal sealed class SetupForm : Form
{
    private readonly Package package;
    private readonly ComboBox folders = new ComboBox { Dock = DockStyle.Fill, DropDownStyle = ComboBoxStyle.DropDown };
    private readonly Button browse = new Button { AutoSize = true };
    private readonly Button apply = new Button { AutoSize = true };
    private readonly LinkLabel notices = new LinkLabel { AutoSize = true, Anchor = AnchorStyles.Left };
    private readonly Label status = new Label { AutoSize = true, MaximumSize = new Size(560, 0) };
    private readonly ProgressBar progress = new ProgressBar { Style = ProgressBarStyle.Marquee, Visible = false, Dock = DockStyle.Fill };
    private bool busy;

    internal SetupForm(Package package)
    {
        this.package = package;
        Text = Texts.Title;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(610, 250);
        MinimumSize = new Size(550, 270);
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = SystemFonts.MessageBoxFont;
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(18), ColumnCount = 2, RowCount = 6 };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        for (var row = 0; row < 6; row++) layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        var details = new Label
        {
            Text = Texts.Choose(
                "需要兼容的 Steam 版《哈迪斯 II》v1.143476。预览版使用现有游戏和独立模组配置，已禁用存档。首次安装至多需要 ",
                "Requires Hades II Steam v1.143476. The preview uses your existing game and a separate mod profile with saves disabled. A fresh install needs up to ") +
                Texts.Space(package.ProfileBytes + package.Loader.Size + 1024L * 1024) + Texts.Choose(" 可用空间。", " free space."),
            MaximumSize = new Size(550, 0), AutoSize = true, Margin = new Padding(3, 3, 3, 12)
        };
        var label = new Label { Text = Texts.Choose("Steam 游戏目录", "Steam game folder"), AutoSize = true };
        browse.Text = Texts.Choose("浏览…", "Browse…");
        apply.Text = Texts.Choose("安装或更新", "Install or update");
        notices.Text = Texts.Choose("开源许可", "Open-source notices");
        notices.LinkClicked += (_, _) =>
        {
            using var dialog = new Form
            {
                Text = notices.Text,
                StartPosition = FormStartPosition.CenterParent,
                ClientSize = new Size(650, 460)
            };
            dialog.Controls.Add(new TextBox
            {
                Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill,
                Text = package.Notice().Replace("\r\n", "\n").Replace("\n", "\r\n")
            });
            dialog.ShowDialog(this);
        };
        browse.Click += (_, _) =>
        {
            using var picker = new FolderBrowserDialog
            {
                Description = Texts.Choose("选择包含 Ship 和 Content 的 Hades II 文件夹", "Select the Hades II folder containing Ship and Content"),
                ShowNewFolderButton = false
            };
            if (picker.ShowDialog(this) == DialogResult.OK)
                folders.Text = picker.SelectedPath;
        };
        apply.Click += async (_, _) => await Apply();
        Shown += async (_, _) => await Discover();
        FormClosing += (_, e) => e.Cancel = busy;
        layout.Controls.Add(details, 0, 0);
        layout.SetColumnSpan(details, 2);
        layout.Controls.Add(label, 0, 1);
        layout.Controls.Add(folders, 0, 2);
        layout.Controls.Add(browse, 1, 2);
        layout.Controls.Add(progress, 0, 3);
        layout.SetColumnSpan(progress, 2);
        layout.Controls.Add(status, 0, 4);
        layout.SetColumnSpan(status, 2);
        layout.Controls.Add(notices, 0, 5);
        layout.Controls.Add(apply, 1, 5);
        Controls.Add(layout);
        AcceptButton = apply;
    }

    private async Task Discover()
    {
        SetBusy(true);
        status.Text = Texts.Choose("正在查找 Steam 安装…", "Looking for Steam installations…");
        try
        {
            var matches = await Task.Run(() => SteamLibraries.Find().Distinct(StringComparer.OrdinalIgnoreCase)
                .Where(path => SteamGame.Pins.All(file => SteamGame.Matches(path, file, strict: false))).ToArray());
            folders.Items.AddRange(matches);
            if (matches.Length > 0)
                folders.SelectedIndex = 0;
            status.Text = matches.Length > 0 ? "" :
                Texts.Choose("未自动找到兼容版本。可以手动选择游戏目录。", "No compatible Steam installation was detected. You can browse for the game folder.");
        }
        catch (Exception)
        {
            status.Text = Texts.Choose("请手动选择游戏目录。", "Browse for the game folder to continue.");
        }
        finally { SetBusy(false); }
    }

    private async Task Apply()
    {
        var path = folders.Text.Trim().Trim('"');
        if (path.Length == 0)
        {
            status.Text = Texts.Choose("请先选择游戏目录。", "Select the game folder first.");
            return;
        }
        SetBusy(true);
        status.Text = Texts.Choose("正在检查 Steam 版本并安装模组…", "Checking the Steam build and installing the mod…");
        try
        {
            await Task.Run(() => Install.Exclusive(() => Install.ForUser().Apply(package, path, null)));
            status.Text = Texts.Choose("已完成。请从开始菜单打开 Hades2Together Preview。", "Done. Open Hades2Together Preview from the Start menu.");
        }
        catch (Exception error)
        {
            status.Text = Texts.Choose("安装失败。", "Setup could not finish.");
            Program.Error(error, gui: true);
        }
        finally { SetBusy(false); }
    }

    private void SetBusy(bool value)
    {
        busy = value;
        progress.Visible = value;
        apply.Enabled = browse.Enabled = folders.Enabled = notices.Enabled = !value;
    }
}
#endif
