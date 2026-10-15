#!/usr/bin/env bash
# Make an engine-only, PKG-focused Quake II PS3 source tree.
set -Eeuo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: run from a Quake II PS3 git checkout." >&2
  exit 2
}
cd "$ROOT"
for required in Makefile.ps3 src/backends/ps3/system.c src/common/frame_ps3.c; do
  [[ -f "$required" ]] || { echo "ERROR: missing $required" >&2; exit 2; }
done
[[ -z "$(git status --porcelain)" ]] || {
  echo "ERROR: refuse to patch a dirty checkout." >&2
  exit 2
}

python3 - <<'PY'
from pathlib import Path
import shutil

root = Path(".")
def replace_once(name, old, new):
    p = root / name
    data = p.read_text(encoding="utf-8")
    count = data.count(old)
    if count != 1:
        raise SystemExit(f"{name}: expected exactly one patch anchor, found {count}: {old[:80]!r}")
    p.write_text(data.replace(old, new, 1), encoding="utf-8")

replace_once(
    "src/backends/ps3/system.c",
    "#include <sysutil/osk.h>\n#include <sysutil/sysutil.h>",
    "#include <sysutil/osk.h>\n#include <sysutil/msg.h>\n#include <sysutil/sysutil.h>",
)

missing_data = r'''
/* Use a native PS3 dialog because renderer fonts may be inside the missing PAKs. */
static volatile qboolean ps3_missing_data_dialog_finished = false;

static void
Sys_PS3_MissingDataDialogCallback(msgButton button, void *userdata)
{
    (void)userdata;
    if (button != MSG_DIALOG_BTN_INVALID)
        ps3_missing_data_dialog_finished = true;
}

void
Sys_PS3_ShowMissingGameDataWarning(void)
{
    struct stat pak_stat;
    static const char *pak_path =
        "/dev_hdd0/game/QUAKE2000/USRDIR/baseq2/pak0.pak";
    static const char *warning =
        "Quake II game data was not found.\n\n"
        "This PKG contains the engine only. Copy legally acquired Quake II\n"
        "baseq2 PAK files to:\n"
        "/dev_hdd0/game/QUAKE2000/USRDIR/baseq2/\n\n"
        "Close this message and launch the game again.";
    s32 dialog_result;

    if (stat(pak_path, &pak_stat) == 0 && S_ISREG(pak_stat.st_mode) &&
        pak_stat.st_size > 0)
        return;

    Sys_BootTrace("startup: pak0.pak missing; showing data warning", false);
    if (ps3_sysutil_registered)
    {
        ps3_missing_data_dialog_finished = false;
        dialog_result = msgDialogOpen2(
            (msgType)(MSG_DIALOG_NORMAL | MSG_DIALOG_BTN_TYPE_OK),
            warning, Sys_PS3_MissingDataDialogCallback, NULL, NULL);
        if (dialog_result == SYSUTIL_OK)
        {
            while (!ps3_missing_data_dialog_finished && !ps3_exit_requested)
            {
                (void)sysUtilCheckCallback();
                Sys_Nanosleep(1000000);
            }
            (void)msgDialogAbort();
        }
        else
        {
            Sys_BootTrace("startup: missing-data dialog failed to open", false);
        }
    }

    Sys_BootTrace("startup: exiting because game data is absent", false);
    Sys_PS3_UnregisterCallback();
    exit(0);
}

'''
replace_once(
    "src/backends/ps3/system.c",
    "// ---------------------------------------------\n//  Input/Output\n// ---------------------------------------------",
    missing_data + "// ---------------------------------------------\n//  Input/Output\n// ---------------------------------------------",
)
replace_once(
    "src/common/header/common.h",
    "void Sys_BootTrace(const char *stage, qboolean reset);\n",
    "void Sys_BootTrace(const char *stage, qboolean reset);\nvoid Sys_PS3_ShowMissingGameDataWarning(void);\n",
)
replace_once(
    "src/common/frame_ps3.c",
    'Sys_Init();\n\tPS3_BOOT_TRACE("Qcommon_Init: before NET_Init");',
    'Sys_Init();\n\tSys_PS3_ShowMissingGameDataWarning();\n\tPS3_BOOT_TRACE("Qcommon_Init: before NET_Init");',
)

makefile = root / "Makefile.ps3"
data = makefile.read_text(encoding="utf-8")
for anchor in (
    "PS3_DISC_BUILD ?= 0\n",
    "ifeq ($(PS3_DISC_BUILD),1)\nCFLAGS += -DPS3_DISC_BUILD\nendif\n",
):
    count = data.count(anchor)
    if count != 1:
        raise SystemExit(f"Makefile.ps3: expected exactly one disc/ISO switch, found {count}")
    data = data.replace(anchor, "", 1)
