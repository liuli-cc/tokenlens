namespace TokenLens.Windows;

public partial class App : System.Windows.Application
{
    protected override void OnStartup(System.Windows.StartupEventArgs e)
    {
        base.OnStartup(e);
        MainWindow = new MainWindow();
        MainWindow.Show();
    }
}
