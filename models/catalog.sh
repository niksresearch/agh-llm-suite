#!/usr/bin/env bash
# Model catalog — sourced by startup.sh
#
# GPU tiers → categories → top models
# Tags marked [VERIFY] need confirmation on HF/Ollama before first use.

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
        "Gemma 4 31B"
        "Qwen3 32B"
        "DeepSeek R1 32B"
        "Llama 3.3 70B"
        "Mistral Small 3.1 22B"
      )
      MODEL_TAGS=(
        "hf.co/unsloth/gemma-4-31B-it-GGUF:UD-Q4_K_XL"
        "hf.co/unsloth/Qwen3-32B-GGUF:UD-Q4_K_XL"
        "hf.co/unsloth/DeepSeek-R1-0528-Qwen3-32B-GGUF:UD-Q4_K_XL"
        "hf.co/unsloth/Llama-3.3-70B-Instruct-GGUF:UD-Q4_K_XL"
        "hf.co/unsloth/Mistral-Small-3.1-22B-Instruct-2503-GGUF:UD-Q4_K_XL"
      )
      MODEL_BEST_FOR=(
        "General · Chat · Summarization · Instructions"
        "Coding · Debugging · Logic · Code Review"
        "Reasoning · Math · Science · Step-by-step"
        "Best overall quality · Complex tasks (uses full VRAM)"
        "Fast responses · Balanced quality · Low latency"
      )
      MODEL_SIZE=("~22 GB" "~22 GB" "~22 GB" "~40 GB" "~14 GB")
      MODEL_LICENSE=("Gemma" "Apache 2.0" "MIT" "Llama" "Apache 2.0")
      ;;

    1) # ── 1× A100 80GB ──────────────────────────────────────────────────
      if [ "$category" = "Coding" ]; then
        MODEL_NAMES=(
          "DeepSeek V4 Flash  (Rank 1)"
          "Qwen3.5 122B A10B  (Rank 2)"
        )
        MODEL_TAGS=(
          "hf.co/unsloth/DeepSeek-V4-Flash-GGUF:Q4_K_M"           # [VERIFY]
          "hf.co/unsloth/Qwen3.5-122B-A10B-Instruct-GGUF:Q4_K_M"  # [VERIFY]
        )
        MODEL_BEST_FOR=(
          "Coding · Fast inference · MoE 284B / 13B active"
          "Coding · Logic · MoE 122B / 10B active"
        )
        MODEL_SIZE=("284B MoE  ~40–50 GB" "122B MoE  ~40 GB")
        MODEL_LICENSE=("MIT" "Apache 2.0")
      else
        MODEL_NAMES=(
          "DeepSeek R1 Distill Llama 70B  (Rank 1)"
          "DeepSeek V3 heavy quant        (Rank 2)"
        )
        MODEL_TAGS=(
          "hf.co/unsloth/DeepSeek-R1-Distill-Llama-70B-GGUF:Q4_K_M"
          "hf.co/unsloth/DeepSeek-V3-GGUF:IQ2_XS"                  # [VERIFY quant]
        )
        MODEL_BEST_FOR=(
          "Reasoning · Math · Science · 70B dense"
          "Reasoning · Complex tasks · MoE 671B / 37B active"
        )
        MODEL_SIZE=("70B dense  ~40 GB" "671B MoE  ~70 GB heavy quant")
        MODEL_LICENSE=("MIT / Llama" "MIT")
      fi
      ;;

    2) # ── 1× H100 80GB ──────────────────────────────────────────────────
      if [ "$category" = "Coding" ]; then
        MODEL_NAMES=(
          "DeepSeek V4 Flash  (Rank 1)"
          "GPT-OSS 120B       (Rank 2)"
        )
        MODEL_TAGS=(
          "hf.co/unsloth/DeepSeek-V4-Flash-GGUF:Q4_K_M"  # [VERIFY]
          "hf.co/unsloth/GPT-OSS-120B-GGUF:Q4_K_M"       # [VERIFY]
        )
        MODEL_BEST_FOR=(
          "Coding · Fast · MoE 284B / 13B active"
          "Coding · General · 120B MoE"
        )
        MODEL_SIZE=("284B MoE  ~40–50 GB" "120B MoE  ~60 GB")
        MODEL_LICENSE=("MIT" "Apache 2.0")
      else
        MODEL_NAMES=(
          "Qwen3.5 122B A10B  (Rank 1)"
          "GPT-OSS 120B       (Rank 2)"
        )
        MODEL_TAGS=(
          "hf.co/unsloth/Qwen3.5-122B-A10B-Instruct-GGUF:Q4_K_M"  # [VERIFY]
          "hf.co/unsloth/GPT-OSS-120B-GGUF:Q4_K_M"                 # [VERIFY]
        )
        MODEL_BEST_FOR=(
          "Reasoning · Math · MoE 122B / 10B active"
          "Reasoning · General · 120B MoE"
        )
        MODEL_SIZE=("122B MoE  ~40 GB" "120B MoE  ~60 GB")
        MODEL_LICENSE=("Apache 2.0" "Apache 2.0")
      fi
      ;;

    3) # ── 4× H100 (320 GB) ──────────────────────────────────────────────
      MODEL_NAMES=(
        "GLM-4.7   (Rank 1 — Coding + Reasoning)"
        "Kimi K2.6 (Rank 2 — Coding + Reasoning)"
      )
      MODEL_TAGS=(
        "hf.co/unsloth/GLM-4.7-GGUF:Q4_K_M"      # [VERIFY]
        "hf.co/unsloth/Kimi-K2.6-GGUF:INT4"       # [VERIFY]
      )
      MODEL_BEST_FOR=(
        "Coding · Reasoning · MoE 355B / 32B active"
        "Coding · Reasoning · MoE 1T / 32B active"
      )
      MODEL_SIZE=("355B MoE  ~160 GB" "1T MoE  ~200 GB")
      MODEL_LICENSE=("MIT" "Modified MIT")
      ;;

    4) # ── 8× H100 (640 GB) ──────────────────────────────────────────────
      MODEL_NAMES=(
        "GLM-5.1      (Rank 1 — Coding + Reasoning)"
        "Kimi K2.5/K2.6 (Rank 2 — Coding + Reasoning)"
      )
      MODEL_TAGS=(
        "hf.co/unsloth/GLM-5.1-GGUF:Q4_K_M"      # [VERIFY]
        "hf.co/unsloth/Kimi-K2.6-GGUF:INT4"       # [VERIFY]
      )
      MODEL_BEST_FOR=(
        "Coding · Reasoning · MoE 754B / 40B active"
        "Coding · Reasoning · MoE 1T / 32B active"
      )
      MODEL_SIZE=("754B MoE  ~300 GB" "1T MoE  ~400 GB")
      MODEL_LICENSE=("MIT" "Modified MIT")
      ;;

    5) # ── 8× H200 (1,128 GB) ────────────────────────────────────────────
      MODEL_NAMES=(
        "DeepSeek V4 Pro  (Rank 1 — Coding + Reasoning)"
        "GLM-5.2          (Rank 2 — Coding + Reasoning)"
      )
      MODEL_TAGS=(
        "hf.co/unsloth/DeepSeek-V4-Pro-GGUF:Q4_K_M"  # [VERIFY]
        "hf.co/unsloth/GLM-5.2-GGUF:FP8"             # [VERIFY]
      )
      MODEL_BEST_FOR=(
        "Coding · Reasoning · MoE 1.6T / 49B active"
        "Coding · Reasoning · MoE 744B / 40B active (FP8)"
      )
      MODEL_SIZE=("1.6T MoE  ~500 GB" "744B MoE  ~744 GB")
      MODEL_LICENSE=("MIT" "MIT")
      ;;

  esac
}
