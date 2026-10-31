using System;
using System.Diagnostics;
using System.IO;
using uniffi.relaya_core;
using Relaya.Platform;

namespace Relaya.Desktop;

/// Звук удалённого стола на Linux: PCM 16 бит от ядра (поток сессии) → stdin `pacat` (PulseAudio и PipeWire-pulse).
/// Формат — по первому пакету. Громкость — наша (ползунок) × присланная сервером, умножаем сами сэмплы.
/// Нет pacat — звука нет, сессия работает.
internal sealed class RdpAudio : RemoteAudioListener, IDisposable
{
    private readonly object gate = new();
    private Process? player;
    private Stream? input;
    private AudioFormat? format;
    private float server = 1f;
    private int percent;

    public RdpAudio(string volume) => percent = int.TryParse(volume, out var v) ? Math.Clamp(v, 0, 100) : 100;

    public int VolumePercent
    {
        get => percent;
        set => percent = Math.Clamp(value, 0, 100);
    }

    public void OnAudio(AudioFormat f, uint timestamp, byte[] pcm)
    {
        lock (gate)
        {
            if (format is not { } cur || cur.sampleRate != f.sampleRate || cur.channels != f.channels || cur.bitsPerSample != f.bitsPerSample)
            {
                Stop();
                if (f.bitsPerSample != 16 || Dialogs.Which("pacat") is not { } pacat) return;
                try
                {
                    var info = new ProcessStartInfo(pacat) { UseShellExecute = false, RedirectStandardInput = true };
                    foreach (var a in new[] { "--playback", "--raw", "--format=s16le", $"--rate={f.sampleRate}", $"--channels={f.channels}",
                                 "--latency-msec=80", "--client-name=Relaya", "--stream-name=Remote desktop" })
                        info.ArgumentList.Add(a);
                    player = Process.Start(info);
                    input = player?.StandardInput.BaseStream;
                    format = f;
                }
                catch (Exception e)
                {
                    Terminal.TerminalView.Trace("RDP audio: " + e.Message);
                    Stop();
                    return;
                }
            }
            if (input == null) return;
            var gain = Math.Clamp(percent / 100f * server, 0f, 1f);
            if (gain < 0.999f) Scale(pcm, gain);
            try { input.Write(pcm); input.Flush(); }
            catch (Exception) { Stop(); }
        }
    }

    // s16le: каждый сэмпл × gain.
    private static void Scale(byte[] pcm, float gain)
    {
        for (var i = 0; i + 1 < pcm.Length; i += 2)
        {
            var v = (short)(pcm[i] | pcm[i + 1] << 8);
            var s = (short)(v * gain);
            pcm[i] = (byte)s;
            pcm[i + 1] = (byte)(s >> 8);
        }
    }

    public void OnAudioVolume(ushort left, ushort right) => server = Math.Max(left, right) / 65535f;

    public void OnAudioClosed()
    {
        lock (gate) Stop();
    }

    private void Stop()
    {
        try { input?.Dispose(); } catch (Exception) { }
        try { if (player is { HasExited: false }) player.Kill(); player?.Dispose(); } catch (Exception) { }
        input = null;
        player = null;
        format = null;
    }

    public void Dispose()
    {
        lock (gate) Stop();
    }
}
