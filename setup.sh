#!/usr/bin/env bash
# Instala dependências, extrai o ELF da ISO e compila o PS2Recomp.
set -euo pipefail
cd "$(dirname "$0")"

ISO="Downhill Domination (USA)/Downhill Domination (USA).iso"
ELF=SCUS_971.77

sudo pacman -S --needed base-devel git cmake ninja clang python 7zip ghidra sdl2 vulkan-headers glslang

# o runtime lê módulos IRX e dados do disco a partir desta pasta.
# A extração precisa estar completa: uma pasta game/ parcial (por exemplo sem
# IOPRP270.IMG, que fica na raiz da ISO) passa na checagem do ELF e deixa a
# imagem do IOP sem carregar. Por isso conferimos também os outros arquivos
# da raiz, e reextraímos se faltar algum.
ROOT_FILES=("$ELF" SYSTEM.CNF IOPRP270.IMG)
need_extract=0
for f in "${ROOT_FILES[@]}"; do
  [ -f "game/$f" ] || need_extract=1
done
if [ "$need_extract" = 1 ]; then
  rm -rf game
  mkdir -p game
  7z x -y -ogame "$ISO"
fi
for f in "${ROOT_FILES[@]}"; do
  [ -f "game/$f" ] || { echo "erro: game/$f não foi extraído da ISO" >&2; exit 1; }
done

# A imagem do IOP é um contêiner com os módulos do kernel em sequência (ELF).
# O runtime carrega cada um no IOP emulado, para os serviços de verdade
# (fileio, cdvdman, ioman, ...) responderem no lugar dos stubs HLE.
IOP_NAMES=(loadcore sifcmd sifman threadman ioman modload fileio cdvdman
           cdvdfsv loadfile timemani romdrv eesync sysclib stdio)
python3 - game/IOPRP270.IMG game/iopmod "${IOP_NAMES[@]}" <<'PY'
import pathlib, sys

source = pathlib.Path(sys.argv[1]).read_bytes()
destination = pathlib.Path(sys.argv[2])
names = sys.argv[3:]

magic = b"\x7fELF"
offsets = [i for i in range(len(source) - 4) if source[i:i + 4] == magic]
if not offsets:
    raise SystemExit("erro: nenhum módulo ELF encontrado em " + sys.argv[1])

destination.mkdir(parents=True, exist_ok=True)
for index, start in enumerate(offsets):
    end = offsets[index + 1] if index + 1 < len(offsets) else len(source)
    name = names[index] if index < len(names) else f"mod{index}"
    (destination / f"{index:02d}_{name}.elf").write_bytes(source[start:end])
print(f"iopmod: {len(offsets)} módulos extraídos para {destination}")
PY

if [ ! -d PS2Recomp ]; then
  git clone --recurse-submodules https://github.com/ran-j/PS2Recomp
  git -C PS2Recomp checkout -q 2c5fbb9   # commit em que patches/ aplica limpo
  git -C PS2Recomp apply ../patches/ps2recomp-runtime-env.patch  # PS2X_CD_IMAGE e PS2X_BINDS
fi
cmake -S PS2Recomp -B PS2Recomp/out/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS=-march=native
cmake --build PS2Recomp/out/build