# GCC 10+ defaults to -fno-common; this legacy Quake II code uses
# tentative global definitions that must be merged as common symbols.
marker = "CFLAGS = -O2 -Wall -std=gnu99"
if data.count(marker) != 1:
    raise SystemExit("Makefile.ps3: could not find the unique base CFLAGS assignment")
data = data.replace(marker, marker + " -fcommon", 1)
makefile.write_text(data, encoding="utf-8")

(root / "README.md").write_text("""# Quake II PS3 — engine-only homebrew build

This source build does not distribute commercial Quake II game data, original
game artwork, release binaries, or an ISO workflow.

The generated PKG contains the engine only; it does not include PAK files.
Before renderer startup, the executable checks for baseq2/pak0.pak. If missing,
a native PS3 dialog explains where to install legally acquired game data and
the application exits.

Copy your own Quake II base-game PAK files to:
/dev_hdd0/game/QUAKE2000/USRDIR/baseq2/

The source retains its upstream licensing. Quake II trademarks and commercial
game data remain the property of their respective owners.
""", encoding="utf-8")

(root / "docs/BUILDING.md").write_text("""# Build the engine-only PS3 PKG

Use Bucanero's precompiled PS3DEV/PSL1GHT toolchain. No ISO is built.

Set PS3DEV, PSL1GHT, PORTLIBS, and PATH, then run:

    make -f Makefile.ps3 -j1 BUILD=build-rsx TARGET=q2ps3 \\
      'TITLE=Quake II PS3 (game data required)' APPID=QUAKE2000 \\
      CONTENTID=UP0001-QUAKE2000_00-0000000000000000 \\
      ICON0=$PS3DEV/bin/ICON0.PNG PKGFILES= \\
      PS3_NATIVE_RSX=1 PS3_CAMERA=0 PS3_MOVE=0 \\
      PS3_V198_OSK_RECOVERY=1 PS3_FORCE_FONT_SAMPLER_PER_DRAW=1 \\
      PS3_USB_INPUT_BRIDGE=0 PS3_POLYBLEND_2D_OVERRIDE=1 \\
      PS3_SCENE_SCALE_BRIDGE=1 PS3_SAFE_VIDEO=0 q2ps3.pkg

The build enables -fcommon for GCC 10+ compatibility. CI installs the official NVIDIA Cg Toolkit 3.1.0013 host compiler/runtime (checksum-verified) and builds with PS3_NATIVE_RSX=1, generating native RSX vertex/fragment shader binaries. Cg is a build-time dependency only and is not shipped in the PKG. The installable output is q2ps3.gnpdrm.pkg. The package must not contain PAK
files, baseq2, private EBOOTs, ISO trees, or commercial release payloads.
Physical-PS3 install/boot testing remains necessary after a successful build.
""", encoding="utf-8")

(root / "docs/INSTALLATION.md").write_text("""# Installation — engine-only PKG

Install q2ps3.gnpdrm.pkg using the PS3 package manager.

This package includes the engine but not game data. Copy legally acquired Quake
II base-game PAK files to:

    /dev_hdd0/game/QUAKE2000/USRDIR/baseq2/

If pak0.pak is absent or empty, a native PS3 warning appears and the game exits.
This cleaned distribution does not support an ISO workflow.
""", encoding="utf-8")

# Remove game branding, distribution payloads, and old PKG/ISO metadata.
for item in (
    "release-assets", "branding", "stuff/icon", "stuff/models/crosshair",
    "stuff/mapfixes", "stuff/osx/quake2-appbundle.zip",
    "param-v221-full.xml", "param-v221-iso.xml",
):
    p = root / item
    if p.is_dir():
        shutil.rmtree(p)
    elif p.exists():
        p.unlink()

for p in list(root.rglob("*")):
    if ".git" in p.parts or not p.is_file():
        continue
    low = p.name.lower()
    if p.suffix.lower() in {".pak", ".pkg", ".iso"} or low.endswith(".gnpdrm.pkg"):
        p.unlink()
PY

if find . -path './.git' -prune -o -type f \( -iname '*.pak' -o -iname '*.iso' -o -iname '*.pkg' -o -iname '*.gnpdrm.pkg' \) -print | grep -q .; then
  echo "ERROR: a commercial payload or old package remains in the cleaned source tree." >&2
  exit 1
fi
git diff --check
printf 'Engine-only cleanup applied. Review with: git diff --stat && git diff\n'
