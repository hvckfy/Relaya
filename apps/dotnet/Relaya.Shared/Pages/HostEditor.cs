using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Relaya.Data;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya.Pages;

/// Новый хост, изменение и дубль: запись в ~/.ssh/config кодом ядра. Перед сохранением виден блок, который будет записан.
internal static class HostEditor
{
    public static Task Show(XamlRoot root, SshHost? source, bool duplicate)
    {
        var editing = source != null && !duplicate;
        TextBox Field(string header, string? text, string placeholder = "") => new() { Header = header, Text = text ?? "", PlaceholderText = placeholder };
        ComboBox Combo(string header, IEnumerable<string> items, string? text, string placeholder = "")
        {
            var c = new ComboBox { Header = header, IsEditable = true, PlaceholderText = placeholder, HorizontalAlignment = HorizontalAlignment.Stretch };
            foreach (var i in items) c.Items.Add(i);
            c.Text = text ?? "";
            return c;
        }

        var alias = Field(L("Название (Host)"), duplicate ? source!.alias + "-copy" : source?.alias, "prod-web");
        var address = Field(L("Адрес (HostName)"), source?.hostName, "203.0.113.10");
        var user = Field(L("Пользователь"), source?.user, "root");
        var port = Field(L("Порт"), source?.port?.ToString(), "22");
        // `user@host[:port]` в «Название» или «Адрес» раскладывается по полям (разбор — ядро, parse_destination).
        void Split(TextBox from)
        {
            var text = from.Text.Trim();
            if (!text.Contains('@') && !text.StartsWith("ssh://")) return;
            var d = RelayaCoreMethods.ParseDestination(text);
            if (d.host.Length == 0) return;
            if (d.user is { } u) user.Text = u;
            if (d.port is { } pt) port.Text = pt.ToString();
            address.Text = d.host;
            if (from == alias || alias.Text.Trim().Length == 0) alias.Text = d.host;
            from.Description = L("Разложено: пользователь, адрес и порт — в своих полях.");
        }
        alias.LostFocus += (_, _) => Split(alias);
        address.LostFocus += (_, _) => Split(address);
        alias.Description = L("Короткое имя без «@» и пробелов. Можно вставить user@host:port — разложим по полям.");
        var keys = Directory.Exists(AppState.SshDir)
            ? Directory.GetFiles(AppState.SshDir, "*.pub").Select(p => "~/.ssh/" + Path.GetFileNameWithoutExtension(p))
            : Enumerable.Empty<string>();
        // Все IdentityFile блока по порядку (C1): ssh пробует их сверху вниз.
        var keyLines = source == null ? new List<string>()
            : source.identityFiles.Count > 0 ? source.identityFiles : source.identityFile is { } f1 ? new List<string> { f1 } : new List<string>();
        var keyList = new TextBox
        {
            Header = L("Ключи (IdentityFile), по одному в строке"),
            Text = string.Join("\r", keyLines),
            AcceptsReturn = true,
            PlaceholderText = L("необязательно"),
            MinHeight = 56,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
        };
        var addKeyMenu = new MenuFlyout();
        foreach (var k in keys)
        {
            var item = new MenuFlyoutItem { Text = k };
            item.Click += (_, _) => keyList.Text = keyList.Text.Trim().Length == 0 ? k : keyList.Text.TrimEnd() + "\r" + k;
            addKeyMenu.Items.Add(item);
        }
        var addKey = new DropDownButton { Content = L("Добавить ключ из ~/.ssh"), Flyout = addKeyMenu, IsEnabled = addKeyMenu.Items.Count > 0 };
        List<string> KeyFiles() => keyList.Text.Split('\r', '\n').Select(l => l.Trim()).Where(l => l.Length > 0).ToList();
        var jump = Combo(L("Через хост (ProxyJump)"), AppState.Hosts.Select(h => h.alias), source?.proxyJump, L("необязательно"));
        var group = Combo(L("Группа"), AppState.Groups(), source?.group, L("необязательно"));
        var color = new ComboBox { Header = L("Цвет"), HorizontalAlignment = HorizontalAlignment.Stretch };
        color.Items.Add(L("Без цвета"));
        foreach (var c in HostColors.All) color.Items.Add(c.Label);
        color.SelectedIndex = Array.FindIndex(HostColors.All, c => c.Name == source?.color) + 1;
        var tags = Field(L("Метки через запятую"), source == null ? "" : string.Join(", ", source.tags), "prod, db");
        var os = new ComboBox { Header = L("Система"), HorizontalAlignment = HorizontalAlignment.Stretch };
        os.Items.Add(L("Не указана"));
        var all = RelayaCoreMethods.OsAll();
        foreach (var o in all) os.Items.Add(RelayaCoreMethods.OsTitle(o));
        os.SelectedIndex = source?.os is { } so ? all.IndexOf(so) + 1 : 0;
        // Тристейт (C1): «как в конфиге» не пишет строку, «да»/«нет» — явное значение.
        ComboBox Tri(string header, string? value, bool? old)
        {
            var c = new ComboBox { Header = header, HorizontalAlignment = HorizontalAlignment.Stretch, Items = { L("Как в конфиге"), L("Да"), L("Нет") } };
            var v = value ?? (old is { } b ? (b ? "yes" : "no") : null);
            c.SelectedIndex = v == "yes" ? 1 : v == "no" ? 2 : 0;
            return c;
        }
        string? TriValue(ComboBox c) => c.SelectedIndex switch { 1 => "yes", 2 => "no", _ => null };
        bool? TriBool(ComboBox c) => c.SelectedIndex switch { 1 => true, 2 => false, _ => null };
        var agent = Tri(L("Пробрасывать ssh-agent (ForwardAgent)"), source?.forwardAgentValue, source?.forwardAgent);
        var compression = Tri(L("Сжатие (Compression)"), source?.compressionValue, source?.compression);
        var saved = editing && Platform.CredentialStore.Has(source!.alias);
        var forget = false;
        var password = new PasswordBox
        {
            Header = L("Пароль"),
            PlaceholderText = saved ? L("Сохранён — введите новый, чтобы сменить") : L("Если сервер входит по паролю"),
        };
        var forgetButton = new HyperlinkButton { Content = L("Забыть"), Visibility = saved ? Visibility.Visible : Visibility.Collapsed, Padding = new Thickness(0) };
        forgetButton.Click += (_, _) =>
        {
            forget = true;
            forgetButton.Visibility = Visibility.Collapsed;
            password.PlaceholderText = L("Если сервер входит по паролю");
        };
        var passwordNote = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Children = { Ui.Secondary(Platform.PlatformText.PasswordStored()), forgetButton },
        };
        // Keepalive (ServerAliveInterval, секунды; пусто — как в конфиге): ssh шлёт пинги и рвёт мёртвое соединение.
        var keepalive = Field(L("Keepalive, секунд (ServerAliveInterval)"), source?.serverAliveInterval?.ToString(), L("необязательно"));
        var tmux = new ToggleSwitch { Header = L("Сессии в tmux (переживают разрыв связи)"), IsOn = source?.tmux == true };
        // Превью — diff текущего блока и того, что будет записано (1.2, 2.6, как на Mac): «+» добавится, «−» уйдёт.
        var preview = new StackPanel();
        var location = Ui.Secondary("");
        var error = new TextBlock { Foreground = Ui.Brush("SystemFillColorCriticalBrush"), TextWrapping = TextWrapping.Wrap };

