using System.CommandLine;
using QCEDL.CLI.Core;
using QCEDL.CLI.Helpers;
using Qualcomm.EmergencyDownload.Layers.APSS.Firehose;

namespace QCEDL.CLI.Commands;

/// <summary>
/// OPPO/OPlus VIP: sends an OEM-signed digest table (--signeddigests) to the running loader and
/// reports whether the loader then accepts an ordinary Firehose command. Non-destructive: it
/// performs no erase or program. On OPPO/OPlus kaanapali (SM8850) the loader rejects every command
/// with "VIP img authentication failed" until this signed table is accepted, so this command is the
/// safe way to confirm the VIP gate opens before attempting a 'rawprogram' flash. The table is
/// OEM-signed and is only transported here (no signing or modification), mirroring
/// fh_loader --signeddigests.
/// </summary>
internal sealed class VipSendCommand
{
    public static Command Create(GlobalOptionsBinder globalOptionsBinder)
    {
        var command = new Command("vip-send",
            "OPPO/OPlus VIP: send the OEM-signed digest table (--signeddigests) and probe whether VIP opens. " +
            "Non-destructive (no erase/program). Pair with --loader (to load a Sahara device first) and --skip-configure.");

        command.SetHandler(ExecuteAsync, globalOptionsBinder);

        return command;
    }

    private static async Task<int> ExecuteAsync(GlobalOptionsBinder globalOptions)
    {
        if (string.IsNullOrEmpty(globalOptions.SignedDigestsPath))
        {
            Logging.Log("Error: '--signeddigests <file>' is required for the 'vip-send' command.", LogLevel.Error);
            return 1;
        }

        Logging.Log("Executing 'vip-send' command...", LogLevel.Trace);

        return await CommandExecutor.RunAsync("vip-send", async () =>
        {
            using var manager = new EdlManager(globalOptions);
            await manager.EnsureFirehoseModeAsync();

            byte[] signedTable;
            try
            {
                signedTable = await File.ReadAllBytesAsync(globalOptions.SignedDigestsPath);
            }
            catch (Exception ex)
            {
                Logging.Log($"Error reading signed digest table '{globalOptions.SignedDigestsPath}': {ex.Message}", LogLevel.Error);
                return 1;
            }

            Logging.Log($"Sending signed digest table '{globalOptions.SignedDigestsPath}' ({signedTable.Length} bytes)...");

            var acked = await Task.Run(() => manager.Firehose.SendSignedDigestTable(signedTable));
            if (!acked)
            {
                Logging.Log("Signed digest table was NOT ACKed. See the DEVPRG LOG lines above for the reason.", LogLevel.Error);
                return 1;
            }

            Logging.Log("Signed digest table ACKed by the loader (VIP table accepted).");

            // Decisive, non-destructive probe: does the loader now accept an ordinary command, or is
            // it still gating per packet? Before the table, even <nop/> returns
            // "VIP img authentication failed" (see run_20_nop.log).
            Logging.Log("Probing VIP state with <nop/>...");
            var nopAcked = await Task.Run(() =>
                manager.Firehose.SendRawXmlAndGetResponse("<?xml version=\"1.0\" ?><data><nop /></data>"));

            if (nopAcked)
            {
                Logging.Log("<nop/> ACKed -> VIP is OPEN after the table load; ordinary commands and " +
                            "'rawprogram --signeddigests ...' should now work.");
            }
            else
            {
                Logging.Log("<nop/> was not ACKed -> the loader is still VIP-gating per packet; " +
                            "see the DEVPRG LOG lines above.", LogLevel.Warning);
            }

            return 0;
        });
    }
}
