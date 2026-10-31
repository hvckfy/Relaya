using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;

namespace Relaya.Terminal;

/// Терминал для экранных дикторов (UI-W2, этап 1): тип «текст», имя, вежливая live-region —
/// Narrator объявляет новые завершённые строки вывода. Чтение экрана построчно (ITextProvider) — этап 2.
internal sealed class TerminalAutomationPeer(TerminalView owner) : FrameworkElementAutomationPeer(owner)
{
    protected override string GetClassNameCore() => "TerminalView";
    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Text;
    protected override string GetNameCore() => Strings.L("Терминал");
    protected override AutomationLiveSetting GetLiveSettingCore() => AutomationLiveSetting.Polite;
    protected override bool IsKeyboardFocusableCore() => true;
}
