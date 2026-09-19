#!/usr/bin/env bash
#
# EDL ABL Recovery Runbook  --  OPPO Find X9 Ultra (CPH2841 / SM8850 "kaanapali")
#
# PURPOSE: restore a corrupted ABL from official OPPO-signed firmware.
#
# CHANGES FROM THE PREVIOUS VERSION:
#   - No longer hardcodes the partition name "abl_a". The GPT dump from
#     Phase 3 is scanned for whatever ABL-named partition(s) actually exist
#     on this device, so it works whether the layout is a single "abl" or
#     an A/B "abl_a"/"abl_b" pair.
#   - ABL candidate image search now also accepts a bare "abl" file, not
#     just abl.elf/abl.img.
#   - Phase 2's "did Sahara actually succeed" check no longer trusts the
#     "Loader uploaded and started successfully via Sahara." line by
#     itself -- that line is also printed on a bare Sahara *timeout*,
#     which is NOT the same thing as a real completion. It's now paired
#     with a scan for Sahara-level error signatures (e.g.
#     ErrorHashTableAuthFailure) anywhere in the same log, and either one
#     failing kills the phase. This was seen to produce a false "success"
#     when an incompatible/unsigned-for-this-device image was substituted
#     into the loader set -- the real failure only surfaced later, in
#     Phase 3, as a misleading "abl_a not found in GPT output" message.
#
# Device facts established from the EDL package (rawprogram4.xml):
#   LUN                4   (physical_partition_number="4")
#   sector size        4096 bytes
#   (ABL start sectors are read dynamically from the GPT in Phase 3 --
#    see NOTES at the bottom for the last known values.)
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
grep -o 'image_path="[^"]*"' "$LOADER" | sed 's/image_path="//;s/"//' | while read -r p; do
    if [ -f "$p" ]; then echo "    OK      $p"; else echo "    MISSING $p"; fi
done
grep -o 'image_path="[^"]*"' "$LOADER" | sed 's/image_path="//;s/"//' | \
    while read -r p; do [ -f "$p" ] || exit 1; done || die "one or more loader images missing"

echo
echo "[*] Which file is serving as the Firehose loader (Sahara image, not the"
echo "    ABL) -- flag it if it isn't the known-good OPPO-signed one:"
LOADER_IMG=$(grep -o 'image_path="[^"]*prog_firehose[^"]*"\|image_path="[^"]*loader[^"]*"' "$LOADER" | head -1 | sed 's/image_path="//;s/"//')
if [ -n "$LOADER_IMG" ]; then
    echo "    $LOADER_IMG"
    if [[ "$LOADER_IMG" != *prog_firehose_ddr* ]]; then
        echo "    !! WARNING: this is NOT prog_firehose_ddr.elf. If it's a substitute"
        echo "       loader (e.g. loader.elf), be aware: a prior run confirmed that"
        echo "       file carries a generic QTI-only signature with no OPPO/OEM"
        echo "       signing or SoC binding at all, and swapping it in caused Sahara"
        echo "       to fail earlier (ErrorHashTableAuthFailure on the multi-image"
        echo "       manifest) than with the real loader. Recommended: use"
        echo "       prog_firehose_ddr.elf here unless testing something specific."
    fi
fi

echo
echo "[*] ABL candidate images (any of: abl, abl.img, abl.elf):"
ABL_CANDIDATES=()
for f in abl abl.img abl.elf; do
    if [ -f "$f" ]; then
        printf "    %-10s %8d bytes  sha256=%s\n" "$f" "$(stat -c%s "$f")" "$(sha256sum "$f" | cut -c1-16)"
        ABL_CANDIDATES+=("$f")
    else
        echo "    $f  not present"
    fi
done
[ "${#ABL_CANDIDATES[@]}" -gt 0 ] || die "no ABL candidate image found (looked for: abl, abl.img, abl.elf)"

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
# "Loader uploaded and started successfully via Sahara." AND no
# Sahara-level error signature anywhere in the log -- both conditions
# are required. A bare Sahara *timeout* can print the same "success"
# line without the transfer having actually completed; the error-pattern
# scan below is what catches that case.

sudo "$BIN" --loader "$LOADER" --loglevel Debug upload-loader 2>&1 | tee phase2_upload.log

SAHARA_ERROR_PATTERN='ErrorHashTableAuthFailure|Status Error|Handshake failed|RESET_STATE_MACHINE'
if grep -qE "$SAHARA_ERROR_PATTERN" phase2_upload.log; then
    echo
    echo "!!!! Sahara reported an error during upload (see above)."
    grep -E "$SAHARA_ERROR_PATTERN" phase2_upload.log
    die "Sahara-level authentication/handshake error -- this is NOT a successful upload even if a 'success' line also appears. If you swapped in a non-stock loader image, put the original (prog_firehose_ddr.elf) back and retry."
