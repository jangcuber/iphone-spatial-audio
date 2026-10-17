// Prints the Windows volume of one playback device whenever it changes:
//   "<scalar 0..1> <level dB> <muted 0|1>"
// VB-CABLE ignores its own volume slider, so snaphost applies this value itself.
using System;
using System.Runtime.InteropServices;
using System.Threading;

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCom {}
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator { int EnumAudioEndpoints(int flow, int mask, out IMMDeviceCollection c); }
[Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceCollection { int GetCount(out int c); int Item(int i, out IMMDevice d); }
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
  int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
  int OpenPropertyStore(int access, out IPropertyStore s);
}
[Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPropertyStore { int GetCount(out int c); int GetAt(int i, out PK k); int GetValue(ref PK k, out PV v); }
[StructLayout(LayoutKind.Sequential)] struct PK { public Guid fmtid; public int pid; }
[StructLayout(LayoutKind.Sequential)] struct PV { public short vt; short a, b, c; public IntPtr p; IntPtr p2; }
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioEndpointVolume {
  int RegisterControlChangeNotify(IntPtr n); int UnregisterControlChangeNotify(IntPtr n);
  int GetChannelCount(out int c);
  int SetMasterVolumeLevel(float db, ref Guid ctx); int SetMasterVolumeLevelScalar(float s, ref Guid ctx);
  int GetMasterVolumeLevel(out float db); int GetMasterVolumeLevelScalar(out float s);
  int SetChannelVolumeLevel(int ch, float db, ref Guid ctx); int SetChannelVolumeLevelScalar(int ch, float s, ref Guid ctx);
  int GetChannelVolumeLevel(int ch, out float db); int GetChannelVolumeLevelScalar(int ch, out float s);
  int SetMute(bool m, ref Guid ctx); int GetMute(out bool m);
}

static class VolWatch {
  static string Name(IMMDevice d) {
    IPropertyStore s; d.OpenPropertyStore(0, out s);
    var k = new PK { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 14 };
    PV v; s.GetValue(ref k, out v); return Marshal.PtrToStringUni(v.p);
  }
  static void Main(string[] args) {
    string want = args.Length > 0 ? args[0] : "CABLE Input";
    IMMDeviceCollection c; ((IMMDeviceEnumerator)new MMDeviceEnumeratorCom()).EnumAudioEndpoints(0, 1, out c);
    int n; c.GetCount(out n); IAudioEndpointVolume vol = null;
    for (int i = 0; i < n && vol == null; i++) {
      IMMDevice d; c.Item(i, out d);
      if (Name(d).StartsWith(want)) { Guid iid = typeof(IAudioEndpointVolume).GUID; object o; d.Activate(ref iid, 23, IntPtr.Zero, out o); vol = (IAudioEndpointVolume)o; }
    }
    if (vol == null) { Console.Error.WriteLine("device not found: " + want); Environment.Exit(1); }
    string last = "";
    while (true) {
      float s, db; bool m;
      vol.GetMasterVolumeLevelScalar(out s); vol.GetMasterVolumeLevel(out db); vol.GetMute(out m);
      string line = string.Format(System.Globalization.CultureInfo.InvariantCulture, "{0:F4} {1:F2} {2}", s, db, m ? 1 : 0);
      if (line != last) { Console.WriteLine(line); Console.Out.Flush(); last = line; }
      Thread.Sleep(30);
    }
  }
}
