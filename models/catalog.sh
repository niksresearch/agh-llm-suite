#!/usr/bin/env bash
# Model catalog — sourced by startup.sh
#
# All tags use Ollama native registry (ollama.com/library) — no HF auth redirects.
# GPU tiers → categories → top models, ordered best-first.

# ---------------------------------------------------------------------------
# detect_gpu_tier
#
# Reads nvidia-smi, sets:
#   DETECTED_TIER_IDX   — index into GPU_TIER_NAMES
#   DETECTED_GPU_LABEL  — human-readable detected config
# ---------------------------------------------------------------------------
detect_gpu_tier() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "WARNING: nvidia-smi not found — defaulting to A100 40GB tier." >&2
    DETECTED_TIER_IDX=0
    DETECTED_GPU_LABEL="Unknown (nvidia-smi missing)"
    return
  fi

  local gpu_name gpu_vram_mb gpu_count
  gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | xargs)
  gpu_vram_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | xargs)
  gpu_count=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l | xargs)

  gpu_vram_mb="${gpu_vram_mb:-0}"
  gpu_count="${gpu_count:-1}"

  if [ "$gpu_count" -ge 8 ]; then
    if echo "$gpu_name" | grep -qi "H200"; then
      DETECTED_TIER_IDX=5
    else
      DETECTED_TIER_IDX=4
    fi
  elif [ "$gpu_count" -ge 4 ]; then
    DETECTED_TIER_IDX=3
  elif echo "$gpu_name" | grep -qi "H100"; then
    DETECTED_TIER_IDX=2
  elif echo "$gpu_name" | grep -qi "A100"; then
    if [ "$gpu_vram_mb" -gt 50000 ]; then
      DETECTED_TIER_IDX=1   # A100 80GB
    else
      DETECTED_TIER_IDX=0   # A100 40GB
    fi
  else
    DETECTED_TIER_IDX=0     # unknown — conservative fallback
  fi

  DETECTED_GPU_LABEL="${gpu_count}× ${gpu_name} ($(( gpu_vram_mb * gpu_count / 1024 )) GB total)"
}

# ---------------------------------------------------------------------------
# GPU tier display names (index = tier_idx passed to load_models_for_tier)
# ---------------------------------------------------------------------------
GPU_TIER_NAMES=(
  "1× A100 40GB"
  "1× A100 80GB"
  "1× H100 80GB"
  "4× H100  (320 GB)"
  "8× H100  (640 GB)"
  "8× H200  (1,128 GB)"
)

