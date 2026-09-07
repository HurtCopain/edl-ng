#!/usr/bin/env bash
#
# EDL ABL Recovery Runbook  --  OPPO Find X9 Ultra (CPH2841 / SM8850 "kaanapali")
#
# PURPOSE: restore a corrupted abl_a from official OPPO-signed firmware.
#
# Device facts established from the EDL package (rawprogram4.xml):
#   LUN                4   (physical_partition_number="4")
#   abl_a              start_sector 98310, 256 sectors
#   abl_b              start_sector 458038, 256 sectors
#   sector size        4096 bytes
#   partition size     256 * 4096 = 1048576 bytes (1 MiB)
#
# DESIGN NOTE: Firehose sessions are stateful and single-shot. The programmer
# lives in RAM only after a successful Sahara upload. If any step fails, the
# session is dead -- power-cycle back to 9008 and start again from PHASE 1.
# Do NOT retry individual commands without re-uploading the loader.
#
# This script STOPS before writing anything. The write is a separate,
# deliberate step you run by hand after reviewing the comparison results.
#
set -u

BIN="$HOME/edl-ng/QCEDL.CLI/bin/Release/net9.0/linux-x64/edl-ng"
LOADER="$HOME/edl-ng/loader.xml"
WORK="$HOME/edl-ng"
LUN=4
PARTSIZE=1048576
CMPLEN=278328          # size of abl.elf; compare this many bytes

cd "$WORK" || { echo "FATAL: $WORK not found"; exit 1; }

hr() { echo; echo "==================== $* ===================="; }
die() {
    echo
    echo "!!!! FAILED: $*"
    echo "!!!! Session is dead. Power-cycle to 9008 and re-run from the top."
    exit 1
}

# ---------------------------------------------------------------------------
hr "PHASE 0  --  HOST PRE-FLIGHT (no device needed)"
# ---------------------------------------------------------------------------

echo "[*] Binary:"
[ -x "$BIN" ] || die "edl-ng binary missing or not executable at $BIN"
ls -la "$BIN"

echo
echo "[*] Loader XML (needs 8 image_path entries + closing tag):"
[ -f "$LOADER" ] || die "loader.xml missing at $LOADER"
N=$(grep -c image_path "$LOADER")
echo "    image_path count: $N"
[ "$N" -eq 8 ] || die "loader.xml has $N image_path entries, expected 8"
tail -1 "$LOADER" | grep -q '</sahara_config>' || die "loader.xml truncated"

echo
echo "[*] All 8 loader images resolve:"
MISS=0
grep -o 'image_path="[^"]*"' "$LOADER" | sed 's/image_path="//;s/"//' | while read -r p; do
    if [ -f "$p" ]; then echo "    OK      $p"; else echo "    MISSING $p"; fi
done
grep -o 'image_path="[^"]*"' "$LOADER" | sed 's/image_path="//;s/"//' | \
    while read -r p; do [ -f "$p" ] || exit 1; done || die "one or more loader images missing"

echo
echo "[*] ABL candidate images:"
for f in abl.elf abl.img; do
    if [ -f "$f" ]; then
        printf "    %-10s %8d bytes  sha256=%s\n" "$f" "$(stat -c%s "$f")" "$(sha256sum "$f" | cut -c1-16)"
    else
        echo "    $f  NOT PRESENT"
    fi
done
[ -f abl.elf ] || [ -f abl.img ] || die "neither abl.elf nor abl.img present"

echo
echo "[*] qcserial must NOT be loaded (it steals the interface):"
if lsmod | grep -q '^qcserial'; then
    echo "    qcserial IS LOADED -- removing"
    sudo modprobe -r qcserial option usb_wwan 2>/dev/null
else
    echo "    OK, not loaded"
fi

# ---------------------------------------------------------------------------
hr "PHASE 1  --  DEVICE PRESENT IN 9008"
# ---------------------------------------------------------------------------
# Get here by: power off fully (Power+VolUp 30s), then hold VolUp+VolDown and
# plug in USB. Prefer a USB 2.0 port. Battery must be well charged.

echo "[*] Waiting for 05c6:9008 (60s timeout)..."
for i in $(seq 1 60); do
    if lsusb | grep -qi '05c6:9008'; then
        echo "    FOUND:"; lsusb | grep -i 05c6
        break
    fi
    [ "$i" -eq 60 ] && die "device never appeared as 05c6:9008"
    sleep 1
done

if lsusb | grep -qi '05c6:900e'; then
    die "device is in 900e (crashdump), not 9008. Power-cycle into EDL."
fi

# ---------------------------------------------------------------------------
hr "PHASE 2  --  UPLOAD FIREHOSE LOADER (multi-image Sahara)"
# ---------------------------------------------------------------------------
# Expect 8 images served in device-requested order, ending with
# "Loader uploaded and started successfully via Sahara."

sudo "$BIN" --loader "$LOADER" --loglevel Debug upload-loader 2>&1 | tee phase2_upload.log
grep -q "Loader uploaded and started successfully" phase2_upload.log \
    || die "Sahara loader upload did not complete"

echo
echo "[*] Loader running. Firehose is live in RAM. Do not unplug."
sleep 2

# ---------------------------------------------------------------------------
hr "PHASE 3  --  READ GPT (first real test of the read path)"
# ---------------------------------------------------------------------------
# This is the gate. If configure NAKs here, reads are blocked and no
# amount of retrying will help without addressing the NAK.

sudo "$BIN" --loader "$LOADER" --memory UFS --loglevel Debug \
     printgpt --lun "$LUN" 2>&1 | tee phase3_gpt.log

