# Samples the default render device's peak meter with CoreAudio and publishes it to
# audio-activity.json. The daemon uses it to stay asleep whenever the PC is playing
# any audio (video, music, calls), which would otherwise leak into the microphone.
$ErrorActionPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path $here 'audio-activity.json'
$pidFile = Join-Path $here 'audio-activity.pid'
try { [System.IO.File]::WriteAllText($pidFile, [string]$PID) } catch {}

$cs = @'
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
internal class MMDeviceEnumeratorComObject { }

[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDeviceEnumerator {
    // vtable order must match the real interface or the call lands in the wrong slot
    int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr ppDevices);
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppDevice);
    int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice ppDevice);
}

[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDevice {
    int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, out IAudioMeterInformation ppInterface);
    int OpenPropertyStore(int stgmAccess, out IntPtr ppProperties);
    int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
    int GetState(out int pdwState);
}

[Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioMeterInformation {
    int GetPeakValue(out float pfPeak);
}

public class AudioPeak {
    static IMMDeviceEnumerator enumerator;
    static IMMDevice device;
    static IAudioMeterInformation meter;

    public static float Read() {
        try {
            if (meter == null) {
                enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
                IMMDevice dev;
                // eRender = 0, eMultimedia = 1
                enumerator.GetDefaultAudioEndpoint(0, 1, out dev);
                device = dev;
                Guid iid = typeof(IAudioMeterInformation).GUID;
                IAudioMeterInformation m;
                device.Activate(ref iid, 1 /* CLSCTX_INPROC_SERVER */, IntPtr.Zero, out m);
                meter = m;
            }
            float peak;
            meter.GetPeakValue(out peak);
            return peak;
        } catch {
            meter = null; device = null; enumerator = null;
            return -1f;
        }
    }
}
'@
Add-Type -TypeDefinition $cs -Language CSharp | Out-Null

$last = 0.0
while ($true) {
  $peak = [AudioPeak]::Read()
  if ($peak -lt 0) { $peak = 0 }
  # small attack/release so one silent sample does not flip the flag
  if ($peak -gt $last) { $last = $peak } else { $last = $last * 0.55 + $peak * 0.45 }
  $json = '{"peak":' + [math]::Round($peak, 4) + ',"level":' + [math]::Round($last, 4) + ',"ts":' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + '}'
  try { [System.IO.File]::WriteAllText($out, $json) } catch {}
  Start-Sleep -Milliseconds 200
}
