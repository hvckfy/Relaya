using Microsoft.UI.Xaml;

namespace Relaya;

public partial class App : Application
{
    private Window? window;

    public App() => InitializeComponent();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
#if RELAYA_SELFTEST
        if (Terminal.TerminalSelfTest.LogPath != null)
        {
            window = new Window { Title = "Relaya selftest" };
            Terminal.TerminalSelfTest.Run(window);
            return;
        }
#endif
        window = new MainWindow();
        window.Activate();
    }
}
