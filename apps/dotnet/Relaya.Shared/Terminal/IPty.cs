using System;

namespace Relaya.Terminal;

/// Процесс в псевдотерминале: ConPTY на Windows, pty на Linux. Порядок: Spawn → подписки → Start().
internal interface IPty : IDisposable
{
    event Action<byte[]>? Output;
    event Action<int>? Exited;
    /// Сбой подписчика Output: чтение продолжается, ошибку показывают в терминале.
    event Action<Exception>? HandlerFailed;
    void Start();
    void Write(byte[] data);
    void Resize(short cols, short rows);
}
