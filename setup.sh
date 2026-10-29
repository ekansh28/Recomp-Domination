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

if [ ! -d PS2Recomp ]; then
  git clone --recurse-submodules https://github.com/ran-j/PS2Recomp
  git -C PS2Recomp checkout -q 2c5fbb9   # commit em que patches/ aplica limpo
  git -C PS2Recomp apply ../patches/ps2recomp-runtime-env.patch  # PS2X_CD_IMAGE e PS2X_BINDS
fi
cmake -S PS2Recomp -B PS2Recomp/out/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS=-march=native
cmake --build PS2Recomp/out/build
