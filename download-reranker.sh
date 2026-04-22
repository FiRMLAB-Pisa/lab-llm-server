#!/bin/bash
# Download HuggingFace model using curl --insecure to bypass SSL verification
# Stores in ~/.cache/huggingface/hub/ structure so sentence_transformers finds it

set -euo pipefail

REPO="cross-encoder/ms-marco-MiniLM-L6-v2"
MODEL_DIR="${HOME}/.cache/huggingface/hub/models--cross-encoder--ms-marco-MiniLM-L6-v2"
REVISION="main"

echo "Downloading ${REPO} to ${MODEL_DIR}..."
mkdir -p "${MODEL_DIR}"

# List of typical model files to download
FILES=(
    "config.json"
    "tokenizer.json"
    "tokenizer_config.json"
    "special_tokens_map.json"
    "pytorch_model.bin"
    "model.safetensors"
)

for file in "${FILES[@]}"; do
    URL="https://huggingface.co/${REPO}/resolve/${REVISION}/${file}"
    OUTPUT="${MODEL_DIR}/${file}"
    
    # Skip if already downloaded
    if [[ -f "${OUTPUT}" ]]; then
        echo "  ✓ ${file} (already present)"
        continue
    fi
    
    echo "  Downloading ${file}..."
    if curl --insecure -fsSL "${URL}" -o "${OUTPUT}" 2>/dev/null; then
        echo "    ✓ ${file}"
    else
        echo "    ✗ ${file} (skipping, may not exist)"
        rm -f "${OUTPUT}"
    fi
done

echo ""
echo "Model files downloaded to: ${MODEL_DIR}"
echo "Cache directory contents:"
ls -lh "${MODEL_DIR}"
echo ""
echo "To transfer to aleatico2:"
echo "  scp -r ${MODEL_DIR} root@aleatico2:/root/.cache/huggingface/hub/"
