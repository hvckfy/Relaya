using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Relaya.Data;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya.Pages;

/// «Настроить вход по ключу» (как KeyWizardView на Mac): ключ → предпросмотр → применение → готово.
/// Применение: ключ (новый ed25519) → на сервер в authorized_keys → ssh-agent (если есть passphrase) →
/// проверочный вход только ключом → и лишь потом IdentityFile + IdentitiesOnly в ~/.ssh/config.
/// При ошибке созданные файлы ключа удаляются, config не меняется. Команды и скрипт — из ядра.
internal sealed class KeyWizardPage : UserControl
{
    private readonly SshHost host;
    private enum Step { Key, Preview, Apply, Done }
    private Step step = Step.Key;

    // Выбор на шаге «Ключ».
    private bool createNew = true;
    private string newName = "id_ed25519";
    private string passphrase = "", existingKey = "", existingPassphrase = "", serverPassword = "";
    private bool saveServerPassword = true;

    private readonly Dictionary<string, string> statuses = new();
    private string? error, rollback;

    public KeyWizardPage(SshHost host)
    {
        this.host = host;
        if (ExistingKeys().FirstOrDefault() is { } first) existingKey = first;
        newName = UniqueName("id_ed25519_" + host.alias.Replace('.', '_'));
        Build();
    }

    private static string KeyPath(string name) => Path.Combine(AppState.SshDir, name);
    private string KeyFile => createNew ? KeyPath(newName) : KeyPath(existingKey);

    private static List<string> ExistingKeys() => Directory.Exists(AppState.SshDir)
        ? Directory.GetFiles(AppState.SshDir, "*.pub").Select(p => Path.GetFileNameWithoutExtension(p)).OrderBy(n => n).ToList()
        : new();

    private static string UniqueName(string name)
    {
        var n = name;
        for (var i = 2; File.Exists(KeyPath(n)) || File.Exists(KeyPath(n) + ".pub"); i++) n = name + "_" + i;
        return n;
    }

    private void Build()
    {
        var (page, body) = Ui.Scaffold(L("Вход по ключу: %@", host.alias), Buttons());
        Content = page;
        var bar = new BreadcrumbBar
        {
            ItemsSource = new[] { L("Ключ"), L("Предпросмотр"), L("Применение"), L("Готово") }.Take((int)step + 1).ToList(),
            Margin = new Thickness(0, 0, 0, 12),
        };
        body.Children.Add(bar);
        var form = new StackPanel { Spacing = 12, MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Left };
        body.Children.Add(form);
        switch (step)
        {
            case Step.Key: KeyStep(form); break;
            case Step.Preview: PreviewStep(form); break;
            default: ApplyStep(form); break;
        }
    }

    private UIElement[] Buttons() => step switch
    {
        Step.Key => new UIElement[] { Ui.Button(L("Отмена"), Close), Ui.Button(L("Далее"), () => { step = Step.Preview; Build(); }, accent: true) },
        Step.Preview => new UIElement[]
        {
            Ui.Button(L("Назад"), () => { step = Step.Key; Build(); }),
            Ui.Button(L("Применить"), () => _ = ApplyAsync(), accent: true),
        },
        Step.Apply => Array.Empty<UIElement>(),
        _ => new UIElement[] { Ui.Button(L("Готово"), Close, accent: true) },
    };

    private void Close()
    {
        if (AppState.Host(host.alias) is { } h) MainWindow.Current?.ShowPage(new HostPage(h));
        else MainWindow.Current?.ShowNothing();
    }

    // --- Шаг 1: ключ ---

