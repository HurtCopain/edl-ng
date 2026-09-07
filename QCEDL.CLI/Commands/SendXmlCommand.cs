using System.CommandLine;
using QCEDL.CLI.Core;
using QCEDL.CLI.Helpers;
using Qualcomm.EmergencyDownload.Layers.APSS.Firehose;

namespace QCEDL.CLI.Commands;

/// <summary>
/// Sends an arbitrary raw Firehose XML command and prints the response. Intended for
/// diagnostics and exercising loader-specific commands (e.g. "resetdigest",
/// "getsha256digest") that aren't wrapped by a dedicated CLI command.
/// </summary>
internal sealed class SendXmlCommand
{
    private static readonly Option<string> XmlOption = new(
        aliases: ["--xml"],
        description: "Raw Firehose XML command to send, e.g. \"<resetdigest/>\" or \"<getsha256digest .../>\". " +
                     "Sent as-is (no <?xml?> declaration or <data> wrapper added).")
    {
        IsRequired = true
    };

    public static Command Create(GlobalOptionsBinder globalOptionsBinder)
    {
        var command = new Command("send-xml",
            "Sends a raw Firehose XML command and prints the response. For diagnostics / loader-specific commands not otherwise exposed.")
        {
            XmlOption
        };

        command.SetHandler(ExecuteAsync, globalOptionsBinder, XmlOption);

        return command;
    }

    private static async Task<int> ExecuteAsync(GlobalOptionsBinder globalOptions, string xml)
    {
        Logging.Log($"Executing 'send-xml' command: '{xml}'...", LogLevel.Trace);

        return await CommandExecutor.RunAsync("send-xml", async () =>
        {
            using var manager = new EdlManager(globalOptions);
            await manager.EnsureFirehoseModeAsync();

            Logging.Log($"Sending raw XML: {xml}");

            var success = await Task.Run(() => manager.Firehose.SendRawXmlAndGetResponse(xml));

            if (success)
            {
                Logging.Log("Command ACKed.");
            }
            else
            {
                Logging.Log("Command NAKed or no ACK received. Check previous logs for the device's response/log lines.", LogLevel.Error);
                return 1;
            }

            return 0;
        });
    }
}