# ---------------------------------------------------------------------------
# load_models_for_tier <tier_idx> [category]
#
# Populates parallel arrays:
#   MODEL_NAMES, MODEL_TAGS, MODEL_BEST_FOR, MODEL_SIZE, MODEL_LICENSE
#
# category = "Coding" | "Reasoning" | "All"  (default: "All")
# ---------------------------------------------------------------------------
load_models_for_tier() {
  local tier_idx="$1"
  local category="${2:-All}"

  MODEL_NAMES=()
  MODEL_TAGS=()
  MODEL_BEST_FOR=()
  MODEL_SIZE=()
  MODEL_LICENSE=()

  case "$tier_idx" in

    0) # ── 1× A100 40GB ──────────────────────────────────────────────────
      MODEL_NAMES=(
        "Gemma 3 27B"
        "Qwen3 32B"
        "DeepSeek R1 32B"
        "Llama 3.3 70B"
        "Phi-4 14B"
      )
      MODEL_TAGS=(
        "gemma3:27b"
        "qwen3:32b"
        "deepseek-r1:32b"
        "llama3.3:70b"
        "phi4"
      )
      MODEL_BEST_FOR=(
        "General · Chat · Summarization · Instructions"
        "Coding · Debugging · Logic · Code Review"
        "Reasoning · Math · Science · Step-by-step"
        "Best overall quality · Complex tasks (uses full VRAM)"
        "Fast responses · Balanced quality · Low latency"
      )
      MODEL_SIZE=("~16 GB" "~20 GB" "~20 GB" "~40 GB" "~9 GB")
      MODEL_LICENSE=("Gemma" "Apache 2.0" "MIT" "Llama" "MIT")
      ;;

    1) # ── 1× A100 80GB ──────────────────────────────────────────────────
      if [ "$category" = "Coding" ]; then
        MODEL_NAMES=(
          "Qwen2.5 Coder 72B  (Rank 1)"
          "Llama 3.3 70B      (Rank 2)"
        )
        MODEL_TAGS=(
          "qwen2.5-coder:72b"
          "llama3.3:70b"
        )
        MODEL_BEST_FOR=(
          "Coding · Code Review · Debugging · 72B coding specialist"
          "Coding · General · Instructions · 70B best overall"
        )
        MODEL_SIZE=("72B dense  ~41 GB" "70B dense  ~40 GB")
        MODEL_LICENSE=("Apache 2.0" "Llama")
      else
        MODEL_NAMES=(
          "DeepSeek R1 70B  (Rank 1)"
          "Qwen3 32B        (Rank 2)"
        )
        MODEL_TAGS=(
          "deepseek-r1:70b"
          "qwen3:32b"
        )
        MODEL_BEST_FOR=(
          "Reasoning · Math · Science · 70B distill"
          "Reasoning · Logic · Coding · Fast inference"
        )
        MODEL_SIZE=("70B dense  ~40 GB" "32B dense  ~20 GB")
        MODEL_LICENSE=("MIT" "Apache 2.0")
      fi
      ;;

    2) # ── 1× H100 80GB — same VRAM as A100 80GB, better throughput ─────
      if [ "$category" = "Coding" ]; then
        MODEL_NAMES=(
          "Qwen2.5 Coder 72B  (Rank 1)"
          "Llama 3.3 70B      (Rank 2)"
        )
        MODEL_TAGS=(
          "qwen2.5-coder:72b"
          "llama3.3:70b"
        )
        MODEL_BEST_FOR=(
          "Coding · Code Review · Debugging · 72B coding specialist"
          "Coding · General · Instructions · 70B best overall"
        )
        MODEL_SIZE=("72B dense  ~41 GB" "70B dense  ~40 GB")
        MODEL_LICENSE=("Apache 2.0" "Llama")
      else
        MODEL_NAMES=(
          "DeepSeek R1 70B  (Rank 1)"
          "Qwen3 32B        (Rank 2)"
        )
        MODEL_TAGS=(
          "deepseek-r1:70b"
          "qwen3:32b"
        )
        MODEL_BEST_FOR=(
          "Reasoning · Math · Science · 70B distill"
          "Reasoning · Logic · Coding · Fast inference"
        )
        MODEL_SIZE=("70B dense  ~40 GB" "32B dense  ~20 GB")
        MODEL_LICENSE=("MIT" "Apache 2.0")
      fi
      ;;

    3) # ── 4× H100 (320 GB) ─────────────────────────────────────────────
      MODEL_NAMES=(
        "Llama 3.1 405B  (Rank 1 — Coding + Reasoning)"
        "DeepSeek R1 671B (Rank 2 — Reasoning)"
      )
      MODEL_TAGS=(
        "llama3.1:405b"
        "deepseek-r1:671b"
      )
      MODEL_BEST_FOR=(
        "Best overall quality · Instructions · 405B dense"
        "Reasoning · Math · Science · 671B distill Q4"
      )
      MODEL_SIZE=("405B dense  ~230 GB" "671B dense  ~403 GB")
      MODEL_LICENSE=("Llama" "MIT")
      ;;

    4) # ── 8× H100 (640 GB) ─────────────────────────────────────────────
      MODEL_NAMES=(
        "DeepSeek R1 671B  (Rank 1 — Reasoning)"
        "Llama 3.1 405B    (Rank 2 — Coding + General)"
      )
      MODEL_TAGS=(
        "deepseek-r1:671b"
        "llama3.1:405b"
      )
      MODEL_BEST_FOR=(
        "Reasoning · Math · Science · 671B full Q4"
        "Coding · General · Instructions · 405B dense"
      )
      MODEL_SIZE=("671B dense  ~403 GB" "405B dense  ~230 GB")
      MODEL_LICENSE=("MIT" "Llama")
      ;;

    5) # ── 8× H200 (1,128 GB) ───────────────────────────────────────────
      MODEL_NAMES=(
        "DeepSeek R1 671B  (Rank 1 — Reasoning)"
        "Llama 3.1 405B    (Rank 2 — Coding + General)"
      )
      MODEL_TAGS=(
        "deepseek-r1:671b"
        "llama3.1:405b"
      )
      MODEL_BEST_FOR=(
        "Reasoning · Math · Science · 671B full Q4 (run Q8 for best quality)"
        "Coding · General · Instructions · 405B dense Q8"
      )
      MODEL_SIZE=("671B dense  ~403 GB Q4 / ~670 GB Q8" "405B dense  ~230 GB Q4 / ~430 GB Q8")
      MODEL_LICENSE=("MIT" "Llama")
      ;;

  esac
}
