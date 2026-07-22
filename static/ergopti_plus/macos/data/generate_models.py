# hammerspoon/data/generate_models.py
"""
==============================================================================
MODULE: Generate Models JSON
DESCRIPTION:
Reads a base JSON configuration of LLM models and enriches it by fetching
metadata, parameter counts, and hardware requirements from HuggingFace
and Ollama.

FEATURES & RATIONALE:
1. Automated Metadata Fetching: Scrapes tags, parameter sizes, and updates.
2. Hardware Estimation: Intelligently calculates RAM and download sizes.
3. Failsafe Parsing: Gracefully handles network timeouts and missing data.
==============================================================================
"""

import json
import os
import re
from typing import Any, Dict, Optional, Union

import requests
from bs4 import BeautifulSoup

REQUEST_TIMEOUT = 10


# ==========================================
# ==========================================
# ======= 1/ Data Fetching Utilities =======
# ==========================================
# ==========================================


def extract_repo_id(url: Optional[str]) -> Optional[str]:
    """Extracts the repository ID from a HuggingFace URL.

    Args:
            url: The full HuggingFace repository URL.

    Returns:
            The extracted repository ID or None if parsing fails.
    """
    if not url:
        return None
    if "huggingface.co/" not in url:
        return url
    return url.split("huggingface.co/")[-1].strip("/")


# =========================================
# ===== 1.1) HuggingFace API Metadata =====
# =========================================


def get_hf_metadata(repo_url: Optional[str]) -> Dict[str, Any]:
    """Fetches model metadata from the HuggingFace API.

    Retrieves tags, parameter counts, last updated dates, and the raw README content.

    Args:
            repo_url: The full HuggingFace repository URL.

    Returns:
            A dictionary containing the enriched metadata.
    """
    default_meta = {
        "tags": [],
        "total_params": "N/A",
        "readme": "",
        "last_updated": "Unknown",
    }

    repo_id = extract_repo_id(repo_url)
    if not repo_id:
        return default_meta

    api_url = f"https://huggingface.co/api/models/{repo_id}"
    try:
        response = requests.get(api_url, timeout=REQUEST_TIMEOUT)
        if response.status_code != 200:
            return default_meta
        data = response.json()
    except requests.RequestException:
        return default_meta

    raw_tags = data.get("tags", [])
    target_tags = {
        "mixture_of_experts",
        "moe",
        "text-generation",
        "conversational",
        "reasoning",
        "instruct",
        "dsa",
    }
    relevant_tags = [t for t in raw_tags if t in target_tags]

    if "text-generation" in raw_tags or "conversational" in raw_tags:
        relevant_tags.append("text")
    if "moe" in raw_tags:
        relevant_tags.append("mixture_of_experts")

    total_params = "N/A"
    safetensors = data.get("safetensors", {})
    total_p_count = safetensors.get("total")

    # If 'total' is missing, sum the individual parameter counts
    if not isinstance(total_p_count, int):
        params_dict = safetensors.get("parameters", {})
        total_p_count = sum(
            v for v in params_dict.values() if isinstance(v, int)
        )

    if total_p_count and total_p_count > 0:
        billions = total_p_count / 1e9
        if billions.is_integer():
            total_params = f"{int(billions)}B"
        else:
            total_params = f"{round(billions, 2):g}B"

    last_modified = data.get("lastModified")
    created_at = data.get("createdAt")
    date_str = last_modified or created_at
    clean_date = date_str.split("T")[0] if date_str else "Unknown"

    readme = ""
    try:
        readme_req = requests.get(
            f"https://huggingface.co/{repo_id}/raw/main/README.md",
            timeout=REQUEST_TIMEOUT,
        )
        if readme_req.status_code == 200:
            readme = readme_req.text
    except requests.RequestException:
        pass

    return {
        "tags": sorted(list(set(relevant_tags))),
        "total_params": total_params,
        "readme": readme,
        "last_updated": clean_date,
    }