    private void KeyStep(StackPanel form)
    {
        var mode = new RadioButtons { Header = L("Ключ"), Items = { L("Создать новый ключ ed25519"), L("Взять существующий") }, SelectedIndex = createNew ? 0 : 1 };
        var name = new TextBox { Header = L("Имя файла в ~/.ssh"), Text = newName };
        var pass = new PasswordBox { Header = L("Passphrase ключа (необязательно)"), Password = passphrase };
        var existing = new ComboBox { Header = L("Ключ из ~/.ssh"), ItemsSource = ExistingKeys(), SelectedItem = existingKey, HorizontalAlignment = HorizontalAlignment.Stretch };
        var existingPass = new PasswordBox { Header = L("Passphrase ключа, если есть"), Password = existingPassphrase };
        var serverPass = new PasswordBox
        {
            Header = L("Пароль сервера"),
            Password = serverPassword,
            PlaceholderText = Platform.CredentialStore.Has(host.alias) ? L("Сохранён — будет использован") : L("Нужен, если на сервер ещё нельзя войти ключом"),
        };
        var save = new CheckBox { Content = L("Сохранить пароль сервера"), IsChecked = saveServerPassword };
        void Sync()
        {
            createNew = mode.SelectedIndex == 0;
            name.Visibility = pass.Visibility = createNew ? Visibility.Visible : Visibility.Collapsed;
            existing.Visibility = existingPass.Visibility = createNew ? Visibility.Collapsed : Visibility.Visible;
        }
        mode.SelectionChanged += (_, _) => Sync();
        name.TextChanged += (_, _) => newName = name.Text.Trim();
        pass.PasswordChanged += (_, _) => passphrase = pass.Password;
        existing.SelectionChanged += (_, _) => existingKey = existing.SelectedItem as string ?? "";
        existingPass.PasswordChanged += (_, _) => existingPassphrase = existingPass.Password;
        serverPass.PasswordChanged += (_, _) => serverPassword = serverPass.Password;
        save.Checked += (_, _) => saveServerPassword = true;
        save.Unchecked += (_, _) => saveServerPassword = false;
        Sync();
        foreach (var c in new UIElement[] { mode, name, pass, existing, existingPass, serverPass, save }) form.Children.Add(c);
    }

    // --- Шаг 2: предпросмотр ---

    private void PreviewStep(StackPanel form)
    {
        form.Children.Add(Ui.Secondary(L("Что будет сделано:")));
        var lines = new List<string>();
        if (createNew) lines.Add(L("создать ключ %@ (ed25519)", "~/.ssh/" + newName));
        lines.Add(L("дописать открытый ключ в ~/.ssh/authorized_keys на %@", host.alias));
        if ((createNew ? passphrase : existingPassphrase).Length > 0) lines.Add(L("добавить ключ в ssh-agent"));
        lines.Add(L("проверить вход только этим ключом"));
        lines.Add(L("после успешной проверки — IdentityFile и IdentitiesOnly yes в ~/.ssh/config (копия config.relaya.bak)"));
        foreach (var l in lines) form.Children.Add(new TextBlock { Text = "• " + l, TextWrapping = TextWrapping.Wrap });
        var keyPath = "~/.ssh/" + (createNew ? newName : existingKey);
        var preview = RelayaCoreMethods.ConfigRenderedLines(RelayaCoreMethods.ConfigBindKey(AppState.ConfigText(), keyPath, new List<string> { host.alias }), host, host.alias);
        form.Children.Add(Ui.Section(L("Будет записано в ~/.ssh/config")));
        form.Children.Add(Ui.Card(new TextBlock
        {
            Text = string.Join("\n", preview),
            IsTextSelectionEnabled = true,
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas"),
        }));
    }

    // --- Шаг 3–4: применение и итог ---

    private static readonly string[] Steps = { "Ключ", "Сервер", "Агент", "Проверка", "Config" };

    private void ApplyStep(StackPanel form)
    {
        foreach (var name in Steps)
        {
            var state = statuses.GetValueOrDefault(name, "pending");
            var glyph = state switch { "ok" => "", "failed" => "", "skipped" => "", "running" => "", _ => "" };
            form.Children.Add(Ui.Row(glyph, L(StepTitle(name)), state == "running" ? L("выполняется…") : null));
        }
        if (error != null)
            form.Children.Add(new InfoBar
            {
                Severity = InfoBarSeverity.Error,
                IsOpen = true,
                IsClosable = false,
                Title = L("Не получилось"),
                Message = error + (rollback != null ? "\n" + L("Откатили: %@.", rollback) : ""),
            });
        else if (step == Step.Done)
            form.Children.Add(new InfoBar
            {
                Severity = InfoBarSeverity.Success,
                IsOpen = true,
                IsClosable = false,
                Title = L("Готово"),
                Message = L("%@ теперь входит по ключу %@.", host.alias, "~/.ssh/" + Path.GetFileName(KeyFile)),
            });
    }

    private static string StepTitle(string name) => name switch
    {
        "Ключ" => "Ключ создан",
        "Сервер" => "Ключ добавлен на сервер",
        "Агент" => "Ключ в ssh-agent",
        "Проверка" => "Проверочный вход по ключу",
        _ => "IdentityFile в ~/.ssh/config",
    };

