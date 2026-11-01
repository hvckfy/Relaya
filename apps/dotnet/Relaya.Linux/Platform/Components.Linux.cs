using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using static Relaya.Strings;

namespace Relaya.Platform;

/// Что нужно Linux-клиенту снаружи и как это поставить в этом дистрибутиве (apt, dnf, pacman, zypper — по /etc/os-release).
internal static partial class Components
{
    // Пакет компонента по менеджеру; null — в этом дистрибутиве ставится иначе.
    private sealed record Packages(string Apt, string Dnf, string Pacman, string Zypper);

    public static partial List<Item> List()
    {
        var pm = Manager();
        string? Install(Packages p) => pm switch
        {
            "apt" => "sudo apt install " + p.Apt,
            "dnf" => "sudo dnf install " + p.Dnf,
            "pacman" => "sudo pacman -S " + p.Pacman,
            "zypper" => "sudo zypper install " + p.Zypper,
            _ => null,
        };
        bool Has(params string[] programs) => programs.Any(p => Dialogs.Which(p) != null);
        var library = CredentialStore.LibraryAvailable();
        return new List<Item>
        {
            new("OpenSSH (ssh, sftp, ssh-keygen)", L("Терминал, файлы, туннели и ключи — всё идёт через системный ssh."),
                Has("ssh") && Has("sftp"), true, Install(new("openssh-client", "openssh-clients", "openssh", "openssh-clients"))),
            new("libsecret", L("Библиотека, через которую Relaya сохраняет пароли серверов в системном хранилище."),
                library, true, Install(new("libsecret-1-0", "libsecret", "libsecret", "libsecret-1-0"))),
            new(L("Служба хранения паролей (GNOME Keyring или KWallet)"),
                L("Хранит пароли серверов. Без неё пароли не сохраняются, вход по ключу работает. После установки войдите в систему заново."),
                library && CredentialStore.ServiceAvailable(), true, Install(new("gnome-keyring", "gnome-keyring", "gnome-keyring", "gnome-keyring"))),
            new("zenity / kdialog", L("Подтверждения без окна Relaya: команды агентов (MCP) и выдача пароля по запросу ssh."),
                Has("zenity", "kdialog"), false, Install(new("zenity", "zenity", "zenity", "zenity"))),
            new("xdg-utils", L("Открывать ссылки из терминала, порты сервера в браузере и папку журналов."),
                Has("xdg-open"), false, Install(new("xdg-utils", "xdg-utils", "xdg-utils", "xdg-utils"))),
            new("pacat (PulseAudio / PipeWire)", L("Звук встроенного RDP."),
                Has("pacat"), false, Install(new("pulseaudio-utils", "pulseaudio-utils", "libpulse", "pulseaudio-utils"))),
            new("TigerVNC / Remmina", L("Подключения VNC (встроенного VNC пока нет)."),
                Has("vncviewer", "remmina"), false, Install(new("tigervnc-viewer", "tigervnc", "tigervnc", "tigervnc"))),
            new("FreeRDP / Remmina", L("Запасной внешний RDP-клиент; основной RDP — встроенный, во вкладке."),
                Has("xfreerdp3", "xfreerdp", "remmina"), false, Install(new("freerdp3-x11", "freerdp", "freerdp", "freerdp"))),
        };
    }

    // ID и ID_LIKE из /etc/os-release → менеджер пакетов.
    private static string? Manager()
    {
        try
        {
            var ids = File.ReadAllLines("/etc/os-release")
                .Where(l => l.StartsWith("ID=") || l.StartsWith("ID_LIKE="))
                .SelectMany(l => l[(l.IndexOf('=') + 1)..].Trim('"').Split(' '))
                .ToHashSet();
            if (ids.Overlaps(new[] { "debian", "ubuntu" })) return "apt";
            if (ids.Overlaps(new[] { "fedora", "rhel", "centos" })) return "dnf";
            if (ids.Overlaps(new[] { "arch", "manjaro" })) return "pacman";
            if (ids.Overlaps(new[] { "suse", "opensuse", "opensuse-leap", "opensuse-tumbleweed" })) return "zypper";
        }
        catch (Exception) { }
        return null;
    }
}
