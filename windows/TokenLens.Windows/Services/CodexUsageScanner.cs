using System.Text.Json;

namespace TokenLens.Windows.Services;

public sealed record UsageSnapshot(
    string Model,
    string Provider,
    long TotalTokens,
    long ContextTokens,
    long ContextWindow,
    double? RemainingQuota,
    double CacheHitRate,
    DateTimeOffset UpdatedAt)
{
    public static UsageSnapshot Empty => new(
        "Waiting for Codex", "OpenAI", 0, 0, 0, null, 0, DateTimeOffset.Now);
}

public sealed class CodexUsageScanner
{
    private readonly string sessionsRoot = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "sessions");

    public UsageSnapshot Scan()
    {
        if (!Directory.Exists(sessionsRoot)) return UsageSnapshot.Empty;

        var cutoff = DateTimeOffset.Now.AddDays(-7);
        var model = "Waiting for Codex";
        var provider = "OpenAI";
        long total = 0;
        long context = 0;
        long contextWindow = 0;
        long input = 0;
        long cachedInput = 0;
        DateTimeOffset latest = DateTimeOffset.MinValue;

        foreach (var file in Directory.EnumerateFiles(sessionsRoot, "*.jsonl", SearchOption.AllDirectories))
        {
            if (File.GetLastWriteTimeUtc(file) < cutoff.UtcDateTime) continue;

            foreach (var line in File.ReadLines(file))
            {
                try
                {
                    using var document = JsonDocument.Parse(line);
                    var root = document.RootElement;
                    if (!root.TryGetProperty("payload", out var payload)) continue;
                    var type = root.TryGetProperty("type", out var typeValue) ? typeValue.GetString() : null;

                    if (type == "session_meta" && payload.TryGetProperty("model_provider", out var providerValue))
                        provider = providerValue.GetString() ?? provider;
                    if (type == "turn_context" && payload.TryGetProperty("model", out var modelValue))
                        model = modelValue.GetString() ?? model;
                    if (type == "task_started" && payload.TryGetProperty("model_context_window", out var window))
                        contextWindow = Math.Max(contextWindow, ReadInt64(window));

                    if (!payload.TryGetProperty("type", out var eventType) || eventType.GetString() != "token_count") continue;
                    if (!payload.TryGetProperty("info", out var info) ||
                        !info.TryGetProperty("total_token_usage", out var usage)) continue;

                    var nextTotal = ReadInt64(usage, "total_tokens");
                    total = Math.Max(total, nextTotal);
                    input = Math.Max(input, ReadInt64(usage, "input_tokens"));
                    cachedInput = Math.Max(cachedInput, ReadInt64(usage, "cached_input_tokens"));
                    context = Math.Max(context, nextTotal);
                    if (root.TryGetProperty("timestamp", out var timestamp) &&
                        DateTimeOffset.TryParse(timestamp.GetString(), out var parsed)) latest = parsed;
                }
                catch (JsonException)
                {
                    // Codex sessions can be read while the last line is still being written.
                }
            }
        }

        return new UsageSnapshot(
            model,
            provider,
            total,
            context,
            contextWindow,
            null,
            input == 0 ? 0 : (double)cachedInput / input,
            latest == DateTimeOffset.MinValue ? DateTimeOffset.Now : latest);
    }

    private static long ReadInt64(JsonElement parent, string name)
        => parent.TryGetProperty(name, out var value) ? ReadInt64(value) : 0;

    private static long ReadInt64(JsonElement value)
        => value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number) ? number : 0;
}