        string? Opt(string s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
        SshHost? Build(out string? problem)
        {
            problem = null;
            if (Opt(alias.Text) is not { } name || name.Contains(' ')) { problem = L("Укажите название без пробелов."); return null; }
            if (name.Contains('@')) { problem = L("В названии не должно быть «@»: пользователя укажите в поле «Пользователь», адрес — в поле «Адрес»."); return null; }
            // Все алиасы конфига, включая git-серверы, которых нет в списке хостов (К23).
            var taken = RelayaCoreMethods.ConfigAllAliases(AppState.ConfigText()).Contains(name);
            if (!editing && taken || editing && name != source!.alias && taken)
            { problem = L("Хост «%@» уже есть в ~/.ssh/config", name); return null; }
            long? keepaliveValue = null;
            if (Opt(keepalive.Text) is { } ka)
            {
                if (!long.TryParse(ka, out var kv) || kv is < 0 or > 86400) { problem = L("Keepalive — число секунд от 0 до 86400"); return null; }
                keepaliveValue = kv;
            }
            long? portValue = null;
            if (Opt(port.Text) is { } p)
            {
                if (!long.TryParse(p, out var v) || v is < 1 or > 65535) { problem = L("Порт — число от 1 до 65535"); return null; }
                portValue = v;
            }
            var files = KeyFiles();
            return new SshHost(name, Opt(address.Text), Opt(user.Text), portValue, files.FirstOrDefault(), Opt(jump.Text),
                // Выключили при ForwardAgent в блоке — пишем явное no, иначе значение из блока остаётся (R2).
                TriBool(agent), keepaliveValue, TriBool(compression), Opt(group.Text),
                RelayaCoreMethods.SplitTags(tags.Text), color.SelectedIndex > 0 ? HostColors.All[color.SelectedIndex - 1].Name : null, os.SelectedIndex > 0 ? all[os.SelectedIndex - 1] : null, tmux.IsOn,
                identityFiles: files, forwardAgentValue: TriValue(agent), compressionValue: TriValue(compression));
        }
        void Update()
        {
            var h = Build(out var problem);
            error.Text = problem ?? "";
            preview.Children.Clear();
            var text = AppState.ConfigText();
            var block = editing ? RelayaCoreMethods.ConfigBlock(text, source!.alias) : null;
            location.Text = block is { } b ? L("~/.ssh/config : строка %@", (b.hostLine + 1).ToString()) : L("Новый блок в конце ~/.ssh/config");
            if (h == null) return;
            var before = editing ? RelayaCoreMethods.ConfigCurrentLines(text, source!.alias) : new List<string>();
            var after = RelayaCoreMethods.ConfigRenderedLines(text, h, editing ? source!.alias : null);
            foreach (var line in RelayaCoreMethods.LineDiff(before, after))
                preview.Children.Add(new TextBlock
                {
                    Text = (line.kind == DiffKind.Added ? "+ " : line.kind == DiffKind.Removed ? "− " : "  ") + line.text,
                    FontFamily = new FontFamily("Cascadia Mono, Consolas, monospace"),
                    FontSize = 12,
                    TextWrapping = TextWrapping.Wrap,
                    Foreground = Ui.Brush(line.kind == DiffKind.Added ? "SystemFillColorSuccessBrush"
                        : line.kind == DiffKind.Removed ? "SystemFillColorCriticalBrush" : "TextFillColorSecondaryBrush"),
                });
        }
        foreach (var t in new[] { alias, address, user, port, tags, keyList, keepalive }) t.TextChanged += (_, _) => Update();
        foreach (var c in new[] { jump, group }) { c.SelectionChanged += (_, _) => Update(); c.TextSubmitted += (_, _) => Update(); }
        os.SelectionChanged += (_, _) => Update();
        agent.SelectionChanged += (_, _) => Update();
        compression.SelectionChanged += (_, _) => Update();
        tmux.Toggled += (_, _) => Update();
        Update();

        // Длинная форма — страница в основной области, а не ContentDialog (UI-W3, Fluent: диалог — для коротких форм).
        void Back()
        {
            if (editing && AppState.Host(source!.alias) is { } h0) MainWindow.Current?.ShowPage(new HostPage(h0));
            else MainWindow.Current?.ShowNothing();
        }
        void Save()
        {
            Split(alias);
            Split(address);
            var h = Build(out var problem);
            if (h == null) { error.Text = problem ?? ""; return; }
            try
            {
                AppState.Upsert(h, editing ? source!.alias : null);
                if (editing && h.alias != source!.alias && Platform.CredentialStore.Read(source.alias) is { } pass)
                {
                    Platform.CredentialStore.Write(h.alias, pass);
                    Platform.CredentialStore.Delete(source.alias);
                }
                if (forget) Platform.CredentialStore.Delete(h.alias);
                if (password.Password.Length > 0) Platform.CredentialStore.Write(h.alias, password.Password);
            }
            catch (Exception e) { error.Text = e.Message; return; }
            if (AppState.Host(h.alias) is { } saved) MainWindow.Current?.ShowPage(new HostPage(saved));
        }
        var (page, body) = Ui.Scaffold(editing ? L("Изменить %@", source!.alias) : L("Новый хост"),
            Ui.Button(L("Отмена"), Back),
            Ui.Button(editing ? L("Сохранить") : L("Добавить"), Save, accent: true));
        var form = new StackPanel { Spacing = 12, MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var c in new UIElement[] { alias, address, user, port, password, passwordNote, keyList, addKey, jump, group, tags, color, os, agent, compression, keepalive, tmux })
            form.Children.Add(c);
        form.Children.Add(Ui.Section(L("Изменения в ~/.ssh/config")));
        form.Children.Add(location);
        form.Children.Add(Ui.Card(preview));
        form.Children.Add(error);
        body.Children.Add(form);
        MainWindow.Current?.ShowPage(page);
        return Task.CompletedTask;
    }

    public static async Task AskPassword(XamlRoot root, string alias)
    {
        var box = new PasswordBox { PlaceholderText = L("Пароль") };
        var dialog = new ContentDialog
        {
            Title = L("Пароль для %@", alias),
            Content = new StackPanel
            {
                Spacing = 8,
                Children = { box, Ui.Secondary(Platform.PlatformText.PasswordStoredAndTyped()) },
            },
            PrimaryButtonText = L("Сохранить"),
            CloseButtonText = L("Отмена"),
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = root,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && box.Password.Length > 0)
        {
            try { Platform.CredentialStore.Write(alias, box.Password); }
            catch (Exception e) { await Ui.ShowError(root, L("Не удалось сохранить пароль"), e.Message); }
        }
    }
}
