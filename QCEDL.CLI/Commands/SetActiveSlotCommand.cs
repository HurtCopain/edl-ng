using System.CommandLine;
using QCEDL.CLI.Core;
using QCEDL.CLI.Helpers;
using QCEDL.NET.PartitionTable;

namespace QCEDL.CLI.Commands;

/// <summary>
/// Switches the active A/B slot by editing GPT partition entry metadata.
///
/// Semantics follow bkerler/edl firehose.py cmd_setactiveslot, which is the behaviour known to
/// work on Qualcomm targets. Two things there are easy to get wrong and are reproduced here:
///
///  1. The TypeGUIDs of each _a/_b pair are SWAPPED. Qualcomm's XBL uses the partition type GUID
///     to locate boot-chain partitions, so flag bits alone do not move the slot.
///  2. Only boot_a/boot_b get a wholesale flag-byte replacement (0x6F active / 0x3A inactive).
///     Every other slotted partition just has the active bit (bit 50) set or cleared, preserving
///     its existing priority / retry / successful bits.
/// </summary>
internal sealed class SetActiveSlotCommand
{
    private static readonly Argument<string> SlotArgument =
        new("slot", "Slot to make active: 'a' or 'b'.");

    private static readonly Option<uint?> LunOption = new(
        aliases: ["--lun", "-u"],
        description: "Restrict to a single LUN. Default: every LUN that carries slotted partitions.");

    private static readonly Option<bool> DryRunOption = new(
        name: "--dry-run",
        description: "Show every change that would be made, then exit without writing.");

    public static Command Create(GlobalOptionsBinder globalOptionsBinder)
    {
        var command = new Command("set-active-slot", "Sets the active A/B boot slot via GPT partition attributes.")
        {
            SlotArgument,
            LunOption,
            DryRunOption
        };

        command.SetHandler(ExecuteAsync, globalOptionsBinder, SlotArgument, LunOption, DryRunOption);
        return command;
    }

    private static async Task<int> ExecuteAsync(
        GlobalOptionsBinder globalOptions,
        string slot,
        uint? lun,
        bool dryRun)
    {
        var target = slot.Trim().ToLowerInvariant();

        if (target is not ("a" or "b"))
        {
            Logging.Log($"Error: slot must be 'a' or 'b', got '{slot}'.", LogLevel.Error);
            return 1;
        }

        return await CommandExecutor.RunAsync("set-active-slot", async () =>
        {
            using var manager = new EdlManager(globalOptions);

            var lunsToProcess = await manager.StorageBackend.DetermineLunsToScanAsync(lun);
            var exitCode = 0;
            var totalChanged = 0;

            foreach (var currentLun in lunsToProcess)
            {
                var effectiveLun = manager.IsDirectMode ? 0u : currentLun;

                try
                {
                    var geometry = await manager.GetStorageGeometryAsync(effectiveLun);
                    var sectorSize = (int)geometry.SectorSize;

                    const uint sectorsToRead = 64;
                    var buffer = await manager.ReadSectorsAsync(effectiveLun, 0, sectorsToRead);

                    if (buffer == null || buffer.Length < sectorSize * 3)
                    {
                        Logging.Log($"LUN {currentLun}: could not read enough sectors for a GPT; skipping.", LogLevel.Debug);
                        continue;
                    }

                    var changed = PatchSlotMetadata(buffer, sectorSize, target, currentLun, out var headerLba, out var lastTouchedSector);

                    if (changed == 0)
                    {
                        Logging.Log($"LUN {currentLun}: no slotted (_a/_b) partitions; nothing to do.");
                        continue;
                    }

                    totalChanged += changed;

                    if (dryRun)
                    {
                        Logging.Log($"LUN {currentLun}: {changed} partition entries would change (dry run, nothing written).");
                        continue;
                    }

                    var firstSector = headerLba;
                    var sectorCount = (int)(lastTouchedSector - firstSector + 1);
                    var slice = new byte[sectorCount * sectorSize];
                    Array.Copy(buffer, (int)firstSector * sectorSize, slice, 0, slice.Length);

                    using var ms = new MemoryStream(slice, writable: false);
                    await manager.WriteSectorsFromStreamAsync(
                        effectiveLun, firstSector, ms, slice.Length, padToSector: false,
                        sourceName: $"GPT slot metadata (LUN {currentLun})");

                    Logging.Log($"LUN {currentLun}: wrote {sectorCount} sector(s), {changed} partition entries updated.");
                }
                catch (Exception ex)
                {
                    Logging.Log($"LUN {currentLun}: {ex.Message}", LogLevel.Error);
                    exitCode = 1;
                }
            }

            if (totalChanged == 0)
            {
                Logging.Log("No slotted partitions found on any scanned LUN.", LogLevel.Warning);
                return exitCode;
            }

            if (!dryRun)
            {
                Logging.Log($"Active slot set to '{target}'. NOTE: only the primary GPT was updated; " +
                            "the backup GPT at the end of each LUN is now stale.", LogLevel.Warning);
            }

            return exitCode;
        });
    }

