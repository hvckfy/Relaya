using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya.Platform;

/// Синхронизация на Windows: те же профили и тот же код ядра (git_sync / folder_sync), что на Mac.
/// Профили — %APPDATA%\Relaya\sync-profiles.json, пароль шифрования ключей — Credential Manager.
internal sealed class SyncService
{
    public static SyncService Shared { get; } = new();

    public enum State { Idle, Syncing, Conflict, Failed }

    private const string PassphraseAccount = "relaya-sync-keys";
    private static readonly string Support =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Relaya");
    private static readonly string Store = Path.Combine(Support, "sync-profiles.json");
    private static readonly SyncPaths Paths = new(
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh"), Support);

    // Таймер автосинхронизации и UI работают в разных потоках: состояния — потокобезопасные,
    // один прогон на профиль (SemaphoreSlim), список профилей меняется под замком, наружу — копия.
    private readonly ConcurrentDictionary<string, (State State, string? Message)> states = new();
    private readonly ConcurrentDictionary<string, List<SyncConflict>> conflicts = new();
    private readonly ConcurrentDictionary<string, SemaphoreSlim> gates = new();
    private readonly object profilesLock = new();
    private readonly List<SyncProfile> profiles = Load();
    private Timer? timer;

    public List<SyncProfile> Profiles { get { lock (profilesLock) return profiles.ToList(); } }

    private SemaphoreSlim Gate(string id) => gates.GetOrAdd(id, _ => new SemaphoreSlim(1, 1));

    /// Состояние профиля изменилось или пришли хосты — UI перерисовывается, список хостов перечитывается.
    public event Action? Changed;
    public event Action? Imported;

    public (State State, string? Message) StateOf(SyncProfile p) => states.GetValueOrDefault(p.id, (State.Idle, null));
    public IReadOnlyList<SyncConflict> ConflictsOf(SyncProfile p) => conflicts.GetValueOrDefault(p.id) ?? new();

    public bool HasPassphrase => CredentialStore.Has(PassphraseAccount);

    public void SetPassphrase(string value)
    {
        if (value.Length == 0) CredentialStore.Delete(PassphraseAccount);
        else CredentialStore.Write(PassphraseAccount, value);
    }

    public SyncProfile Add()
    {
        SyncProfile p;
        lock (profilesLock)
        {
            p = RelayaCoreMethods.SyncNewProfile(profiles.Count == 0 ? L("Все хосты") : L("Профиль %@", profiles.Count + 1));
            profiles.Add(p);
        }
        Save();
        return p;
    }

    public void Update(SyncProfile p)
    {
        lock (profilesLock)
        {
            var i = profiles.FindIndex(x => x.id == p.id);
            if (i < 0) return;
            profiles[i] = p;
        }
        Save();
        ScheduleAuto();
    }

    public void Remove(string id)
    {
        lock (profilesLock) profiles.RemoveAll(p => p.id == id);
        Save();
    }

    /// Автосинхронизация раз в 10 минут, как на Mac.
    public void ScheduleAuto()
    {
        timer?.Dispose();
        if (!Profiles.Any(p => p.enabled && p.auto)) return;
        timer = new Timer(_ => _ = SyncAll(interactive: false), null, TimeSpan.FromSeconds(5), TimeSpan.FromMinutes(10));
    }

    public async Task SyncAll(bool interactive = true)
    {
        foreach (var p in Profiles.Where(p => p.enabled && (interactive || p.auto))) await Sync(p.id);
    }

    public async Task Sync(string id)
    {
        var p = Profiles.FirstOrDefault(x => x.id == id);
        if (p is null || !p.enabled) return;
        if (string.IsNullOrWhiteSpace(p.remote)) { Set(p, State.Failed, p.backend == SyncBackend.Git ? L("Укажите репозиторий.") : L("Укажите папку.")); return; }
        var gate = Gate(id);
        if (!gate.Wait(0)) return; // этот профиль уже синхронизируется
        try { await SyncLocked(p); }
        finally { gate.Release(); }
    }

    private async Task SyncLocked(SyncProfile p)
    {
        Set(p, State.Syncing, null);
        var pass = CredentialStore.Read(PassphraseAccount);
        try
        {
            List<SyncItem> imported;
            if (p.backend == SyncBackend.Git)
            {
                var outcome = await Task.Run(() =>
                    RelayaCoreMethods.GitSync(RepoDir(p), p.remote, Environment.MachineName, p, Paths, pass));
                switch (outcome)
                {
                    case SyncOutcome.Conflict c:
                        conflicts[p.id] = c.conflicts.ToList();
                        Set(p, State.Conflict, L("Конфликт в %@ файл(ах)", c.conflicts.Count));
                        return;
                    case SyncOutcome.Synced s: imported = s.imported; break;
                    default: imported = new(); break;
                }
            }
            else
            {
                imported = await Task.Run(() => RelayaCoreMethods.FolderSync(p, Paths, pass, p.remote));
            }
            Set(p, State.Idle, L("Синхронизировано %@", DateTime.Now.ToString("HH:mm")));
            if (imported.Count > 0) Imported?.Invoke();
        }
        catch (Exception e)
        {
            Set(p, State.Failed, GitHint(e.Message));
        }
    }

    /// Разрешить конфликт целиком: оставить свои файлы или взять с сервера.
    public async Task Resolve(string id, bool keepMine)
    {
        var p = Profiles.FirstOrDefault(x => x.id == id);
        if (p is null || !conflicts.TryGetValue(id, out var list)) return;
        var choices = list.ToDictionary(c => c.path, _ => keepMine);
        var gate = Gate(id);
        if (!gate.Wait(0)) return;
        var resolved = false;
        Set(p, State.Syncing, null);
        try
        {
            var imported = await Task.Run(() =>
                RelayaCoreMethods.GitResolve(RepoDir(p), choices, p, Paths, CredentialStore.Read(PassphraseAccount)));
            conflicts.TryRemove(id, out _);
            Set(p, State.Idle, L("Конфликт разрешён"));
            if (imported.Count > 0) Imported?.Invoke();
            resolved = true;
        }
        catch (Exception e)
        {
            Set(p, State.Failed, GitHint(e.Message));
        }
        finally { gate.Release(); }
        if (resolved) await Sync(id);
    }

    private static string GitHint(string message) =>
        message.Contains("git:") && (message.Contains("program not found", StringComparison.OrdinalIgnoreCase)
            || message.Contains("cannot find the file", StringComparison.OrdinalIgnoreCase))
            ? Strings.L("Не найден git. Установите Git for Windows (git-scm.com) и перезапустите Relaya.")
            : SshErrors.Describe(message);

    private static string RepoDir(SyncProfile p) => Path.Combine(Support, "sync", p.id);

    private void Set(SyncProfile p, State state, string? message)
    {
        states[p.id] = (state, message);
        Changed?.Invoke();
    }

    // --- Хранение профилей ---

    private sealed record Dto(string Id, string Name, int Backend, string Remote, bool AllHosts, List<string> Groups,
        List<string> Hosts, List<int> Items, bool Auto, bool Enabled);

    private static List<SyncProfile> Load()
    {
        try
        {
            if (!File.Exists(Store)) return new();
            return (JsonSerializer.Deserialize<List<Dto>>(File.ReadAllText(Store)) ?? new())
                .Select(d => new SyncProfile(d.Id, d.Name, (SyncBackend)d.Backend, d.Remote,
                    new SyncScope(d.AllHosts, d.Groups, d.Hosts), d.Items.Select(i => (SyncItem)i).ToList(), d.Auto, d.Enabled))
                .ToList();
        }
        catch (Exception) { return new(); }
    }

    private void Save()
    {
        Directory.CreateDirectory(Support);
        var dtos = Profiles.Select(p => new Dto(p.id, p.name, (int)p.backend, p.remote, p.scope.allHosts,
            p.scope.groups, p.scope.hosts, p.items.Select(i => (int)i).ToList(), p.auto, p.enabled));
        File.WriteAllText(Store, JsonSerializer.Serialize(dtos, new JsonSerializerOptions { WriteIndented = true }));
    }
}