# ==========================================
# ==========================================
# ======= 2/ Hardware & Math Helpers =======
# ==========================================
# ==========================================


def get_hf_repo_size_gb(repo_url: Optional[str]) -> Optional[float]:
    """Calculates the total size of a HuggingFace repository in Gigabytes.

    Args:
            repo_url: The full HuggingFace repository URL.

    Returns:
            The total size in GB, or None if the request fails.
    """
    repo_id = extract_repo_id(repo_url)
    if not repo_id:
        return None

    api_url = f"https://huggingface.co/api/models/{repo_id}/tree/main"
    try:
        response = requests.get(api_url, timeout=REQUEST_TIMEOUT)
        if response.status_code != 200:
            return None
        files = response.json()
        total_bytes = sum(
            f.get("size", 0) for f in files if isinstance(f, dict)
        )
        return round(total_bytes / (1024**3), 2)
    except requests.RequestException:
        return None


def get_ollama_size_gb(ollama_url: Optional[str]) -> Optional[float]:
    """Scrapes the model size in Gigabytes from an Ollama model page.

    Args:
            ollama_url: The full Ollama repository URL.

    Returns:
            The extracted size in GB, or None if parsing fails.
    """
    if not ollama_url or "ollama.com" not in ollama_url:
        return None

    try:
        # Spoofing the User-Agent to prevent 403 Forbidden or bot-blocks from Ollama's CDN
        headers = {
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        }
        response = requests.get(
            ollama_url, headers=headers, timeout=REQUEST_TIMEOUT
        )
        soup = BeautifulSoup(response.text, "html.parser")

        # Look into standard text containers for an exact size match
        for tag in soup.find_all(["span", "div", "p", "a"]):
            text = tag.get_text(strip=True)
            if re.match(r"^\d+(?:\.\d+)?\s*(GB|MB)$", text, re.IGNORECASE):
                size_matches = re.findall(r"\d+\.\d+|\d+", text)
                if size_matches:
                    size = float(size_matches[0])
                    if "MB" in text.upper():
                        size /= 1024
                    return round(size, 2)

        # Fallback: scan the entire text for something like "8B • 4.7 GB"
        full_text = soup.get_text(separator=" ")
        fallback_match = re.search(
            r"(?:^|\s|•|-)(\d+(?:\.\d+)?)\s*(GB|MB)\b", full_text, re.IGNORECASE
        )
        if fallback_match:
            size = float(fallback_match.group(1))
            if fallback_match.group(2).upper() == "MB":
                size /= 1024
            return round(size, 2)

    except Exception as e:
        print(f"Erreur de récupération pour Ollama ({ollama_url}): {e}")

    return None


# ==================================
# ===== 2.1) Parameter Parsing =====
# ==================================


def extract_active_params(
    model_name: str, readme_text: str, total_params: str
) -> str:
    """Extracts active parameters for Mixture of Experts (MoE) or Effective parameter models.

    Prioritizes the model name to avoid conflicts when multiple models share a README.

    Args:
            model_name: The name of the model.
            readme_text: The content of the model's README file.
            total_params: The fallback total parameters string.

    Returns:
            A string representing the active parameter count.
    """
    match_a_name = re.search(r"(?i)A(\d+(?:\.\d+)?)B", model_name)
    if match_a_name:
        return f"{match_a_name.group(1)}B"

    match_e_name = re.search(r"(?i)E(\d+(?:\.\d+)?)B", model_name)
    if match_e_name:
        return f"{match_e_name.group(1)}B"

    if readme_text:
        match_active = re.search(
            r"(?i)(\d+(?:\.\d+)?B)[ -]*active", readme_text
        )
        if match_active:
            return match_active.group(1).upper()

    return total_params


