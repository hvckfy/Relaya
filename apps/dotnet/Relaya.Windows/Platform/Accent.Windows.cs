namespace Relaya.Platform;

internal static partial class Accent
{
    // Windows: акцент из «Персонализация → Цвета». Кисти приложения свои (App.xaml), поэтому системный цвет
    // ставится в них явно, как и свой, а смена акцента в системе применяется заново.
    private static readonly Windows.UI.ViewManagement.UISettings SystemColors = Watch(new());

    private static partial Windows.UI.Color? PlatformSystemAccent() => SystemColors.GetColorValue(Windows.UI.ViewManagement.UIColorType.Accent);

    private static Windows.UI.ViewManagement.UISettings Watch(Windows.UI.ViewManagement.UISettings settings)
    {
        // Событие приходит из фонового потока.
        settings.ColorValuesChanged += (_, _) => MainWindow.Current?.DispatcherQueue.TryEnqueue(() => { if (Custom == null) Apply(); });
        return settings;
    }
}
