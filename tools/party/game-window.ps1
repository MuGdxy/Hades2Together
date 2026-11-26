# WGC needs the stock game window. The loader console can share its PID.
if (-not ('PartyGameWindow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class PartyGameWindow {
    private delegate bool Enumerate(IntPtr hwnd, IntPtr unused);
    [DllImport("user32.dll")] private static extern bool EnumWindows(Enumerate callback, IntPtr unused);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder title, int length);
    public static long Find(uint pid) {
        long match = 0;
        int count = 0;
        EnumWindows(delegate(IntPtr hwnd, IntPtr unused) {
            uint owner;
            if (GetWindowThreadProcessId(hwnd, out owner) != 0 && owner == pid) {
                var title = new StringBuilder(256);
                if (GetWindowText(hwnd, title, title.Capacity) > 0 && title.ToString() == "Hades II") {
                    count++;
                    match = hwnd.ToInt64();
                }
            }
            return true;
        }, IntPtr.Zero);
        return count == 1 ? match : 0;
    }
}
'@
}
