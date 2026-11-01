using System;
using System.Diagnostics;
using System.IO;
using uniffi.relaya_core;
using Relaya.Platform;

namespace Relaya.Desktop;

/// Звук удалённого стола на Linux: PCM 16 бит от ядра (поток сессии) → stdin `pacat` (PulseAudio и PipeWire-pulse).
/// Формат — по первому пакету. Громкость — наша (ползунок) × присланная сервером, умножаем сами сэмплы.
/// Нет pacat — звука нет, сессия работает. Запись в pacat — из своего потока через очередь на ~1 с: поток сессии ядра,
/// который приносит и кадры, на звуке не ждёт; не успевает pacat — старые куски отбрасываются (как DiscardOnBufferOverflow).
internal sealed class RdpAudio : RemoteAudioListener, IDisposable
{
    private readonly object gate = new();
    private Process? player;
    private Stream? input;
    private AudioFormat? format;
    private float server = 1f;
    private int percent;
    private System.Collections.Concurrent.BlockingCollection<byte[]>? queue;
    private const int QueueChunks = 50; // ≈ 1 с при кусках по 20 мс

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
                    if (input is { } stream)
                    {
                        var created = new System.Collections.Concurrent.BlockingCollection<byte[]>(QueueChunks);
                        queue = created;
                        new System.Threading.Thread(() => Writer(created, stream)) { IsBackground = true, Name = "RDP audio" }.Start();
                    }
                }
                catch (Exception e)
                {
                    Terminal.TerminalView.Trace("RDP audio: " + e.Message);
                    Stop();
                    return;
                }
            }
            if (queue is not { } q) return;
            var gain = Math.Clamp(percent / 100f * server, 0f, 1f);
            if (gain < 0.999f) Scale(pcm, gain);
            // Очередь полна — выкидываем самый старый кусок, чтобы звук не отставал.
            while (!q.TryAdd(pcm)) q.TryTake(out _);
        }
    }

    private static void Writer(System.Collections.Concurrent.BlockingCollection<byte[]> q, Stream stream)
    {
        try
        {
            foreach (var chunk in q.GetConsumingEnumerable()) { stream.Write(chunk); stream.Flush(); }
        }
        catch (Exception e) { Terminal.TerminalView.Trace("RDP audio: " + e.Message); }
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
        queue?.CompleteAdding();
        queue = null;
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
