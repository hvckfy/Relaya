namespace Relaya;

public sealed partial class MainWindow
{
    // Трея на Windows пока нет (Shell_NotifyIcon — задача Relaya-windows): окно закрывается, туннели останавливаются.
    private partial bool HideToTray() => false;
}
