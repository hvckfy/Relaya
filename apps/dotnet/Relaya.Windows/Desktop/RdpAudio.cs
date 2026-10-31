using System;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using uniffi.relaya_core;

namespace Relaya.Desktop;

/// Звук удалённого стола: PCM от ядра (поток сессии) → BufferedWaveProvider → WASAPI. Формат — по первому пакету.
/// Итоговая громкость — наша (ползунок) × громкость, которую прислал сервер.
internal sealed class RdpAudio : RemoteAudioListener, IDisposable
{
    private readonly object gate = new();
    private WasapiOut? output;
    private BufferedWaveProvider? buffer;
    private AudioFormat? format;
    private float server = 1f;
    private int percent;
    private DateTime lastRestart = DateTime.MinValue;

    public RdpAudio(string volume) => percent = int.TryParse(volume, out var v) ? Math.Clamp(v, 0, 100) : 100;

    public int VolumePercent
    {
        get => percent;
        set { percent = Math.Clamp(value, 0, 100); Apply(); }
    }

    private void Apply()
    {
        lock (gate)
            if (output != null)
                try { output.Volume = Math.Clamp(percent / 100f * server, 0f, 1f); } catch (Exception) { }
    }

    public void OnAudio(AudioFormat f, uint timestamp, byte[] pcm)
    {
        lock (gate)
        {
            if (format is not { } cur || cur.sampleRate != f.sampleRate || cur.channels != f.channels || cur.bitsPerSample != f.bitsPerSample)
            {
                // Перезапуск WASAPI — не чаще раза в секунду (W-RDP-6): сервер, меняющий формат на лету, не дёргает устройство.
                if (DateTime.UtcNow - lastRestart < TimeSpan.FromSeconds(1)) return;
                lastRestart = DateTime.UtcNow;
                Stop();
                try
                {
                    buffer = new BufferedWaveProvider(new WaveFormat((int)f.sampleRate, f.bitsPerSample, f.channels))
                    {
                        DiscardOnBufferOverflow = true, BufferDuration = TimeSpan.FromSeconds(2),
                    };
                    output = new WasapiOut(AudioClientShareMode.Shared, 80);
                    output.Init(buffer);
                    output.Play();
                    format = f;
                }
                catch (Exception e)
                {
                    Terminal.TerminalView.Trace("RDP audio: " + e.Message);
                    Stop();
                    return;
                }
            }
            buffer!.AddSamples(pcm, 0, pcm.Length);
        }
        Apply();
    }

    public void OnAudioVolume(ushort left, ushort right)
    {
        server = Math.Max(left, right) / 65535f;
        Apply();
    }

    public void OnAudioClosed()
    {
        lock (gate) Stop();
    }

    private void Stop()
    {
        try { output?.Stop(); output?.Dispose(); } catch (Exception) { }
        output = null;
        buffer = null;
        format = null;
    }

    public void Dispose()
    {
        lock (gate) Stop();
    }
}