if grep -q 'value="NAK"' phase3_gpt.log; then
    echo
    echo "!!!! CONFIGURE WAS NAK'd. Storage init refused."
    echo "!!!! Note the code= value and stop. See NOTES at end of file."
    exit 1
fi

grep -qi 'abl_a' phase3_gpt.log || die "abl_a not found in GPT output"
echo
echo "[*] GPT read OK. Verify above that:"
echo "      abl_a  start sector 98310, 256 sectors"
echo "      abl_b  start sector 458038, 256 sectors"

# ---------------------------------------------------------------------------
hr "PHASE 4  --  BACKUP BOTH SLOTS (read-only, no risk)"
# ---------------------------------------------------------------------------

echo "[*] Dumping abl_b (untouched stock reference)..."
sudo "$BIN" --loader "$LOADER" --memory UFS \
     read-part abl_b abl_b_stock.bin --lun "$LUN" 2>&1 | tee phase4_read_b.log
[ -f abl_b_stock.bin ] || die "abl_b dump did not produce a file"

echo
echo "[*] Dumping abl_a (the damaged slot, for the record)..."
sudo "$BIN" --loader "$LOADER" --memory UFS \
     read-part abl_a abl_a_broken.bin --lun "$LUN" 2>&1 | tee phase4_read_a.log

echo
ls -la abl_a_broken.bin abl_b_stock.bin 2>/dev/null
sudo chown "$USER":"$USER" abl_a_broken.bin abl_b_stock.bin 2>/dev/null

# ---------------------------------------------------------------------------
hr "PHASE 5  --  IDENTIFY THE CORRECT IMAGE"
# ---------------------------------------------------------------------------
# abl.elf and abl.img differ in 225,575 of 278,328 bytes -- they are DIFFERENT
# builds. Only one (at most) matches this device. abl_b is ground truth.

echo "[*] abl_b header (expect 7f 45 4c 46 = ELF):"
head -c 4 abl_b_stock.bin | od -A n -t x1

echo
echo "[*] Comparing abl_b against candidates:"
WINNER=""
for f in abl.elf abl.img; do
    if [ -f "$f" ] && cmp -s -n "$CMPLEN" abl_b_stock.bin "$f"; then
        echo "    >>> MATCH: $f is this device's ABL build"
        WINNER="$f"
    elif [ -f "$f" ]; then
        echo "        no match: $f"
    fi
done

if [ -z "$WINNER" ]; then
    echo
    echo "    Neither file matches abl_b."
    echo "    ==> USE abl_b_stock.bin ITSELF as the write source."
    echo "        It is this device's own known-good ABL."
    WINNER="abl_b_stock.bin"
fi

echo
echo "[*] Is abl_a actually damaged? (abl_a vs abl_b)"
if cmp -s -n "$CMPLEN" abl_a_broken.bin abl_b_stock.bin; then
    echo "    abl_a and abl_b are IDENTICAL -- abl_a may not be the fault."
    echo "    STOP and reassess before writing."
else
    echo "    abl_a differs from abl_b, consistent with the bad flash."
fi

# ---------------------------------------------------------------------------
hr "PHASE 6  --  STOP. WRITE IS MANUAL."
# ---------------------------------------------------------------------------

cat <<EOF

Recommended write source: $WINNER

The loader is still resident. Run the write NOW, in this same session,
without unplugging:

  cd $WORK
  sudo $BIN \\
    --loader $LOADER \\
    --memory UFS write-part abl_a $WINNER --lun $LUN

If it rejects on size, pad to the exact partition size and retry:

  cp $WINNER abl_a_write.bin
  truncate -s $PARTSIZE abl_a_write.bin
  sudo $BIN \\
    --loader $LOADER \\
    --memory UFS write-part abl_a abl_a_write.bin --lun $LUN

VERIFY before rebooting:

  sudo $BIN \\
    --loader $LOADER \\
    --memory UFS read-part abl_a abl_a_after.bin --lun $LUN
  cmp -n $CMPLEN abl_a_after.bin $WINNER && echo "VERIFIED"

Only once VERIFIED prints, reset:

  sudo $BIN --loader $LOADER reset

EOF

hr "END OF AUTOMATED PHASES"
exit 0

# ===========================================================================
# NOTES
# ===========================================================================
#
# IF CONFIGURE IS NAK'd (code="0x900000e"):
#   Storage init was refused by OPPO's programmer. Try, one per session
#   (power-cycle between each):
#       --maxpayload 1048576
#       --maxpayload 262144
#       --maxpayload 32768
#       --maxpayload 8192
#   If the code never changes, this is authenticated-host enforcement and
#   is not something the host side can work around.
#
# IF THE XML PARSER CRASHES ON 'msg' TOKEN:
#   OPPO's programmer emits malformed XML: code="0x..."msg=" " with no space
#   between attributes. edl-ng's strict parser throws. Fix in
#   QCEDL.NET/Layers/APSS/Firehose/QualcommFirehose.cs -- insert a space
#   before an attribute name that immediately follows a closing quote,
#   before handing the string to the XML parser, then `dotnet build -c Release`.
#
# IF WRITE RETURNS smc_status = 0xfffffffe:
#   VIP / authenticated-write enforcement. Direct abl_a restore is blocked.
#   Fallback: flip the active slot to B via GPT partition attributes so the
#   device boots stock ABL from slot B, reaches fastbootd, and abl_a can be
#   fixed from there. Requires reading LUN 4 GPT, editing the priority/
#   successful/unbootable bits, recomputing header + array CRC32, writing
#   back. Take a full `read-lun` backup of LUN 4 first.
#
# IF THE DEVICE DROPS OFF MID-SESSION:
#   Almost always low battery. Charge on a wall charger for 2+ hours.
#   A device that enumerates, answers once, then vanishes is browning out.