fi
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

if grep -qE "$SAHARA_ERROR_PATTERN" phase3_gpt.log; then
    die "Sahara/Firehose-level error surfaced in Phase 3 (see phase3_gpt.log) -- the device never actually reached a working Firehose session in Phase 2, despite what that phase reported."
fi

if grep -q 'value="NAK"' phase3_gpt.log; then
    echo
    echo "!!!! CONFIGURE WAS NAK'd. Storage init refused."
    echo "!!!! Note the code=/smc_status value and stop. See NOTES at end of file."
    exit 1
fi

echo
echo "[*] Detecting ABL partition name(s) from the GPT dump..."
mapfile -t ABL_PARTS < <(grep -oiE 'name:[[:space:]]*[a-z0-9_]*abl[a-z0-9_]*' phase3_gpt.log \
    | sed -E 's/^[Nn]ame:[[:space:]]*//' | sort -u)

if [ "${#ABL_PARTS[@]}" -eq 0 ]; then
    die "no partition matching *abl* found in GPT output -- check phase3_gpt.log by hand"
fi

echo "    Found: ${ABL_PARTS[*]}"

if [ "${#ABL_PARTS[@]}" -eq 1 ]; then
    ABL_TARGET="${ABL_PARTS[0]}"
    ABL_REFERENCE=""
    echo "    Single ABL partition (no A/B split detected): $ABL_TARGET"
elif [ "${#ABL_PARTS[@]}" -eq 2 ]; then
    # Heuristic: treat the lexicographically-first as the "target" (commonly
    # _a / slot 0) and the second as the known-good reference (_b / slot 1).
    # VERIFY this matches your device's actual active/other slot before
    # trusting it for anything beyond a read-only backup.
    ABL_TARGET="${ABL_PARTS[0]}"
    ABL_REFERENCE="${ABL_PARTS[1]}"
    echo "    A/B pair detected. Target (to inspect/restore): $ABL_TARGET"
    echo "                        Reference (known-good?):    $ABL_REFERENCE"
    echo "    Double-check against phase3_gpt.log which slot is actually active"
    echo "    before treating either side as ground truth."
else
    echo "    More than 2 matches -- inspect phase3_gpt.log manually:"
    printf '      %s\n' "${ABL_PARTS[@]}"
    die "ambiguous ABL partition set, needs manual review"
fi

# ---------------------------------------------------------------------------
hr "PHASE 4  --  BACKUP THE ABL PARTITION(S) (read-only, no risk)"
# ---------------------------------------------------------------------------

if [ -n "$ABL_REFERENCE" ]; then
    echo "[*] Dumping $ABL_REFERENCE (assumed untouched reference slot)..."
    sudo "$BIN" --loader "$LOADER" --memory UFS \
         read-part "$ABL_REFERENCE" abl_reference_stock.bin --lun "$LUN" 2>&1 | tee phase4_read_reference.log
    [ -f abl_reference_stock.bin ] || die "$ABL_REFERENCE dump did not produce a file"
fi

echo
echo "[*] Dumping $ABL_TARGET (the target/damaged slot, for the record)..."
sudo "$BIN" --loader "$LOADER" --memory UFS \
     read-part "$ABL_TARGET" abl_target_current.bin --lun "$LUN" 2>&1 | tee phase4_read_target.log

echo
ls -la abl_target_current.bin abl_reference_stock.bin 2>/dev/null
sudo chown "$USER":"$USER" abl_target_current.bin abl_reference_stock.bin 2>/dev/null

# ---------------------------------------------------------------------------
hr "PHASE 5  --  IDENTIFY THE CORRECT IMAGE"
# ---------------------------------------------------------------------------

REFFILE=""
[ -f abl_reference_stock.bin ] && REFFILE="abl_reference_stock.bin"

if [ -n "$REFFILE" ]; then
    echo "[*] $REFFILE header (expect 7f 45 4c 46 = ELF):"
    head -c 4 "$REFFILE" | od -A n -t x1

    echo
    echo "[*] Comparing $REFFILE against candidates:"
    WINNER=""
    for f in "${ABL_CANDIDATES[@]}"; do
        if cmp -s -n "$CMPLEN" "$REFFILE" "$f"; then
            echo "    >>> MATCH: $f is this device's ABL build"
            WINNER="$f"
        else
            echo "        no match: $f"
        fi
    done

    if [ -z "$WINNER" ]; then
        echo
        echo "    None of the candidate files match $REFFILE."
        echo "    ==> USE $REFFILE ITSELF as the write source."
        echo "        It is this device's own known-good ABL."
        WINNER="$REFFILE"
    fi

    echo
    echo "[*] Is $ABL_TARGET actually damaged? ($ABL_TARGET vs $REFFILE)"
    if cmp -s -n "$CMPLEN" abl_target_current.bin "$REFFILE"; then
        echo "    $ABL_TARGET and $REFFILE are IDENTICAL -- $ABL_TARGET may not be the fault."
        echo "    STOP and reassess before writing."
    else
        echo "    $ABL_TARGET differs from $REFFILE, consistent with the bad flash."
    fi