# Quantised weights (Ollama's default Q4_K_M, and typical 4-bit MLX builds)
# weigh about this many GB per billion parameters. Used ONLY to estimate a
# download size when the live HuggingFace/Ollama lookup returned nothing.
GB_PER_BILLION_Q4 = 0.55
# A loaded model needs its quantised weights resident, PLUS KV-cache and
# activations (~15 % at the small context this driver uses), PLUS a fixed
# engine + OS overhead. RAM is derived from the DOWNLOAD size so the two can
# never be mutually inconsistent — the previous estimate computed RAM straight
# from the parameter count and produced RAM < download for MoE models.
RAM_ACTIVATION_FACTOR = 1.15
RAM_BASE_OVERHEAD_GB = 1.0


def parse_params_billions(params_str: Optional[str]) -> Optional[float]:
    """Parses a parameter-count string into a float number of billions.

    Handles "30.53B" / "3B" suffixes and the "8x7B" mixture-of-experts
    shorthand (total ≈ experts × size × 0.85, accounting for shared layers).

    Args:
            params_str: A parameter-count string such as "30.53B" or "8x7B".

    Returns:
            The parameter count in billions, or None if unparseable.
    """
    if not params_str or params_str in ("N/A", "0.0B", "0B"):
        return None
    lowered = params_str.lower().replace("b", "")
    try:
        if "x" in lowered:
            experts, size = lowered.split("x")
            return float(experts) * float(size) * 0.85
        return float(re.sub(r"[^\d.]", "", lowered))
    except ValueError:
        return None


def estimate_download_gb(params_str: Optional[str]) -> Optional[float]:
    """Estimates the quantised download size in GB from the parameter count.

    A fallback only: the real size comes from the HuggingFace/Ollama lookup and
    is preferred whenever available. Filling this in stops a failed lookup from
    leaving a blank disk figure in the menu.

    Args:
            params_str: A parameter-count string such as "7B" or "30.53B".

    Returns:
            The estimated download size in GB, or None if params are unknown.
    """
    billions = parse_params_billions(params_str)
    if billions is None:
        return None
    return round(billions * GB_PER_BILLION_Q4, 2)


def estimate_ram_gb(download_gb: Optional[float]) -> Optional[float]:
    """Estimates required RAM in GB from the (real or estimated) download size.

    Args:
            download_gb: The model download size in GB.

    Returns:
            The estimated RAM in GB (always ≥ the download), or None if unknown.
    """
    if not download_gb or download_gb <= 0:
        return None
    return round(download_gb * RAM_ACTIVATION_FACTOR + RAM_BASE_OVERHEAD_GB, 1)


def calculate_hardware_requirements(
    download_gb: Optional[float], params_str: str
) -> Dict[str, Optional[float]]:
    """Calculates unified hardware requirements.

    The download size is the live-looked-up value when available, otherwise an
    estimate from the parameter count (so a failed lookup no longer leaves a
    blank). RAM is always derived from whichever download size is used, keeping
    the two consistent (RAM ≥ download).

    Args:
            download_gb: The looked-up download size in GB, or None.
            params_str: A string representing the total parameter count.

    Returns:
            A dictionary mapping hardware components to their GB requirements.
    """
    effective_dl = download_gb if download_gb else estimate_download_gb(params_str)
    dl_rounded = round(effective_dl, 2) if effective_dl else None
    return {
        "download_gb": dl_rounded,
        "ram_gb": estimate_ram_gb(effective_dl),
    }


def estimate_speed(active_params_str: str) -> Dict[str, Union[int, str]]:
    """Estimates inference speed (tokens per second) based on active parameter count.

    Args:
            active_params_str: A string representing the active parameter count.

    Returns:
            A dictionary mapping speed metrics to their estimated values.
    """
    try:
        val = float(re.sub(r"[^\d.]", "", active_params_str))
    except ValueError:
        return {"speed_tok_s": 50, "speed_tier": "Unknown"}

    if val <= 4:
        return {"speed_tok_s": 80, "speed_tier": "Very Fast"}
    elif val <= 10:
        return {"speed_tok_s": 50, "speed_tier": "Fast"}
    elif val <= 35:
        return {"speed_tok_s": 25, "speed_tier": "Moderate"}
    elif val <= 75:
        return {"speed_tok_s": 10, "speed_tier": "Slow"}
    else:
        return {"speed_tok_s": 3, "speed_tier": "Very Slow"}


