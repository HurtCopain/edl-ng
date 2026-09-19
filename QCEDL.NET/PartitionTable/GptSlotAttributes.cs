namespace QCEDL.NET.PartitionTable;

/// <summary>
/// Android/Qualcomm A/B slot metadata, stored in the top byte range of each GPT partition
/// entry's 8-byte Attributes field. Byte 6 of that field carries bits 48..55:
///
///   bits 48-49  priority      (0..3)
///   bit  50     active
///   bits 51-53  retry count   (0..7)
///   bit  54     boot successful
///   bit  55     unbootable
///
/// Layout matches Qualcomm's gpt-utils (PART_ATT_PRIORITY_BIT = 48, PART_ATT_ACTIVE_BIT = 50,
/// PART_ATT_MAX_RETRY_CNT_BIT = 51, PART_ATT_SUCCESS_BIT = 54, PART_ATT_UNBOOTABLE_BIT = 55)
/// and is the same encoding bkerler/edl writes.
/// </summary>
public static class GptSlotAttributes
{
    /// <summary>Byte index, within the 8-byte Attributes field, holding the A/B flags.</summary>
    public const int AbFlagByteOffset = 6;

    /// <summary>Offset of the Attributes field within a 128-byte GPT partition entry.</summary>
    public const int AttributesOffsetInEntry = 48;

    /// <summary>Offset of the UTF-16LE partition name within a GPT partition entry.</summary>
    public const int NameOffsetInEntry = 56;

    /// <summary>Maximum length in bytes of the partition name field.</summary>
    public const int NameLengthInEntry = 72;

    /// <summary>Bit 50 within byte 6: the "slot active" flag.</summary>
    public const byte SlotActiveBit = 0x04;

    /// <summary>
    /// Flag byte written to the ACTIVE boot partition: 0x6F =
    /// priority 3, active, retry 5, successful 1, unbootable 0.
    /// Matches bkerler/edl firehose.py cmd_setactiveslot (new_flags = 0x6f).
    /// NOTE: the AB_SLOT_ACTIVE_VAL = 0x3F constant in that project's gpt.py is NOT what the
    /// runtime path uses -- it is unused legacy. Do not "simplify" to 0x3F.
    /// </summary>
    public const byte BootSlotActive = 0x6F;

    /// <summary>
    /// Flag byte written to the INACTIVE boot partition: 0x3A =
    /// priority 2, not active, retry 7, successful 0, unbootable 0.
    /// Priority 2 (not 0) deliberately keeps the other slot bootable as a fallback.
    /// Matches bkerler/edl (new_flags = 0x3a).
    /// </summary>
    public const byte BootSlotInactive = 0x3A;

    public static string Describe(byte flags)
    {
        var priority = flags & 0x03;
        var active = (flags >> 2) & 0x01;
        var retry = (flags >> 3) & 0x07;
        var successful = (flags >> 6) & 0x01;
        var unbootable = (flags >> 7) & 0x01;

        return $"priority={priority} active={active} retry={retry} successful={successful} unbootable={unbootable}";
    }
}
