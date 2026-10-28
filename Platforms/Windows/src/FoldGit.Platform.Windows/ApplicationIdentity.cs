using System.ComponentModel;
using System.Runtime.InteropServices;

namespace FoldGit.Platform.Windows;

public static class WindowsApplicationIdentity
{
    public static bool IsPackaged
    {
        get
        {
            uint length = 0;
            var result = GetCurrentPackageFullName(ref length, IntPtr.Zero);
            return result switch
            {
                122 => true,
                15700 => false,
                _ => throw new Win32Exception(result)
            };
        }
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetCurrentPackageFullName(ref uint length, IntPtr name);
}