# =======================================
# =======================================
# ======= 3/ Main Generator Logic =======
# =======================================
# =======================================


def build_final_json(v0_filepath: str, output_filepath: str) -> None:
    """Reads the initial JSON, processes data, and writes the enriched JSON.

    Args:
            v0_filepath: The path to the source JSON file.
            output_filepath: The path where the enriched JSON will be saved.
    """
    with open(v0_filepath, "r", encoding="utf-8") as f:
        v0_data = json.load(f)

    final_output = []

    for provider_block in v0_data:
        provider_name = provider_block.get("provider", "Unknown Provider")
        new_provider = {"label": provider_name, "families": []}

        for family_block in provider_block.get("families", []):
            family_name = family_block.get("family", "Unknown Family")
            new_family = {"label": family_name, "models": []}

            for model_item in family_block.get("models", []):
                model_name = model_item.get("name", "Unknown Model")
                print(f"Traitement en cours : {model_name}…")

                urls = model_item.get("urls", {})
                hf_meta = get_hf_metadata(urls.get("hf"))

                total_p = hf_meta["total_params"]

                # Smart fallback: Parse model name if HuggingFace API lacks the parameter count
                if total_p in ("N/A", "0.0B", "0B"):
                    match_b = re.search(
                        r"(?i)(\d+(?:\.\d+)?(?:x\d+(?:\.\d+)?)?)B", model_name
                    )
                    if match_b:
                        total_p = f"{match_b.group(1).upper()}B"
                    else:
                        match_m = re.search(r"(?i)(\d+(?:\.\d+)?)M", model_name)
                        if match_m:
                            mb = float(match_m.group(1))
                            total_p = f"{round(mb / 1000, 2):g}B"

                active_p = extract_active_params(
                    model_name, hf_meta["readme"], total_p
                )

                if active_p in ("N/A", "0.0B", "0B"):
                    active_p = total_p

                speed_data = estimate_speed(active_p)
                model_type = model_item.get("type", "chat")
                hardware = {}

                mlx_url = urls.get("mlx")
                mlx_dl = get_hf_repo_size_gb(mlx_url) if mlx_url else None
                hardware["mlx"] = calculate_hardware_requirements(
                    mlx_dl, total_p
                )

                ollama_url = urls.get("ollama")
                ollama_dl = (
                    get_ollama_size_gb(ollama_url) if ollama_url else None
                )
                hardware["ollama"] = calculate_hardware_requirements(
                    ollama_dl, total_p
                )

                new_family["models"].append(
                    {
                        "name": model_name,
                        "type": model_type,
                        "last_updated": hf_meta["last_updated"],
                        "parameters": {"total": total_p, "active": active_p},
                        "capabilities": {
                            "speed_tok_s": speed_data["speed_tok_s"],
                            "speed_tier": speed_data["speed_tier"],
                            "tags": hf_meta["tags"]
                            if hf_meta["tags"]
                            else ["dense", "text"],
                        },
                        "hardware_requirements": hardware,
                        "urls": urls,
                    }
                )

            new_provider["families"].append(new_family)

        final_output.append(new_provider)

    with open(output_filepath, "w", encoding="utf-8") as f:
        json.dump(final_output, f, indent=4, ensure_ascii=False)

    print(f"\nSuccès ! Sauvegardé dans {output_filepath}")


if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    # Source and output files now live in _shared/modules/llm/ — two levels up from this
    # script (hammerspoon/data/ → hammerspoon/ → drivers/ → _shared/modules/llm/).
    shared_llm_dir = os.path.normpath(os.path.join(script_dir, "../../_shared/modules/llm"))
    v0_path = os.path.join(shared_llm_dir, "models_v0.json")
    final_path = os.path.join(shared_llm_dir, "models.json")

    build_final_json(v0_path, final_path)
