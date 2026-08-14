using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using TokenLens.Windows.Services;

namespace TokenLens.Windows;

public partial class MainWindow : Window
{
    private const double CompactWidth = 358;
    private const double CompactHeight = 33;
    private const double ExpandedWidth = 548;
    private const double ExpandedHeight = 148;

    private readonly CodexUsageScanner scanner = new();
    private readonly ChatGptWatcher chatGptWatcher = new();
    private readonly DispatcherTimer pointerTimer = new() { Interval = TimeSpan.FromMilliseconds(30) };
    private readonly DispatcherTimer refreshTimer = new() { Interval = TimeSpan.FromSeconds(5) };
    private bool isExpanded;

    public MainWindow()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            PositionCompact();
            pointerTimer.Tick += (_, _) => UpdatePointerState();
            refreshTimer.Tick += (_, _) => RefreshSnapshot();
            pointerTimer.Start();
            refreshTimer.Start();
            RefreshSnapshot();
        };
    }

    private void UpdatePointerState()
    {
        if (!chatGptWatcher.IsRunning)
        {
            Hide();
            return;
        }

        if (!IsVisible) Show();
        NativeMethods.GetCursorPos(out var point);
        var center = SystemParameters.PrimaryScreenWidth / 2;
        var inTrigger = point.X >= center - 220 && point.X <= center + 220 && point.Y <= 26;
        var inPanel = point.X >= Left && point.X <= Left + Width && point.Y >= Top && point.Y <= Top + Height;

        if (!isExpanded && inTrigger) Expand();
        else if (isExpanded && !inTrigger && !inPanel) Collapse();
    }

    private void RefreshSnapshot()
    {
        var snapshot = scanner.Scan();
        CompactModel.Text = snapshot.Model;
        CompactProvider.Text = snapshot.Provider;
        ExpandedModel.Text = snapshot.Model;
        ExpandedProvider.Text = snapshot.Provider;
        var quota = snapshot.RemainingQuota is double value ? $"{value:0.0}%" : "--";
        CompactQuota.Text = quota;
        ExpandedQuota.Text = quota;
        MetricTokens.Text = FormatTokens(snapshot.TotalTokens);
        MetricContext.Text = snapshot.ContextWindow == 0 ? FormatTokens(snapshot.ContextTokens) : $"{snapshot.ContextTokens / 1000.0:0.#}k / {snapshot.ContextWindow / 1000.0:0.#}k";
        MetricCache.Text = $"{snapshot.CacheHitRate * 100:0.0}%";
    }

    private void Expand()
    {
        if (isExpanded) return;
        isExpanded = true;
        ExpandedContent.Visibility = Visibility.Visible;
        CompactContent.Visibility = Visibility.Collapsed;
        IslandSurface.CornerRadius = new CornerRadius(0, 0, 30, 30);
        AnimatePanel(ExpandedWidth, ExpandedHeight, 680);
    }

    private void Collapse()
    {
        if (!isExpanded) return;
        isExpanded = false;
        ExpandedContent.Visibility = Visibility.Collapsed;
        CompactContent.Visibility = Visibility.Visible;
        IslandSurface.CornerRadius = new CornerRadius(0, 0, 16.5, 16.5);
        AnimatePanel(CompactWidth, CompactHeight, 160);
    }

    private void AnimatePanel(double width, double height, int milliseconds)
    {
        var easing = new CubicEase { EasingMode = EasingMode.EaseOut };
        BeginAnimation(WidthProperty, new DoubleAnimation(width, TimeSpan.FromMilliseconds(milliseconds)) { EasingFunction = easing });
        BeginAnimation(HeightProperty, new DoubleAnimation(height, TimeSpan.FromMilliseconds(milliseconds)) { EasingFunction = easing });
        Left = (SystemParameters.PrimaryScreenWidth - width) / 2;
    }

    private void PositionCompact()
    {
        Width = CompactWidth;
        Height = CompactHeight;
        Left = (SystemParameters.PrimaryScreenWidth - CompactWidth) / 2;
        Top = 0;
    }

    private void IslandSurface_OnMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (!isExpanded) Expand();
    }

    private static string FormatTokens(long value)
        => value >= 1_000_000 ? $"{value / 1_000_000.0:0.#}M" : value >= 1_000 ? $"{value / 1_000.0:0.#}k" : value.ToString("N0");
}
