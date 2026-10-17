param([string]$Play = "CABLE Input")
# Sets VB-CABLE to 7.1 / 48 kHz / 16-bit on both sides (playback "CABLE Input", recording "CABLE Output").
# Same as Sound control panel > Configure 7.1 + Advanced format, done through the panel's own API.
$ErrorActionPreference = "Stop"
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCom2 {}
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator2 {
  int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection2 devices);
}
[Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceCollection2 { int GetCount(out int c); int Item(int i, out IMMDevice2 d); }
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice2 {
  int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
  int OpenPropertyStore(int access, out IPropertyStore2 store);
  int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
}
[Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPropertyStore2 { int GetCount(out int c); int GetAt(int i, out PK k); int GetValue(ref PK k, out PV v); }
[StructLayout(LayoutKind.Sequential)] public struct PK { public Guid fmtid; public int pid; }
[StructLayout(LayoutKind.Sequential)] public struct PV { public short vt; short r1, r2, r3; public IntPtr p; IntPtr p2; }

[Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPolicyConfig2 {
  int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string id, out IntPtr fmt);
  int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id, int def, out IntPtr fmt);
  int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id);
  int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string id, IntPtr endpointFmt, IntPtr mixFmt);
  int GetProcessingPeriod(); int SetProcessingPeriod(); int GetShareMode(); int SetShareMode();
  int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string id, int fxStore, ref PK key, out PV v);
  int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string id, int fxStore, ref PK key, ref PV v);
}
[ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")] class PolicyConfigClient2 {}

public static class Cable71 {
  static string Name(IMMDevice2 d) {
    IPropertyStore2 s; d.OpenPropertyStore(0, out s);
    var k = new PK { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 14 };
    PV v; s.GetValue(ref k, out v); return Marshal.PtrToStringUni(v.p);
  }
  public static string Find(int flow, string name) {
    IMMDeviceCollection2 c; ((IMMDeviceEnumerator2)new MMDeviceEnumeratorCom2()).EnumAudioEndpoints(flow, 1, out c);
    int n; c.GetCount(out n);
    for (int i = 0; i < n; i++) { IMMDevice2 d; c.Item(i, out d); if (Name(d).StartsWith(name)) { string id; d.GetId(out id); return id; } }
    return null;
  }
  public static void Set71(string id, bool speakers) {
    // WAVEFORMATEXTENSIBLE: PCM 16-bit, 8 ch, 48 kHz, mask 0x63F (FL FR FC LFE BL BR SL SR)
    byte[] w = new byte[40];
    BitConverter.GetBytes((ushort)0xFFFE).CopyTo(w, 0);
    BitConverter.GetBytes((ushort)8).CopyTo(w, 2);
    BitConverter.GetBytes(48000).CopyTo(w, 4);
    BitConverter.GetBytes(48000 * 16).CopyTo(w, 8);
    BitConverter.GetBytes((ushort)16).CopyTo(w, 12);
    BitConverter.GetBytes((ushort)16).CopyTo(w, 14);
    BitConverter.GetBytes((ushort)22).CopyTo(w, 16);
    BitConverter.GetBytes((ushort)16).CopyTo(w, 18);
    BitConverter.GetBytes(0x63F).CopyTo(w, 20);
    new Guid("00000001-0000-0010-8000-00aa00389b71").ToByteArray().CopyTo(w, 24);
    IntPtr p = Marshal.AllocCoTaskMem(40); Marshal.Copy(w, 0, p, 40);
    var pc = (IPolicyConfig2)new PolicyConfigClient2();
    if (speakers) {
      var k = new PK { fmtid = new Guid("1da5d803-d492-4edd-8c23-e0c0ffee7f0e"), pid = 3 };   // PhysicalSpeakers
      var v = new PV { vt = 19 }; v.p = (IntPtr)0x63F;
      Marshal.ThrowExceptionForHR(pc.SetPropertyValue(id, 0, ref k, ref v));
    }
    Marshal.ThrowExceptionForHR(pc.SetDeviceFormat(id, p, p));
    Marshal.FreeCoTaskMem(p);
  }
}
"@
$play = [Cable71]::Find(0, $Play)
$rec = [Cable71]::Find(1, "CABLE Output")
if (-not $play -or -not $rec) { throw "VB-CABLE not found" }
[Cable71]::Set71($play, $true);  "$Play -> 7.1, 48 kHz"
[Cable71]::Set71($rec, $false);  "CABLE Output -> 8 ch, 48 kHz"
