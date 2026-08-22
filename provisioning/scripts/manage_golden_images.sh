#!/usr/bin/env bash
# ceph-lab — manage_golden_images.sh
# List or prune local Lima golden images built by build_golden_image.sh.
set -euo pipefail

IMAGES_DIR="${HOME}/.lima-images"
ARCHIVE_DIR="${IMAGES_DIR}/archive"
ACTION="${1:-list}"

case "${ACTION}" in
    list)
        echo "Active golden images (referenced by lima-up.sh):"
        found=0
        for f in "${IMAGES_DIR}"/ceph-lab-golden-*.qcow2; do
            [ -f "${f}" ] || continue
            found=1
            printf "  %s  (%s)\n" "${f}" "$(du -h "${f}" | cut -f1)"
        done
        [ "${found}" -eq 0 ] && echo "  (none — run 'task bake-image')"
        echo ""
        echo "Archived builds:"
        found=0
        if [ -d "${ARCHIVE_DIR}" ]; then
            for f in "${ARCHIVE_DIR}"/*.qcow2; do
                [ -f "${f}" ] || continue
                found=1
                printf "  %s  (%s)\n" "${f}" "$(du -h "${f}" | cut -f1)"
            done
        fi
        [ "${found}" -eq 0 ] && echo "  (none)"
        ;;
    prune)
        [ -d "${ARCHIVE_DIR}" ] || { echo "No archive directory; nothing to prune."; exit 0; }
        # Keep the newest archived copy per arch, delete the rest.
        for arch in aarch64 x86_64; do
            mapfile -t files < <(ls -t "${ARCHIVE_DIR}"/ceph-lab-golden-"${arch}"-*.qcow2 2>/dev/null || true)
            if [ "${#files[@]}" -le 1 ]; then
                continue
            fi
            for f in "${files[@]:1}"; do
                echo "  -> deleting ${f}"
                rm -f "${f}"
            done
        done
        echo "Prune complete."
        ;;
    *)
        echo "Usage: $0 [list|prune]" >&2
        exit 1
        ;;
esac
