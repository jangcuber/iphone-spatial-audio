# Lists playback devices and sets the Windows default output (no admin needed).
#   audiodev.ps1 list | get | set "<part of name or id>"
param([string]$Cmd = "list", [string]$Name = "")

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCom {}

[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
  int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
  int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
}
[Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceCollection {
  int GetCount(out int count);
  int Item(int index, out IMMDevice device);
}
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
  int Activate(ref Guid iid, int clsCtx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
  int OpenPropertyStore(int access, out IPropertyStore store);
  int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
}
[Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPropertyStore {
  int GetCount(out int c);
  int GetAt(int i, out PROPERTYKEY k);
  int GetValue(ref PROPERTYKEY k, out PROPVARIANT v);
}
[StructLayout(LayoutKind.Sequential)] struct PROPERTYKEY { public Guid fmtid; public int pid; }
[StructLayout(LayoutKind.Sequential)] struct PROPVARIANT { public short vt; short r1, r2, r3; public IntPtr p; IntPtr p2; }

[Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPolicyConfig {
  int a(); int b(); int c(); int d(); int e(); int f(); int g(); int h(); int i(); int j();
  int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
}
[ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")] class PolicyConfigClient {}

public static class AudioDev {
  static IMMDeviceEnumerator En() { return (IMMDeviceEnumerator)new MMDeviceEnumeratorCom(); }
  static string FriendlyName(IMMDevice d) {
    IPropertyStore s; d.OpenPropertyStore(0, out s);
    var k = new PROPERTYKEY { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 14 };
    PROPVARIANT v; s.GetValue(ref k, out v);
    return Marshal.PtrToStringUni(v.p);
  }
  public static List<string[]> List() {
    var r = new List<string[]>(); IMMDeviceCollection c; En().EnumAudioEndpoints(0, 1, out c);
    int n; c.GetCount(out n);
    for (int i = 0; i < n; i++) { IMMDevice d; c.Item(i, out d); string id; d.GetId(out id); r.Add(new[] { id, FriendlyName(d) }); }
    return r;
  }
  public static string[] Default() {
    IMMDevice d; En().GetDefaultAudioEndpoint(0, 1, out d); string id; d.GetId(out id);
    return new[] { id, FriendlyName(d) };
  }
  public static void SetDefault(string id) {
    var p = (IPolicyConfig)new PolicyConfigClient();
    for (int role = 0; role < 3; role++) Marshal.ThrowExceptionForHR(p.SetDefaultEndpoint(id, role));
  }
}
"@

switch ($Cmd) {
  "list" { [AudioDev]::List() | ForEach-Object { "{0}`t{1}" -f $_[1], $_[0] } }
  "get"  { $d = [AudioDev]::Default(); "{0}`t{1}" -f $d[1], $d[0] }
  "set"  {
    $hit = [AudioDev]::List() | Where-Object { $_[0] -eq $Name -or $_[1] -like "*$Name*" } | Select-Object -First 1
    if (-not $hit) { Write-Error "playback device '$Name' not found"; exit 1 }
    [AudioDev]::SetDefault($hit[0]); "default output -> $($hit[1])"
  }
}
