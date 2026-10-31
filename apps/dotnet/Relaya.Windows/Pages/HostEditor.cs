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
    public static async Task Show(XamlRoot root, SshHost? source, bool duplicate)
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
            Header = L("Ключи (IdentityFile), по одному в строке"), Text = string.Join("\r", keyLines), AcceptsReturn = true,
            PlaceholderText = L("необязательно"), MinHeight = 56, FontFamily = new FontFamily("Cascadia Mono, Consolas"),
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
            Orientation = Orientation.Horizontal, Spacing = 8,
            Children = { Ui.Secondary(L("Хранится в диспетчере учётных данных Windows")), forgetButton },
        };
        var tmux = new ToggleSwitch { Header = L("Сессии в tmux (переживают разрыв связи)"), IsOn = source?.tmux == true };
        var preview = new TextBlock
        {
            FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12, TextWrapping = TextWrapping.Wrap,
            Foreground = Ui.Brush("TextFillColorSecondaryBrush"),
        };
        var error = new TextBlock { Foreground = new SolidColorBrush(Microsoft.UI.Colors.IndianRed), TextWrapping = TextWrapping.Wrap };

        string? Opt(string s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
        SshHost? Build(out string? problem)
        {
            problem = null;
            if (Opt(alias.Text) is not { } name || name.Contains(' ')) { problem = L("Укажите название без пробелов."); return null; }
            if (name.Contains('@')) { problem = L("В названии не должно быть «@»: пользователя укажите в поле «Пользователь», адрес — в поле «Адрес»."); return null; }
            if (!editing && AppState.Host(name) != null || editing && name != source!.alias && AppState.Host(name) != null)
            { problem = L("Хост «%@» уже есть в ~/.ssh/config", name); return null; }
            long? portValue = null;
            if (Opt(port.Text) is { } p)
            {
                if (!long.TryParse(p, out var v) || v is < 1 or > 65535) { problem = L("Порт — число от 1 до 65535."); return null; }
                portValue = v;
            }
            var files = KeyFiles();
            return new SshHost(name, Opt(address.Text), Opt(user.Text), portValue, files.FirstOrDefault(), Opt(jump.Text),
                // Выключили при ForwardAgent в блоке — пишем явное no, иначе значение из блока остаётся (R2).
                TriBool(agent), source?.serverAliveInterval, TriBool(compression), Opt(group.Text),
                RelayaCoreMethods.SplitTags(tags.Text), source?.color, os.SelectedIndex > 0 ? all[os.SelectedIndex - 1] : null, tmux.IsOn,
                identityFiles: files, forwardAgentValue: TriValue(agent), compressionValue: TriValue(compression));
        }
        void Update()
        {
            var h = Build(out var problem);
            error.Text = problem ?? "";
            preview.Text = h == null ? "" : string.Join("\n",
                RelayaCoreMethods.ConfigRenderedLines(AppState.ConfigText(), h, editing ? source!.alias : null));
        }
        foreach (var t in new[] { alias, address, user, port, tags, keyList }) t.TextChanged += (_, _) => Update();
        foreach (var c in new[] { jump, group }) { c.SelectionChanged += (_, _) => Update(); c.TextSubmitted += (_, _) => Update(); }
        os.SelectionChanged += (_, _) => Update();
        agent.SelectionChanged += (_, _) => Update();
        compression.SelectionChanged += (_, _) => Update();
        tmux.Toggled += (_, _) => Update();
        Update();

        var dialog = new ContentDialog
        {
            Title = editing ? L("Изменить %@", source!.alias) : L("Новый хост"),
            Content = new ScrollViewer
            {
                MaxHeight = 560,
                Content = new StackPanel
                {
                    Spacing = 10, MinWidth = 440,
                    Children =
                    {
                        alias, address, user, port, password, passwordNote, keyList, addKey, jump, group, tags, os, agent, compression, tmux,
                        Ui.Section(L("Будет записано в ~/.ssh/config")), Ui.Card(preview), error,
                    },
                },
            },
            PrimaryButtonText = editing ? L("Сохранить") : L("Добавить"),
            CloseButtonText = L("Отмена"),
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = root,
        };
        dialog.PrimaryButtonClick += (_, args) =>
        {
            Split(alias);
            Split(address);
            var h = Build(out var problem);
            if (h == null) { error.Text = problem ?? ""; args.Cancel = true; return; }
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
            catch (Exception e) { error.Text = e.Message; args.Cancel = true; }
        };
        await dialog.ShowAsync();
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
                Children = { box, Ui.Secondary(L("Хранится в диспетчере учётных данных Windows и вводится сам, когда сервер спросит пароль.")) },
            },
            PrimaryButtonText = L("Сохранить"), CloseButtonText = L("Отмена"), DefaultButton = ContentDialogButton.Primary, XamlRoot = root,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && box.Password.Length > 0)
            Platform.CredentialStore.Write(alias, box.Password);
    }
}
