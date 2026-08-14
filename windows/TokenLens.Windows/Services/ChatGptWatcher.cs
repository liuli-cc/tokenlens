using System.Diagnostics;

namespace TokenLens.Windows.Services;

public sealed class ChatGptWatcher
{
    public bool IsRunning => Process.GetProcessesByName("ChatGPT").Length > 0;
}
