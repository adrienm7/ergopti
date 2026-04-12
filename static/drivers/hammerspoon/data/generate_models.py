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


def estimate_ram(total_params_str: str) -> Optional[float]:
    """Estimates the required RAM in GB based on total parameters.

    Provides a precise estimation without arbitrary tiers, optimized for
    4-bit quantization and a very small context window.

    Args:
            total_params_str: A string representing the total parameter count.

    Returns:
            The estimated required RAM in GB.
    """
    if not total_params_str or total_params_str == "N/A":
        return None

    try:
        total_params_lower = total_params_str.lower().replace("b", "")
        if "x" in total_params_lower:
            parts = total_params_lower.split("x")
            # MoE heuristic: total params is roughly 85% of experts * size due to shared layers
            total_p = float(parts[0]) * float(parts[1]) * 0.85
        else:
            total_p = float(re.sub(r"[^\d.]", "", total_params_lower))
    except ValueError:
        return None

    # 4-bit weights = ~0.55 GB per billion parameters
    # Inference engine overhead + small context = ~0.5 GB
    ram_gb = (total_p * 0.55) + 0.5

    return round(ram_gb, 1)


def calculate_hardware_requirements(
    download_gb: Optional[float], params_str: str
) -> Dict[str, Optional[float]]:
    """Calculates unified hardware requirements.

    Args:
            download_gb: The size of the model download in GB.
            params_str: A string representing the total parameter count.

    Returns:
            A dictionary mapping hardware components to their GB requirements.
    """
    dl_rounded = round(download_gb, 2) if download_gb else None
    return {
        "download_gb": dl_rounded,
        "ram_gb": estimate_ram(params_str),
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
    v0_path = os.path.join(script_dir, "llm_models_v0.json")
    final_path = os.path.join(script_dir, "llm_models.json")

    build_final_json(v0_path, final_path)