else
    echo "[*] No reference slot available (single-ABL layout) -- comparing"
    echo "    candidates directly against the current on-device image instead."
    WINNER=""
    for f in "${ABL_CANDIDATES[@]}"; do
        if cmp -s -n "$CMPLEN" abl_target_current.bin "$f"; then
            echo "    >>> $f already matches what's on the device."
        else
            echo "        differs from device: $f"
            WINNER="$f"
        fi
    done
    [ -n "$WINNER" ] || WINNER="${ABL_CANDIDATES[0]}"
fi

# ---------------------------------------------------------------------------
hr "PHASE 6  --  STOP. WRITE IS MANUAL."
# ---------------------------------------------------------------------------

cat <<EOF

Target partition:     $ABL_TARGET
Recommended write source: $WINNER

The loader is still resident. Run the write NOW, in this same session,
without unplugging:

  cd $WORK
  sudo $BIN \\
    --loader $LOADER \\
    --memory UFS write-part $ABL_TARGET $WINNER --lun $LUN

If it rejects on size, pad to the exact partition size (read the actual
size for $ABL_TARGET from phase3_gpt.log -- do not assume 1 MiB) and retry:

  cp $WINNER abl_write.bin
  truncate -s <PARTITION_SIZE_FROM_GPT> abl_write.bin
  sudo $BIN \\
    --loader $LOADER \\
    --memory UFS write-part $ABL_TARGET abl_write.bin --lun $LUN

VERIFY before rebooting:

  sudo $BIN \\
    --loader $LOADER \\
    --memory UFS read-part $ABL_TARGET abl_after.bin --lun $LUN
  cmp -n $CMPLEN abl_after.bin $WINNER && echo "VERIFIED"

Only once VERIFIED prints, reset:

  sudo $BIN --loader $LOADER reset

EOF

hr "END OF AUTOMATED PHASES"
exit 0

# ===========================================================================
# NOTES
# ===========================================================================
#
# Last known GPT facts for this device (rawprogram4.xml, LUN 4, sector size
# 4096 bytes) -- re-verify against phase3_gpt.log each run rather than
# trusting these blindly, that's the whole point of the dynamic detection
# added above:
#   abl_a   start_sector 98310,  256 sectors (1 MiB)
#   abl_b   start_sector 458038, 256 sectors (1 MiB)
#
# IF CONFIGURE IS NAK'd (code="0x900000e" or a VIP/smc_status error):
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
#   Some programmers emit malformed XML: code="0x..."msg=" " with no space
#   between attributes. edl-ng's strict parser throws. Fix in
#   QCEDL.NET/Layers/APSS/Firehose/QualcommFirehose.cs -- insert a space
#   before an attribute name that immediately follows a closing quote,
#   before handing the string to the XML parser, then `dotnet build -c Release`.
#
# IF SAHARA FAILS WITH ErrorHashTableAuthFailure ON A DIFFERENT IMAGE THAN
# THE ONE YOU CHANGED:
#   This has been confirmed to happen when one image in the 8-file set
#   (multi_image_qti.mbn in particular) acts as a manifest/hash-table
#   cross-checking the whole set. Substituting any image with content that
#   doesn't match what that manifest expects (verified: swapping in a
#   generic, non-OPPO-signed loader.elf in place of prog_firehose_ddr.elf)
#   causes the *manifest's* image to fail auth, not necessarily the file
#   you actually changed. Treat this as "the substituted file is not
#   trusted for this device," not as a transient glitch -- revert to the
#   original, known-good image.
#
# IF WRITE RETURNS smc_status = 0xfffffffe:
#   VIP / authenticated-write enforcement. Direct ABL restore via Firehose
#   is blocked at the secure-world level, independent of which loader or
#   command is used -- this has been confirmed to fire during Configure
#   itself, before any read/write command is even sent. No slot-flip or
#   loader substitution has been found to get past it; see the project
#   notes for the full investigation.
#
# IF THE DEVICE DROPS OFF MID-SESSION:
#   Almost always low battery. Charge on a wall charger for 2+ hours.
#   A device that enumerates, answers once, then vanishes is browning out.