    private void Set(string name, string state) { statuses[name] = state; Build(); }

    private async Task ApplyAsync()
    {
        step = Step.Apply;
        error = rollback = null;
        statuses.Clear();
        Build();
        var keyFile = KeyFile;
        var createdKey = false;
        var tempPassword = false;
        string? current = null;
        try
        {
            // 1. Ключ
            current = "Ключ";
            if (createNew)
            {
                Set(current, "running");
                if (File.Exists(keyFile) || File.Exists(keyFile + ".pub")) throw new InvalidOperationException(L("Файл %@ уже существует", keyFile));
                Directory.CreateDirectory(AppState.SshDir);
                var (ok, err) = await Platform.KeyGen.CreateAsync(keyFile, $"{Environment.UserName}@{Environment.MachineName}", passphrase);
                if (!ok) throw new InvalidOperationException("ssh-keygen: " + err);
                createdKey = true;
                Set(current, "ok");
            }
            else Set(current, "skipped");
            var pub = File.ReadAllText(keyFile + ".pub").Trim();

            // 2. Сервер: пароль — через askpass из хранилища (временная запись удаляется в конце).
            current = "Сервер";
            Set(current, "running");
            var hasPassword = Platform.CredentialStore.Has(host.alias);
            if (!hasPassword && serverPassword.Length > 0)
            {
                Platform.CredentialStore.Write(host.alias, serverPassword);
                tempPassword = !saveServerPassword;
                hasPassword = true;
            }
            var install = await AppState.Run(AppState.SshExe,
                RelayaCoreMethods.KeyInstallSshArgs(host.alias, hasPassword), // алиас и удалённый скрипт уже в аргументах
                hasPassword ? host.alias : null, pub + "\n", 60);
            if (install.Status != 0) throw new InvalidOperationException(Platform.SshErrors.Describe(install.Stderr, L("ssh завершился с кодом %@", install.Status)));
            Set(current, "ok");

            // 3. Агент (если есть passphrase). На Windows служба ssh-agent часто выключена — тогда шаг пропускаем.
            current = "Агент";
            if ((createNew ? passphrase : existingPassphrase).Length > 0)
            {
                Set(current, "running");
                var added = await Platform.KeyGen.AddToAgentAsync(keyFile, createNew ? passphrase : existingPassphrase);
                Set(current, added ? "ok" : "skipped");
            }
            else Set(current, "skipped");

            // 4. Проверочный вход только ключом.
            current = "Проверка";
            Set(current, "running");
            var verify = await AppState.Run(AppState.SshExe, RelayaCoreMethods.KeyVerifySshArgs(host.alias, keyFile), null, null, 30);
            if (verify.Status != 0)
            {
                var hint = RelayaCoreMethods.KeyVerifyHint(verify.Stderr);
                throw new InvalidOperationException(L("Проверочный вход по ключу не прошёл: %@", Platform.SshErrors.Describe(verify.Stderr, verify.Status.ToString()))
                    + (hint != null ? L(hint) : "")); // ключ подсказки начинается с «. »
            }
            Set(current, "ok");

            // 5. Config — только после успешной проверки.
            current = "Config";
            Set(current, "running");
            AppState.WriteConfig(RelayaCoreMethods.ConfigBindKey(AppState.ConfigText(), "~/.ssh/" + Path.GetFileName(keyFile), new List<string> { host.alias }));
            Set(current, "ok");
            step = Step.Done;
        }
        catch (Exception e)
        {
            if (current != null) statuses[current] = "failed";
            error = e.Message;
            var undone = new List<string>();
            if (createdKey)
            {
                try { File.Delete(keyFile); File.Delete(keyFile + ".pub"); } catch (IOException) { }
                undone.Add(L("удалены созданные файлы %@*", Path.GetFileName(keyFile)));
            }
            undone.Add(statuses.GetValueOrDefault("Сервер") == "ok"
                ? L("ключ на сервере остался в authorized_keys — удалите строку вручную, если она не нужна")
                : L("на сервере ничего не изменено"));
            undone.Add(L("~/.ssh/config не менялся"));
            rollback = string.Join("; ", undone);
            step = Step.Done;
        }
        finally
        {
            if (tempPassword) Platform.CredentialStore.Delete(host.alias);
            Build();
        }
    }
}
