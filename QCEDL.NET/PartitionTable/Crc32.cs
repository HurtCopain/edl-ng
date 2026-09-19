namespace QCEDL.NET.PartitionTable;

/// <summary>
/// CRC-32/ISO-HDLC (reflected, polynomial 0xEDB88320), as required by the GPT specification
/// for both the header checksum and the partition entry array checksum.
/// </summary>
public static class Crc32
{
    private static readonly uint[] Table = BuildTable();

    private static uint[] BuildTable()
    {
        var table = new uint[256];

        for (uint i = 0; i < 256; i++)
        {
            var c = i;

            for (var k = 0; k < 8; k++)
            {
                c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            }

            table[i] = c;
        }

        return table;
    }

    public static uint Compute(ReadOnlySpan<byte> data)
    {
        var crc = 0xFFFFFFFFu;

        foreach (var b in data)
        {
            crc = Table[(crc ^ b) & 0xFF] ^ (crc >> 8);
        }

        return crc ^ 0xFFFFFFFFu;
    }
}