    /// <summary>
    /// Edits the GPT in <paramref name="buffer"/> in place and fixes both CRCs.
    /// Returns the number of partition entries modified.
    /// </summary>
    private static int PatchSlotMetadata(
        byte[] buffer, int sectorSize, string targetSlot, uint lunForLog,
        out ulong headerLba, out ulong lastTouchedSector)
    {
        headerLba = 1;
        lastTouchedSector = 1;

        // The GPT header normally lives at LBA 1 (LBA 0 being the protective MBR), but some
        // dumps start at LBA 0. Probe both.
        if (!HasGptSignature(buffer, sectorSize))
        {
            headerLba = 0;

            if (!HasGptSignature(buffer, 0))
            {
                return 0;
            }
        }

        var hdr = (int)headerLba * sectorSize;

        var headerSize = BitConverter.ToUInt32(buffer, hdr + 12);
        var partArrayLba = BitConverter.ToUInt64(buffer, hdr + 72);
        var entryCount = BitConverter.ToUInt32(buffer, hdr + 80);
        var entrySize = BitConverter.ToUInt32(buffer, hdr + 84);

        var arrayOffset = (int)partArrayLba * sectorSize;
        var arrayBytes = (int)(entryCount * entrySize);

        if (arrayOffset + arrayBytes > buffer.Length || entrySize < 128)
        {
            throw new InvalidDataException(
                $"GPT partition array (LBA {partArrayLba}, {arrayBytes} bytes) extends past the sectors read.");
        }

        // Collect slotted entries by base name.
        var bySuffix = new Dictionary<string, (int OffsetA, int OffsetB)>(StringComparer.OrdinalIgnoreCase);

        for (var i = 0; i < entryCount; i++)
        {
            var entry = arrayOffset + (i * (int)entrySize);

            if (IsEmptyGuid(buffer, entry))
            {
                continue;
            }

            var name = ReadEntryName(buffer, entry);

            if (name.Length < 3)
            {
                continue;
            }

            var suffix = name[^2..];

            if (!suffix.Equals("_a", StringComparison.OrdinalIgnoreCase) &&
                !suffix.Equals("_b", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var baseName = name[..^2];
            _ = bySuffix.TryGetValue(baseName, out var pair);

            if (suffix.Equals("_a", StringComparison.OrdinalIgnoreCase))
            {
                pair.OffsetA = entry;
            }
            else
            {
                pair.OffsetB = entry;
            }

            bySuffix[baseName] = pair;
        }

        var changed = 0;
        var makeAActive = targetSlot == "a";

        foreach (var (baseName, pair) in bySuffix)
        {
            if (pair.OffsetA == 0 || pair.OffsetB == 0)
            {
                Logging.Log($"LUN {lunForLog}: '{baseName}' has only one slot present; skipping.", LogLevel.Debug);
                continue;
            }

            // 1. Swap the type GUIDs. XBL locates boot-chain partitions by type GUID, so the
            //    flag bits alone are not sufficient to move the slot.
            for (var b = 0; b < 16; b++)
            {
                (buffer[pair.OffsetA + b], buffer[pair.OffsetB + b]) =
                    (buffer[pair.OffsetB + b], buffer[pair.OffsetA + b]);
            }

            // 2. Update the A/B flag byte.
            var flagA = pair.OffsetA + GptSlotAttributes.AttributesOffsetInEntry + GptSlotAttributes.AbFlagByteOffset;
            var flagB = pair.OffsetB + GptSlotAttributes.AttributesOffsetInEntry + GptSlotAttributes.AbFlagByteOffset;

            var isBoot = baseName.Equals("boot", StringComparison.OrdinalIgnoreCase);

            if (isBoot)
            {
                buffer[flagA] = makeAActive ? GptSlotAttributes.BootSlotActive : GptSlotAttributes.BootSlotInactive;
                buffer[flagB] = makeAActive ? GptSlotAttributes.BootSlotInactive : GptSlotAttributes.BootSlotActive;
            }
            else
            {
                SetActiveBit(buffer, flagA, makeAActive);
                SetActiveBit(buffer, flagB, !makeAActive);
            }

            Logging.Log(
                $"LUN {lunForLog}: {baseName}_a -> {GptSlotAttributes.Describe(buffer[flagA])} | " +
                $"{baseName}_b -> {GptSlotAttributes.Describe(buffer[flagB])}",
                LogLevel.Debug);

            changed += 2;
        }

        if (changed == 0)
        {
            return 0;
        }

        // 3. Recompute the partition array CRC, then the header CRC (with its own field zeroed).
        var arrayCrc = Crc32.Compute(buffer.AsSpan(arrayOffset, arrayBytes));
        BitConverter.GetBytes(arrayCrc).CopyTo(buffer, hdr + 88);

        Array.Clear(buffer, hdr + 16, 4);
        var headerCrc = Crc32.Compute(buffer.AsSpan(hdr, (int)headerSize));
        BitConverter.GetBytes(headerCrc).CopyTo(buffer, hdr + 16);

        lastTouchedSector = partArrayLba + (ulong)((arrayBytes + sectorSize - 1) / sectorSize) - 1;
        return changed;
    }

    private static void SetActiveBit(byte[] buffer, int flagOffset, bool active)
    {
        buffer[flagOffset] = active
            ? (byte)(buffer[flagOffset] | GptSlotAttributes.SlotActiveBit)
            : (byte)(buffer[flagOffset] & ~GptSlotAttributes.SlotActiveBit);
    }

    private static bool HasGptSignature(byte[] buffer, int offset)
    {
        return offset + 8 <= buffer.Length && BitConverter.ToUInt64(buffer, offset) == 0x5452415020494645UL;
    }

    private static bool IsEmptyGuid(byte[] buffer, int offset)
    {
        for (var i = 0; i < 16; i++)
        {
            if (buffer[offset + i] != 0)
            {
                return false;
            }
        }

        return true;
    }

    private static string ReadEntryName(byte[] buffer, int entryOffset)
    {
        var name = System.Text.Encoding.Unicode.GetString(
            buffer, entryOffset + GptSlotAttributes.NameOffsetInEntry, GptSlotAttributes.NameLengthInEntry);

        var nul = name.IndexOf('\0');
        return (nul >= 0 ? name[..nul] : name).Trim();
    }
}
